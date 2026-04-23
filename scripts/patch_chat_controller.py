#!/usr/bin/env python3
"""Patch ChatController.swift to translate media captions before sending.

Media messages (photos, videos, documents) with text captions go through
ChatController.sendMessages() — a DIFFERENT path than the compose bar text
(which goes through ChatControllerLoadDisplayNode.swift).

This patch injects a translation guard at the top of sendMessages(). It
translates the caption text, then sends the ENTIRE batch as one call to
preserve album/group structure (localGroupingKey).

Key design:
- Re-entry safe: if any message has TranslationMessageAttribute, skip entirely
- Batch-preserving: translates caption, then sends ALL messages as one call
- Forwards/media-only pass through unchanged (no caption to translate)
- On failure/timeout: sends untranslated batch + shows warning (media never lost)

No double-translation with compose bar: compose bar text goes directly to
enqueueMessages() via patch_load_display_node.py, never through sendMessages().
"""
import sys
import re


def patch_chat_controller(filepath: str) -> None:
    with open(filepath, "r") as f:
        content = f.read()

    # Add import AITranslation
    if "import AITranslation" not in content:
        content = content.replace("import Foundation", "import Foundation\nimport AITranslation", 1)
        print("Added import AITranslation")

    if "// AI Translation: media caption translation guard" in content:
        print("Already patched, skipping.")
        return

    # Find sendMessages function signature
    # Pattern: func sendMessages(_ messages: [EnqueueMessage]...) {
    pattern = re.compile(
        r'(func sendMessages\(\s*_\s+messages:\s*\[EnqueueMessage\][^{]*\{)',
        re.DOTALL
    )

    match = pattern.search(content)
    if not match:
        print("FATAL: Could not find sendMessages(_ messages: [EnqueueMessage]) in ChatController.swift")
        print("Media caption translation will NOT work.")
        sys.exit(1)

    func_header = match.group(0)

    # Inject the translation guard right after the opening brace.
    # Design: EVERY sendMessages call (regardless of content kind) is routed
    # through AIOutgoingMessageQueue, so duplicate-pending sends are blocked
    # and per-peer FIFO order is preserved across media and text paths. The
    # native sendMessages body is only executed if we can't resolve a peerId
    # (should not happen in practice).
    translation_guard = """
        // AI Translation: media caption translation guard
        // Claim guard (fire-and-forget) stays here — registers the claim on the
        // target regardless of whether the batch is translated or passthrough.
        if let aiClaimPeerId = self.chatLocation.peerId,
           !AIBackgroundTranslationObserver.botChatIds.contains(aiClaimPeerId.id._internalGetInt64Value()),
           aiClaimPeerId.id._internalGetInt64Value() != 777000 {
            AILogger.log("OUT-PATH [chat-controller-sendMessages]: peer=\\(aiClaimPeerId.id._internalGetInt64Value()) msgCount=\\(messages.count)")
            let _ = AITranslationService.shared.applyClaimGuard(chatId: aiClaimPeerId, context: self.context).start()
        }

        if let aiSendPeerId = self.chatLocation.peerId {
            // Re-entry guard: if a message in this batch already carries a
            // TranslationMessageAttribute, a previous invocation of the queue's
            // sendAction built it — treat as passthrough to avoid re-translating.
            let aiAlreadyTranslated = messages.contains(where: {
                if case let .message(_, attributes, _, _, _, _, _, _, _, _) = $0 {
                    return attributes.contains(where: { $0 is TranslationMessageAttribute })
                }
                return false
            })

            let aiShouldTranslate = !aiAlreadyTranslated
                && AITranslationSettings.enabled
                && AITranslationSettings.autoTranslateOutgoing
                && !AIBackgroundTranslationObserver.botChatIds.contains(aiSendPeerId.id._internalGetInt64Value())
                && (AITranslationSettings.enabledChatIds.isEmpty || AITranslationSettings.enabledChatIds.contains(aiSendPeerId.id._internalGetInt64Value()))

            // Find first caption-bearing message in the batch (if any).
            var aiCaptionIdx: Int? = nil
            if aiShouldTranslate {
                for (aiIdx, aiMsg) in messages.enumerated() {
                    if case let .message(text, _, _, _, _, _, _, _, _, _) = aiMsg, !text.isEmpty {
                        aiCaptionIdx = aiIdx
                        break
                    }
                }
            }

            let aiBatchFp = SendFingerprint.buildBatch(peerId: aiSendPeerId, messages: messages)
            let aiBatchRef = messages

            if let aiCaptionIdxLet = aiCaptionIdx,
               case let .message(aiCaptionText, _, _, _, _, _, _, _, _, _) = messages[aiCaptionIdxLet], !aiCaptionText.isEmpty {
                // TRANSLATION PATH — queue handles translation + dedup + FIFO.
                // When translation completes, sendAction rebuilds the batch with
                // the translated caption + TranslationMessageAttribute, then calls
                // enqueueMessages directly (same as before, just via the queue).
                let aiCaptionIdxFinal = aiCaptionIdxLet
                let _ = AIOutgoingMessageQueue.shared.enqueue(
                    peerId: aiSendPeerId,
                    fingerprint: aiBatchFp,
                    kind: .translate(text: aiCaptionText),
                    context: self.context,
                    sendAction: { [weak self] translatedText -> Bool in
                        guard let self = self else { return false }
                        var newMessages = aiBatchRef
                        if case let .message(origText, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = aiBatchRef[aiCaptionIdxFinal] {
                            var newAttributes = attributes
                            newAttributes.append(TranslationMessageAttribute(text: origText, entities: [], toLang: "en"))
                            newMessages[aiCaptionIdxFinal] = .message(text: translatedText, attributes: newAttributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
                        }
                        AIBackgroundTranslationObserver.pendingCaptionOriginals["\\(aiSendPeerId.id._internalGetInt64Value())_\\(translatedText)"] = aiCaptionText
                        let _ = enqueueMessages(account: self.context.account, peerId: aiSendPeerId, messages: newMessages).start()
                        return true
                    },
                    restoreAction: { _ in },
                    errorAction: { [weak self] message in
                        guard let self = self else { return }
                        AILogger.log("POPUP SHOWN: caption — \\(message)")
                        self.present(UndoOverlayController(
                            presentationData: self.presentationData,
                            content: .info(title: nil, text: message, timeout: 5.0, customUndoText: nil),
                            elevatedLayout: true,
                            action: { _ in return false }
                        ), in: .current)
                    }
                )
                return
            }

            // PASSTHROUGH PATH — already-translated batch, bot chat, excluded
            // chat, pure forward, or media-only send. Queue as .passthrough so
            // it still takes its FIFO turn behind any earlier translating messages.
            let _ = AIOutgoingMessageQueue.shared.enqueue(
                peerId: aiSendPeerId,
                fingerprint: aiBatchFp,
                kind: .passthrough(text: ""),
                context: self.context,
                sendAction: { [weak self] _ -> Bool in
                    guard let self = self else { return false }
                    let _ = enqueueMessages(account: self.context.account, peerId: aiSendPeerId, messages: aiBatchRef).start()
                    return true
                },
                restoreAction: { _ in },
                errorAction: { [weak self] message in
                    guard let self = self else { return }
                    AILogger.log("POPUP SHOWN: chat-ctrl-passthrough — \\(message)")
                    self.present(UndoOverlayController(
                        presentationData: self.presentationData,
                        content: .info(title: nil, text: message, timeout: 5.0, customUndoText: nil),
                        elevatedLayout: true,
                        action: { _ in return false }
                    ), in: .current)
                }
            )
            return
        }
"""

    content = content.replace(func_header, func_header + translation_guard, 1)

    with open(filepath, "w") as f:
        f.write(content)

    print(f"Patched {filepath}: media caption translation (batch-preserving)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_ChatController.swift>")
        sys.exit(1)

    patch_chat_controller(sys.argv[1])
