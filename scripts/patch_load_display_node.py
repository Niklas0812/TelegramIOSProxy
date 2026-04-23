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
            print("FATAL: Could not find enqueueMessages call for transformedMessages")
            print("The outgoing translation hook for typed messages will NOT work.")
            sys.exit(1)
        old_line = match.group(0)
        indent = match.group(1)
    else:
        indent = "                        "

    new_code = f"""{indent}// AI Translation: claim guard — decouples claim registration from translation.
{indent}// Fires /claim for every outgoing send on this path (typed text + forwards).
{indent}// The subsequent existing logic only runs if the claim is allowed (or the
{indent}// backend is unreachable — fail-open so users aren't blocked from sending
{indent}// when the proxy is down).
{indent}AILogger.log("OUT-PATH [typed-or-forward]: peer=\\(peerId.id._internalGetInt64Value()) msgCount=\\(transformedMessages.count)")
{indent}signal = AITranslationService.shared.applyClaimGuard(chatId: peerId, context: strongSelf.context)
{indent}|> deliverOnMainQueue
{indent}|> mapToSignal {{ [weak strongSelf] claimResult -> Signal<[MessageId?], NoError> in
{indent}    guard let strongSelf = strongSelf else {{ return .complete() }}
{indent}    if case let .blocked(claimedBy) = claimResult {{
{indent}        AILogger.log("POPUP SHOWN: claim blocked [typed-or-forward] peer=\\(peerId.id._internalGetInt64Value()) claimed_by=\\(claimedBy)")
{indent}        strongSelf.present(UndoOverlayController(
{indent}            presentationData: strongSelf.presentationData,
{indent}            content: .info(title: nil, text: "This user was already claimed by someone else!", timeout: 5.0, customUndoText: nil),
{indent}            elevatedLayout: true,
{indent}            action: {{ _ in return false }}
{indent}        ), in: .current)
{indent}        return .single([])
{indent}    }}
{indent}    // Original logic — only runs when claim guard allows (or network error / fail-open).
{indent}    let aiNeedsTranslation = transformedMessages.contains(where: {{
{indent}        if case let .message(text, _, _, _, _, _, _, _, _, _) = $0 {{
{indent}            return !text.isEmpty && AITranslationSettings.enabled && AITranslationSettings.autoTranslateOutgoing && !AIBackgroundTranslationObserver.botChatIds.contains(peerId.id._internalGetInt64Value()) && (AITranslationSettings.enabledChatIds.isEmpty || AITranslationSettings.enabledChatIds.contains(peerId.id._internalGetInt64Value()))
{indent}        }}
{indent}        return false
{indent}    }})
{indent}    AILogger.log("PATCH: aiNeedsTranslation=\\(aiNeedsTranslation) msgCount=\\(transformedMessages.count) peer=\\(peerId.id._internalGetInt64Value()) enabled=\\(AITranslationSettings.enabled) outgoing=\\(AITranslationSettings.autoTranslateOutgoing)")
{indent}    if aiNeedsTranslation {{
{indent}        // Chronological queue with cascading failure.
{indent}        // Forwards + text-free messages are batched together to preserve album grouping.
{indent}        var aiPassthroughMessages: [EnqueueMessage] = []
{indent}        for aiMsg in transformedMessages {{
{indent}            switch aiMsg {{
{indent}            case let .message(text, attributes, inlineStickers, mediaReference, threadId, replyToMessageId, replyToStoryId, localGroupingKey, correlationId, bubbleUpEmojiOrStickersets):
{indent}                if !text.isEmpty && AITranslationSettings.enabled && AITranslationSettings.autoTranslateOutgoing && !AIBackgroundTranslationObserver.botChatIds.contains(peerId.id._internalGetInt64Value()) && (AITranslationSettings.enabledChatIds.isEmpty || AITranslationSettings.enabledChatIds.contains(peerId.id._internalGetInt64Value())) {{
{indent}                    let aiItemFp = SendFingerprint.build(
{indent}                        peerId: peerId,
{indent}                        text: text,
{indent}                        media: mediaReference?.media,
{indent}                        replyToMessageId: replyToMessageId,
{indent}                        replyToStoryId: replyToStoryId,
{indent}                        localGroupingKey: localGroupingKey
{indent}                    )
{indent}                    let _ = AIOutgoingMessageQueue.shared.enqueue(
{indent}                        peerId: peerId,
{indent}                        fingerprint: aiItemFp,
{indent}                        kind: .translate(text: text),
{indent}                        context: strongSelf.context,
{indent}                        sendAction: {{ [weak strongSelf] translatedText -> Bool in
{indent}                            guard let strongSelf = strongSelf else {{ return false }}
{indent}                            var newAttributes = attributes
{indent}                            newAttributes.append(TranslationMessageAttribute(text: text, entities: [], toLang: "en"))
{indent}                            let _ = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: [.message(text: translatedText, attributes: newAttributes, inlineStickers: inlineStickers, mediaReference: mediaReference, threadId: threadId, replyToMessageId: replyToMessageId, replyToStoryId: replyToStoryId, localGroupingKey: localGroupingKey, correlationId: correlationId, bubbleUpEmojiOrStickersets: bubbleUpEmojiOrStickersets)]).start()
{indent}                            return true
{indent}                        }},
{indent}                        restoreAction: {{ [weak strongSelf] originalText in
{indent}                            guard let strongSelf = strongSelf else {{ return }}
{indent}                            if let textInputPanelNode = strongSelf.chatDisplayNode.inputPanelNode as? ChatTextInputPanelNode {{
{indent}                                if textInputPanelNode.text.isEmpty {{
{indent}                                    textInputPanelNode.text = originalText
{indent}                                }}
{indent}                            }}
{indent}                        }},
{indent}                        errorAction: {{ [weak strongSelf] message in
{indent}                            guard let strongSelf = strongSelf else {{ return }}
{indent}                            AILogger.log("POPUP SHOWN: \\(message)")
{indent}                            strongSelf.present(UndoOverlayController(
{indent}                                presentationData: strongSelf.presentationData,
{indent}                                content: .info(title: nil, text: message, timeout: 5.0, customUndoText: nil),
{indent}                                elevatedLayout: true,
{indent}                                action: {{ _ in return false }}
{indent}                            ), in: .current)
{indent}                        }}
{indent}                    )
{indent}                }} else {{
{indent}                    aiPassthroughMessages.append(aiMsg)
{indent}                }}
{indent}            case .forward:
{indent}                aiPassthroughMessages.append(aiMsg)
{indent}            }}
{indent}        }}
{indent}        if !aiPassthroughMessages.isEmpty {{
{indent}            let aiPassFp = SendFingerprint.buildBatch(peerId: peerId, messages: aiPassthroughMessages)
{indent}            let aiPassMessages = aiPassthroughMessages
{indent}            let _ = AIOutgoingMessageQueue.shared.enqueue(
{indent}                peerId: peerId,
{indent}                fingerprint: aiPassFp,
{indent}                kind: .passthrough(text: ""),
{indent}                context: strongSelf.context,
{indent}                sendAction: {{ [weak strongSelf] _ -> Bool in
{indent}                    guard let strongSelf = strongSelf else {{ return false }}
{indent}                    let _ = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: aiPassMessages).start()
{indent}                    return true
{indent}                }},
{indent}                restoreAction: {{ _ in }},
{indent}                errorAction: {{ [weak strongSelf] message in
{indent}                    guard let strongSelf = strongSelf else {{ return }}
{indent}                    AILogger.log("POPUP SHOWN: passthrough-batch — \\(message)")
{indent}                    strongSelf.present(UndoOverlayController(
{indent}                        presentationData: strongSelf.presentationData,
{indent}                        content: .info(title: nil, text: message, timeout: 5.0, customUndoText: nil),
{indent}                        elevatedLayout: true,
{indent}                        action: {{ _ in return false }}
{indent}                    ), in: .current)
{indent}                }}
{indent}            )
{indent}        }}
{indent}        if let textInputPanelNode = strongSelf.chatDisplayNode.inputPanelNode as? ChatTextInputPanelNode {{
{indent}            textInputPanelNode.text = ""
{indent}        }}
{indent}        strongSelf.chatDisplayNode.historyNode.layoutActionOnViewTransition = nil
{indent}        return .single([])
{indent}    }} else {{
{indent}        // No text needs translation — route the whole batch through the queue
{indent}        // as passthrough so it still takes its FIFO turn behind any earlier
{indent}        // translating messages for the same peer. Claim guard already fired.
{indent}        let aiElseFp = SendFingerprint.buildBatch(peerId: peerId, messages: transformedMessages)
{indent}        let aiElseMessages = transformedMessages
{indent}        let _ = AIOutgoingMessageQueue.shared.enqueue(
{indent}            peerId: peerId,
{indent}            fingerprint: aiElseFp,
{indent}            kind: .passthrough(text: ""),
{indent}            context: strongSelf.context,
{indent}            sendAction: {{ [weak strongSelf] _ -> Bool in
{indent}                guard let strongSelf = strongSelf else {{ return false }}
{indent}                let _ = enqueueMessages(account: strongSelf.context.account, peerId: peerId, messages: aiElseMessages).start()
{indent}                return true
{indent}            }},
{indent}            restoreAction: {{ _ in }},
{indent}            errorAction: {{ [weak strongSelf] message in
{indent}                guard let strongSelf = strongSelf else {{ return }}
{indent}                AILogger.log("POPUP SHOWN: no-translate — \\(message)")
{indent}                strongSelf.present(UndoOverlayController(
{indent}                    presentationData: strongSelf.presentationData,
{indent}                    content: .info(title: nil, text: message, timeout: 5.0, customUndoText: nil),
{indent}                    elevatedLayout: true,
{indent}                    action: {{ _ in return false }}
{indent}                ), in: .current)
{indent}            }}
{indent}        )
{indent}        return .single([])
{indent}    }}
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
