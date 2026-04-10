#!/usr/bin/env python3
"""Patch ChatControllerLoadDisplayNode.swift to handle Quick Reply shortcuts.

Telegram Premium's Quick Reply feature calls `sendMessageShortcut()` which sends
via the server API directly (messages.sendQuickReplyMessages), bypassing all local
translation patches.

In our setup, quick reply templates are stored in GERMAN on the account. The user
sees German templates in the "/" dropdown and they are sent in German to the
recipient. But we want the LOCAL display (both in the "/" preview and in the sent
message bubble) to show ENGLISH.

This patch intercepts sendMessageShortcut, fetches the shortcut's messages from the
local viewTracker, and enqueues them directly — preserving the German text (so the
recipient still gets German) but attaching a `TranslationMessageAttribute` with the
pre-computed English translation from `AIBackgroundTranslationObserver.quickReplyTranslations`.

That attribute is what `patch_text_bubble.py` uses to render the message locally
in English via Telegram's native translation display path.

IMPORTANT: We do NOT route through `self.sendMessages()` here because that would hit
`patch_chat_controller.py` which tries to translate English → German on the caption
text. Since the template is ALREADY German, that would double-translate (or fail,
causing a "Translation failed" popup). We call `enqueueMessages()` directly instead.
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
            // Templates are stored in German. We send them as-is (German) to the recipient,
            // but attach a TranslationMessageAttribute with the pre-computed English text so
            // the local display renders English. We call enqueueMessages directly to bypass
            // sendMessages() which would otherwise try to translate English→German on the
            // already-German text.
            let _ = (self.context.account.viewTracker.quickReplyMessagesViewForLocation(quickReplyId: shortcutId)
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak self] view, _, _ in
                guard let self = self else { return }

                if !AITranslationSettings.enabled || AIBackgroundTranslationObserver.botChatIds.contains(peerId.id._internalGetInt64Value()) || (!AITranslationSettings.enabledChatIds.isEmpty && !AITranslationSettings.enabledChatIds.contains(peerId.id._internalGetInt64Value())) {
                    self.context.engine.accountData.sendMessageShortcut(peerId: peerId, id: shortcutId)
                    return
                }

                var messagesToSend: [EnqueueMessage] = []
                for entry in view.entries {
                    let msg = entry.message
                    let text = msg.text

                    // Look up the pre-computed English translation of this template.
                    // If missing (e.g. scan hasn't completed yet), fall back to the German
                    // text — the user will see German locally until the background scan
                    // finishes and the attribute is re-attached on next open.
                    var attributes: [MessageAttribute] = []
                    if let english = AIBackgroundTranslationObserver.quickReplyTranslations[msg.id], !english.isEmpty {
                        attributes.append(TranslationMessageAttribute(text: english, entities: [], toLang: "en"))
                    }

                    let mediaRef = msg.media.first.flatMap { AnyMediaReference.standalone(media: $0) }
                    messagesToSend.append(.message(
                        text: text,
                        attributes: attributes,
                        inlineStickers: [:],
                        mediaReference: mediaRef,
                        threadId: self.chatLocation.threadId,
                        replyToMessageId: nil,
                        replyToStoryId: nil,
                        localGroupingKey: nil,
                        correlationId: nil,
                        bubbleUpEmojiOrStickersets: []
                    ))
                }

                if messagesToSend.isEmpty {
                    self.context.engine.accountData.sendMessageShortcut(peerId: peerId, id: shortcutId)
                    return
                }

                // Call enqueueMessages DIRECTLY — bypass self.sendMessages() which would
                // trigger patch_chat_controller.py to translate German→English→... Germ.
                AILogger.log("QR-SEND: sending \\(messagesToSend.count) template(s) to peer \\(peerId.id._internalGetInt64Value())")
                let _ = enqueueMessages(account: self.context.account, peerId: peerId, messages: messagesToSend).start()
            })"""

    content = content.replace(old_code, new_code, 1)

    with open(filepath, "w") as f:
        f.write(content)

    print(f"Patched {filepath}: quick reply shortcut translation (direct enqueue)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_ChatControllerLoadDisplayNode.swift>")
        sys.exit(1)

    patch_quick_reply(sys.argv[1])
