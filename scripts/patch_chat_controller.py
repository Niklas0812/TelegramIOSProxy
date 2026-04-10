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

    # Inject the translation guard right after the opening brace
    translation_guard = """
        // AI Translation: media caption translation guard
        // Translates caption text, then enqueues ENTIRE batch directly to preserve album grouping
        // and TranslationMessageAttribute (same path as compose bar text).
        if AITranslationSettings.enabled && AITranslationSettings.autoTranslateOutgoing,
           let aiPeerId = self.chatLocation.peerId,
           !AIBackgroundTranslationObserver.botChatIds.contains(aiPeerId.id._internalGetInt64Value()),
           AITranslationSettings.enabledChatIds.isEmpty || AITranslationSettings.enabledChatIds.contains(aiPeerId.id._internalGetInt64Value()) {

            // Re-entry check: if any message already has TranslationMessageAttribute,
            // this batch was already translated — skip to normal send
            let aiAlreadyTranslated = messages.contains(where: {
                if case let .message(_, attributes, _, _, _, _, _, _, _, _) = $0 {
                    return attributes.contains(where: { $0 is TranslationMessageAttribute })
                }
                return false
            })

            if !aiAlreadyTranslated {
                // Find first message with untranslated caption text
                var aiCaptionIndex: Int? = nil
                for (aiIdx, aiMsg) in messages.enumerated() {
                    if case let .message(text, _, _, _, _, _, _, _, _, _) = aiMsg,
                       !text.isEmpty {
                        aiCaptionIndex = aiIdx
                        break
                    }
                }

                if let aiCaptionIdx = aiCaptionIndex {
                    guard case let .message(aiCaptionText, _, _, _, _, _, _, _, _, _) = messages[aiCaptionIdx] else { return }

                    let aiOriginalMessages = messages
                    let aiTranslationDisposable = MetaDisposable()
                    var aiTranslationCompleted = false

                    let aiSignal = AITranslationService.shared.translateOutgoingStrict(
                        text: aiCaptionText,
                        chatId: aiPeerId,
                        context: self.context
                    ) |> deliverOnMainQueue

                    aiTranslationDisposable.set(aiSignal.start(next: { [weak self] result in
                        guard let self = self, !aiTranslationCompleted else { return }
                        aiTranslationCompleted = true

                        if let translatedText = result, !translatedText.isEmpty {
                            var newMessages = aiOriginalMessages
                            if case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets) = aiOriginalMessages[aiCaptionIdx] {
                                var newAttributes = attributes
                                newAttributes.append(TranslationMessageAttribute(text: text, entities: [], toLang: "en"))
                                newMessages[aiCaptionIdx] = .message(text: translatedText, attributes: newAttributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)
                            }
                            // Use enqueueMessages directly (same path as compose bar) to preserve TranslationMessageAttribute
                            AIBackgroundTranslationObserver.pendingCaptionOriginals["\\(aiPeerId.id._internalGetInt64Value())_\\(translatedText)"] = aiCaptionText
                            let _ = enqueueMessages(account: self.context.account, peerId: aiPeerId, messages: newMessages).start()
                        } else {
                            AILogger.log("POPUP SHOWN: caption fail — result=\\(result == nil ? "nil" : "empty")")
                            self.present(UndoOverlayController(
                                presentationData: self.presentationData,
                                content: .info(title: nil, text: "Translation failed. Message not sent. Try again.", timeout: 5.0, customUndoText: nil),
                                elevatedLayout: true,
                                action: { _ in return false }
                            ), in: .current)
                        }
                    }))

                    // Failsafe timeout
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60.0) { [weak self] in
                        guard !aiTranslationCompleted, let self = self else { return }
                        aiTranslationCompleted = true
                        aiTranslationDisposable.dispose()
                        AILogger.log("POPUP SHOWN: caption 60s TIMEOUT")
                        self.present(UndoOverlayController(
                            presentationData: self.presentationData,
                            content: .info(title: nil, text: "Translation timed out. Message not sent. Try again.", timeout: 5.0, customUndoText: nil),
                            elevatedLayout: true,
                            action: { _ in return false }
                        ), in: .current)
                    }

                    return
                }
            }
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
