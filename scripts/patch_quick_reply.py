#!/usr/bin/env python3
"""Patch ChatControllerLoadDisplayNode.swift to handle Quick Reply shortcuts.

Telegram Premium's Quick Reply feature calls `sendMessageShortcut()` which sends
via the server API directly (messages.sendQuickReplyMessages), bypassing all local
translation patches.

In our setup, quick reply templates are stored in GERMAN on the account. The user
sees English in the "/" dropdown (via the `quickReplyTranslations` cache populated
by `AIBackgroundTranslationObserver.translateQuickReplyTemplates()`). When a template
is sent, we now want it to go through the SAME outgoing translation pipeline as a
regular typed message: the cached ENGLISH text is fed into `AIOutgoingMessageQueue`,
which calls `translateOutgoingStrict()` (EN→DE, claim-checked). The resulting fresh
German is sent to the recipient; locally we attach a `TranslationMessageAttribute`
carrying the English so the sent bubble renders in English.

This fixes two problems at once:
  1. Templates now go through the outgoing pipeline (claim check applies, fresh
     translation every send, consistent with typed-text behavior).
  2. Media+caption templates no longer pop "Translation failed" — the caption
     is translated inside the queue's sendAction and sent as one message with the
     photo's media reference preserved.

Paths:
  - Text-only template with cached English  → AIOutgoingMessageQueue.enqueue
  - Picture+caption template with cached English → AIOutgoingMessageQueue.enqueue,
    sendAction attaches mediaReference
  - Media-only template (empty text)        → direct enqueueMessages (nothing to translate)
  - Cache miss (scan not done yet)          → direct enqueueMessages (German as-is)

Translation-disabled / bot chat / non-whitelisted chat: passes through to the
original sendMessageShortcut() API unchanged.
"""
import sys


def patch_quick_reply(filepath: str) -> None:
    with open(filepath, "r") as f:
        content = f.read()

    if "AI Translation: intercept quick reply" in content:
        print("Already patched, skipping.")
        return

    old_code = "self.context.engine.accountData.sendMessageShortcut(peerId: peerId, id: shortcutId)"

    if old_code not in content:
        print("FATAL: Could not find sendMessageShortcut call in ChatControllerLoadDisplayNode.swift")
        print("Quick reply translation will NOT work.")
        sys.exit(1)

    new_code = """// AI Translation: intercept quick reply
            // Templates are stored in German; the English versions are cached in
            // AIBackgroundTranslationObserver.quickReplyTranslations. On send we route the
            // cached ENGLISH text through AIOutgoingMessageQueue — same pipeline as typed
            // text — so translation is fresh, claim checks apply, and the sent bubble shows
            // English locally via the attached TranslationMessageAttribute. Media+caption
            // templates are handled via the same path with a mediaReference attached inside
            // the sendAction closure.
            let _ = (self.context.account.viewTracker.quickReplyMessagesViewForLocation(quickReplyId: shortcutId)
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak self] view, _, _ in
                guard let self = self else { return }

                // Claim guard — fires /claim once per shortcut send so every quick
                // reply (text, text+media, media-only, AND the translation-disabled
                // passthrough to sendMessageShortcut below) registers the claim on the
                // backend. Placed BEFORE the disabled-chat fall-throughs so even those
                // bypass paths still hit /claim. Fire-and-forget: text entries will
                // re-check via /translate anyway.
                if !AIBackgroundTranslationObserver.botChatIds.contains(peerId.id._internalGetInt64Value()) && peerId.id._internalGetInt64Value() != 777000 {
                    AILogger.log("OUT-PATH [quick-reply]: peer=\\(peerId.id._internalGetInt64Value()) entries=\\(view.entries.count)")
                    let _ = AITranslationService.shared.applyClaimGuard(chatId: peerId, context: self.context).start()
                }

                if !AITranslationSettings.enabled || AIBackgroundTranslationObserver.botChatIds.contains(peerId.id._internalGetInt64Value()) || (!AITranslationSettings.enabledChatIds.isEmpty && !AITranslationSettings.enabledChatIds.contains(peerId.id._internalGetInt64Value())) {
                    self.context.engine.accountData.sendMessageShortcut(peerId: peerId, id: shortcutId)
                    return
                }

                if view.entries.isEmpty {
                    self.context.engine.accountData.sendMessageShortcut(peerId: peerId, id: shortcutId)
                    return
                }

                let threadId = self.chatLocation.threadId

                for entry in view.entries {
                    let msg = entry.message
                    let storedText = msg.text
                    let mediaRef: AnyMediaReference? = msg.media.first.flatMap { AnyMediaReference.standalone(media: $0) }
                    let cachedEnglish = AIBackgroundTranslationObserver.quickReplyTranslations[msg.id]

                    // Case: media-only template — no caption to translate. Route
                    // through the queue as .passthrough so it still takes its FIFO
                    // turn behind any earlier text template translations.
                    if storedText.isEmpty {
                        AILogger.log("QR-SEND MEDIA-ONLY: msg=\\(msg.id.id) peer=\\(peerId.id._internalGetInt64Value()) hasMedia=\\(mediaRef != nil)")
                        let qrMediaFp = SendFingerprint.build(
                            peerId: peerId,
                            text: "",
                            media: mediaRef?.media,
                            replyToMessageId: nil,
                            replyToStoryId: nil,
                            localGroupingKey: nil
                        )
                        let qrMediaRef = mediaRef
                        let qrThreadId = threadId
                        let _ = AIOutgoingMessageQueue.shared.enqueue(
                            peerId: peerId,
                            fingerprint: qrMediaFp,
                            kind: .passthrough(text: ""),
                            context: self.context,
                            sendAction: { [weak self] _ -> Bool in
                                guard let self = self else { return false }
                                let _ = enqueueMessages(account: self.context.account, peerId: peerId, messages: [
                                    .message(text: "", attributes: [], inlineStickers: [:],
                                             mediaReference: qrMediaRef, threadId: qrThreadId,
                                             replyToMessageId: nil, replyToStoryId: nil,
                                             localGroupingKey: nil, correlationId: nil,
                                             bubbleUpEmojiOrStickersets: [])
                                ]).start()
                                return true
                            },
                            restoreAction: { _ in },
                            errorAction: { [weak self] message in
                                guard let self = self else { return }
                                AILogger.log("POPUP SHOWN: quick reply media-only — \\(message)")
                                self.present(UndoOverlayController(
                                    presentationData: self.presentationData,
                                    content: .info(title: nil, text: message, timeout: 5.0, customUndoText: nil),
                                    elevatedLayout: true,
                                    action: { _ in return false }
                                ), in: .current)
                            }
                        )
                        continue
                    }

                    // Case: text template — ALWAYS route through AIOutgoingMessageQueue to guarantee
                    // translation. Prefer the cached English source (canonical). If the cache is
                    // missing (background scan hasn't completed or failed), fall back to msg.text —
                    // this handles English-stored templates correctly (the outgoing pipeline will
                    // translate EN→DE), and for German-stored templates the AI returns German
                    // unchanged. Direct enqueue of raw stored text is NOT safe because an
                    // English-stored template would leak untranslated to the recipient.
                    let sourceText = (cachedEnglish?.isEmpty == false) ? cachedEnglish! : storedText
                    let sourceLabel = (cachedEnglish?.isEmpty == false) ? "cache" : "stored"
                    AILogger.log("QR-SEND QUEUE: enqueue msg=\\(msg.id.id) peer=\\(peerId.id._internalGetInt64Value()) hasMedia=\\(mediaRef != nil) src=\\(sourceLabel) text='\\(String(sourceText.prefix(40)))'")
                    let qrTextFp = SendFingerprint.build(
                        peerId: peerId,
                        text: sourceText,
                        media: mediaRef?.media,
                        replyToMessageId: nil,
                        replyToStoryId: nil,
                        localGroupingKey: nil
                    )
                    let qrTextMediaRef = mediaRef
                    let qrTextThreadId = threadId
                    let _ = AIOutgoingMessageQueue.shared.enqueue(
                        peerId: peerId,
                        fingerprint: qrTextFp,
                        kind: .translate(text: sourceText),
                        context: self.context,
                        sendAction: { [weak self] translatedText -> Bool in
                            guard let self = self else { return false }
                            let attrs: [MessageAttribute] = [
                                TranslationMessageAttribute(text: sourceText, entities: [], toLang: "en")
                            ]
                            let _ = enqueueMessages(account: self.context.account, peerId: peerId, messages: [
                                .message(text: translatedText, attributes: attrs, inlineStickers: [:],
                                         mediaReference: qrTextMediaRef, threadId: qrTextThreadId,
                                         replyToMessageId: nil, replyToStoryId: nil,
                                         localGroupingKey: nil, correlationId: nil,
                                         bubbleUpEmojiOrStickersets: [])
                            ]).start()
                            return true
                        },
                        restoreAction: { _ in
                            // Quick reply has no input box to restore — no-op.
                        },
                        errorAction: { [weak self] message in
                            guard let self = self else { return }
                            AILogger.log("POPUP SHOWN: quick reply — \\(message)")
                            self.present(UndoOverlayController(
                                presentationData: self.presentationData,
                                content: .info(title: nil, text: message, timeout: 5.0, customUndoText: nil),
                                elevatedLayout: true,
                                action: { _ in return false }
                            ), in: .current)
                        }
                    )
                }
            })"""

    content = content.replace(old_code, new_code, 1)

    with open(filepath, "w") as f:
        f.write(content)

    print(f"Patched {filepath}: quick reply shortcut now routes through AIOutgoingMessageQueue")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_ChatControllerLoadDisplayNode.swift>")
        sys.exit(1)

    patch_quick_reply(sys.argv[1])
