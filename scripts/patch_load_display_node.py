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

    new_code = f"""{indent}// AI Translation: chronological queue with cascading failure.
{indent}// Translation fires INSTANTLY per message. Sending is strict chronological order.
{indent}// On failure: cascade-cancel all subsequent, restore failed text, show error.
{indent}for aiMsg in transformedMessages {{
{indent}    switch aiMsg {{
{indent}    case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets):
{indent}        if !text.isEmpty && AITranslationSettings.enabled && AITranslationSettings.autoTranslateOutgoing {{
{indent}            AIOutgoingMessageQueue.shared.enqueue(
{indent}                text: text,
{indent}                peerId: peerId,
{indent}                context: strongSelf.context,
{indent}                sendAction: {{ [weak strongSelf] translatedText -> Bool in
{indent}                    guard let strongSelf = strongSelf else {{ return false }}
{indent}                    var newAttributes = attributes
{indent}                    newAttributes.append(TranslationMessageAttribute(text: text, entities: [], toLang: "en"))
{indent}                    let _ = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: [.message(text: translatedText, attributes: newAttributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)]).start()
{indent}                    return true
{indent}                }},
{indent}                restoreAction: {{ [weak strongSelf] originalText in
{indent}                    guard let strongSelf = strongSelf else {{ return }}
{indent}                    if let textInputPanelNode = strongSelf.chatDisplayNode.inputPanelNode as? ChatTextInputPanelNode {{
{indent}                        if textInputPanelNode.text.isEmpty {{
{indent}                            textInputPanelNode.text = originalText
{indent}                        }}
{indent}                    }}
{indent}                }},
{indent}                errorAction: {{ [weak strongSelf] in
{indent}                    guard let strongSelf = strongSelf else {{ return }}
{indent}                    strongSelf.present(UndoOverlayController(
{indent}                        presentationData: strongSelf.presentationData,
{indent}                        content: .info(title: nil, text: "Translation failed. Message not sent. Try again.", timeout: 5.0, customUndoText: nil),
{indent}                        elevatedLayout: true,
{indent}                        action: {{ _ in return false }}
{indent}                    ), in: .current)
{indent}                }}
{indent}            )
{indent}        }} else {{
{indent}            let _ = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: [aiMsg]).start()
{indent}        }}
{indent}    case .forward:
{indent}        let _ = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: [aiMsg]).start()
{indent}    }}
{indent}}}
{indent}signal = .single([])
{indent}// AI Translation: clear text input immediately since messages are enqueued asynchronously.
{indent}// setupSendActionOnViewUpdate() defers clearing until a Postbox view update, which won't
{indent}// happen until translation completes (1-3s). Bypass it by clearing directly.
{indent}if let textInputPanelNode = strongSelf.chatDisplayNode.inputPanelNode as? ChatTextInputPanelNode {{
{indent}    textInputPanelNode.text = ""
{indent}}}
{indent}// Cancel the deferred text clear from setupSendActionOnViewUpdate().
{indent}// Without this, the stored layoutActionOnViewTransition callback fires 1-3s later
{indent}// when the translated message enters Postbox, wiping any new text the user typed.
{indent}strongSelf.chatDisplayNode.historyNode.layoutActionOnViewTransition = nil"""

    content = content.replace(old_line, new_code, 1)

    with open(filepath, "w") as f:
        f.write(content)

    print(f"Patched enqueueMessages in {filepath} with AI translation hook")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_ChatControllerLoadDisplayNode.swift>")
        sys.exit(1)

    patch_load_display_node(sys.argv[1])
