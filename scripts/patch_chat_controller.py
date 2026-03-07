#!/usr/bin/env python3
"""Patch ChatController.swift to translate media captions before sending.

Media messages (photos, videos, documents) with text captions go through
ChatController.sendMessages() — a DIFFERENT path than the compose bar text
(which goes through ChatControllerLoadDisplayNode.swift).

This patch injects a translation guard at the top of sendMessages(). When a
.message has non-empty text and no TranslationMessageAttribute, it routes
through AIOutgoingMessageQueue. The queue's sendAction callback re-calls
sendMessages() with the translated text + attribute attached. The re-entry
check sees the attribute and falls through to normal send.

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
        print("ERROR: Could not find sendMessages(_ messages: [EnqueueMessage]) in ChatController.swift")
        print("Media caption translation will NOT work.")
        return

    func_header = match.group(0)

    # Inject the translation guard right after the opening brace
    translation_guard = """
        // AI Translation: media caption translation guard
        // Intercepts .message cases with non-empty text that haven't been translated yet.
        // Routes through AIOutgoingMessageQueue for translation + cascading failure.
        // Re-entry safe: translated messages have TranslationMessageAttribute → skip.
        if AITranslationSettings.enabled && AITranslationSettings.autoTranslateOutgoing,
           let aiPeerId = self.chatLocation.peerId {
            var aiNeedsTranslation = false
            for aiMsg in messages {
                if case let .message(text, attributes, _, _, _, _, _, _, _, _) = aiMsg,
                   !text.isEmpty,
                   !attributes.contains(where: { $0 is TranslationMessageAttribute }) {
                    aiNeedsTranslation = true
                    break
                }
            }
            if aiNeedsTranslation {
                for aiMsg in messages {
                    switch aiMsg {
                    case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets):
                        if !text.isEmpty && !attributes.contains(where: { $0 is TranslationMessageAttribute }) {
                            AIOutgoingMessageQueue.shared.enqueue(
                                text: text,
                                peerId: aiPeerId,
                                context: self.context,
                                sendAction: { [weak self] translatedText -> Bool in
                                    guard let self = self else { return false }
                                    var newAttributes = attributes
                                    newAttributes.append(TranslationMessageAttribute(text: text, entities: [], toLang: "en"))
                                    self.sendMessages([.message(text: translatedText, attributes: newAttributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)])
                                    return true
                                },
                                restoreAction: { [weak self] originalText in
                                    guard let self = self else { return }
                                    if let textInputPanelNode = self.chatDisplayNode.inputPanelNode as? ChatTextInputPanelNode {
                                        if textInputPanelNode.text.isEmpty {
                                            textInputPanelNode.text = originalText
                                        }
                                    }
                                },
                                errorAction: { [weak self] in
                                    guard let self = self else { return }
                                    self.present(UndoOverlayController(
                                        presentationData: self.presentationData,
                                        content: .info(title: nil, text: "Translation failed. Message not sent. Try again.", timeout: 5.0, customUndoText: nil),
                                        elevatedLayout: true,
                                        action: { _ in return false }
                                    ), in: .current)
                                }
                            )
                        } else {
                            self.sendMessages([aiMsg])
                        }
                    case .forward:
                        self.sendMessages([aiMsg])
                    }
                }
                return
            }
        }
"""

    content = content.replace(func_header, func_header + translation_guard, 1)

    with open(filepath, "w") as f:
        f.write(content)

    print(f"Patched {filepath}: media caption translation via AIOutgoingMessageQueue")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_ChatController.swift>")
        sys.exit(1)

    patch_chat_controller(sys.argv[1])
