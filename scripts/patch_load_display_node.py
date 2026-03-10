#!/usr/bin/env python3
"""Patch ChatControllerLoadDisplayNode.swift for outgoing message translation.

The main user text input path goes through:
  ChatControllerNode.sendCurrentMessage()
    -> chatDisplayNode.sendMessages closure (in ChatControllerLoadDisplayNode.swift)
    -> enqueueMessages()

This bypasses ChatController.sendMessages() entirely, so our existing hook
in patch_chat_controller.py doesn't catch regular typed messages.

This patch intercepts the enqueueMessages() call in the closure to route text
messages through AIOutgoingMessageQueue — a per-peer chronological queue that:
  1. Fires translation INSTANTLY (concurrent, no delay)
  2. Sends to Telegram in strict chronological order
  3. Cascade-cancels all subsequent messages on any failure
"""
import sys
import re


def patch_load_display_node(filepath: str) -> None:
    with open(filepath, "r") as f:
        content = f.read()

    # Add import AITranslation at the top
    if "import AITranslation" not in content:
        content = content.replace("import UIKit", "import UIKit\nimport AITranslation", 1)
        print("Added import AITranslation")

    # Find the target: the single enqueueMessages call for regular (non-forward) messages
    # in the chatDisplayNode.sendMessages closure.
    #
    # Original:
    #   signal = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: transformedMessages)
    #
    # We wrap it with translation:
    #   signal = AITranslationService.shared.translateOutgoingMessages(...)
    #            |> mapToSignal { translated in enqueueMessages(..., messages: translated) }

    old_line = "                        signal = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: transformedMessages)"

    if old_line not in content:
        # Try without leading spaces
        old_line_pattern = r"(\s+)signal = enqueueMessages\(account: strongSelf\.context\.account, peerId: peerId, messages: transformedMessages\)"
        match = re.search(old_line_pattern, content)
        if not match:
            print("ERROR: Could not find enqueueMessages call for transformedMessages")
            print("The outgoing translation hook for typed messages will NOT work.")
            return
        old_line = match.group(0)
        indent = match.group(1)
    else:
        indent = "                        "

    new_code = f"""{indent}// AI Translation: fire-and-forget outgoing translation.
{indent}// Only intercept if there are text messages that need translation.
{indent}// Forwards and non-translatable messages use the original send path to avoid duplication.
{indent}let aiNeedsTranslation = transformedMessages.contains(where: {{
{indent}    if case let .message(text, _, _, _, _, _, _, _, _, _) = $0 {{
{indent}        return !text.isEmpty && AITranslationSettings.enabled && AITranslationSettings.autoTranslateOutgoing && !AIBackgroundTranslationObserver.botChatIds.contains(peerId.id._internalGetInt64Value())
{indent}    }}
{indent}    return false
{indent}}})
{indent}if aiNeedsTranslation {{
{indent}    // Chronological queue with cascading failure.
{indent}    // Forwards + text-free messages are batched together to preserve album grouping.
{indent}    var aiPassthroughMessages: [EnqueueMessage] = []
{indent}    for aiMsg in transformedMessages {{
{indent}        switch aiMsg {{
{indent}        case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets):
{indent}            if !text.isEmpty && AITranslationSettings.enabled && AITranslationSettings.autoTranslateOutgoing && !AIBackgroundTranslationObserver.botChatIds.contains(peerId.id._internalGetInt64Value()) {{
{indent}                AIOutgoingMessageQueue.shared.enqueue(
{indent}                    text: text,
{indent}                    peerId: peerId,
{indent}                    context: strongSelf.context,
{indent}                    sendAction: {{ [weak strongSelf] translatedText -> Bool in
{indent}                        guard let strongSelf = strongSelf else {{ return false }}
{indent}                        var newAttributes = attributes
{indent}                        newAttributes.append(TranslationMessageAttribute(text: text, entities: [], toLang: "en"))
{indent}                        let _ = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: [.message(text: translatedText, attributes: newAttributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)]).start()
{indent}                        return true
{indent}                    }},
{indent}                    restoreAction: {{ [weak strongSelf] originalText in
{indent}                        guard let strongSelf = strongSelf else {{ return }}
{indent}                        if let textInputPanelNode = strongSelf.chatDisplayNode.inputPanelNode as? ChatTextInputPanelNode {{
{indent}                            if textInputPanelNode.text.isEmpty {{
{indent}                                textInputPanelNode.text = originalText
{indent}                            }}
{indent}                        }}
{indent}                    }},
{indent}                    errorAction: {{ [weak strongSelf] in
{indent}                        guard let strongSelf = strongSelf else {{ return }}
{indent}                        strongSelf.present(UndoOverlayController(
{indent}                            presentationData: strongSelf.presentationData,
{indent}                            content: .info(title: nil, text: "Translation failed. Message not sent. Try again.", timeout: 5.0, customUndoText: nil),
{indent}                            elevatedLayout: true,
{indent}                            action: {{ _ in return false }}
{indent}                        ), in: .current)
{indent}                    }}
{indent}                )
{indent}            }} else {{
{indent}                aiPassthroughMessages.append(aiMsg)
{indent}            }}
{indent}        case .forward:
{indent}            aiPassthroughMessages.append(aiMsg)
{indent}        }}
{indent}    }}
{indent}    if !aiPassthroughMessages.isEmpty {{
{indent}        let _ = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: aiPassthroughMessages).start()
{indent}    }}
{indent}    signal = .single([])
{indent}    if let textInputPanelNode = strongSelf.chatDisplayNode.inputPanelNode as? ChatTextInputPanelNode {{
{indent}        textInputPanelNode.text = ""
{indent}    }}
{indent}    strongSelf.chatDisplayNode.historyNode.layoutActionOnViewTransition = nil
{indent}}} else {{
{indent}    // No text needs translation — use original send path (prevents forward duplication)
{indent}    signal = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: transformedMessages)
{indent}}}"""

    content = content.replace(old_line, new_code, 1)

    with open(filepath, "w") as f:
        f.write(content)

    print(f"Patched enqueueMessages in {filepath} with AI translation hook")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_ChatControllerLoadDisplayNode.swift>")
        sys.exit(1)

    patch_load_display_node(sys.argv[1])
