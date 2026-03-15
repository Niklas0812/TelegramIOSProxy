#!/usr/bin/env python3
"""Patch AppDelegate.swift to translate notification replies before sending.

When a user replies to a message from the iOS notification banner (without
opening the app), AppDelegate calls enqueueMessages() directly — bypassing
all our translation patches in ChatControllerLoadDisplayNode and ChatController.

This patch wraps the enqueueMessages call with a translation step:
1. Check if translation is enabled + autoTranslateOutgoing
2. If yes, call AIProxyClient to translate EN→DE
3. Send the translated text (or original on failure)
"""
import sys
import re


def patch_notification_reply(filepath: str) -> None:
    with open(filepath, "r") as f:
        content = f.read()

    if "AI Translation: translate notification reply" in content:
        print("Already patched, skipping.")
        return

    # Add import AITranslation if not present
    if "import AITranslation" not in content:
        content = content.replace("import UIKit", "import UIKit\nimport AITranslation", 1)
        print("Added import AITranslation")

    # Find the exact enqueueMessages call in the notification reply handler
    # Pattern: return enqueueMessages(account: account, peerId: peerId, messages: [EnqueueMessage.message(text: text, ...
    old_pattern = (
        'return enqueueMessages(account: account, peerId: peerId, messages: '
        '[EnqueueMessage.message(text: text, attributes: [], inlineStickers: [:], '
        'mediaReference: nil, threadId: nil, replyToMessageId: replyToMessageId.flatMap '
        '{ EngineMessageReplySubject(messageId: $0, quote: nil) }, replyToStoryId: nil, '
        'localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])'
    )

    if old_pattern not in content:
        print("FATAL: Could not find enqueueMessages in notification reply handler")
        print("Notification reply translation will NOT work.")
        sys.exit(1)

    new_code = """// AI Translation: translate notification reply before sending
                        let aiReplyToMessageId = replyToMessageId
                        if AITranslationSettings.enabled && AITranslationSettings.autoTranslateOutgoing && !AIBackgroundTranslationObserver.botChatIds.contains(peerId.id._internalGetInt64Value()) {
                            return AIProxyClient.shared.translateStrict(
                                text: text,
                                direction: "outgoing",
                                chatId: peerId.id._internalGetInt64Value(),
                                context: []
                            )
                            |> mapToSignal { translatedText -> Signal<[MessageId?], NoError> in
                                let finalText = translatedText ?? text
                                var attributes: [MessageAttribute] = []
                                if let translatedText = translatedText {
                                    attributes.append(TranslationMessageAttribute(text: text, entities: [], toLang: "en"))
                                    let _ = finalText
                                }
                                return enqueueMessages(account: account, peerId: peerId, messages: [EnqueueMessage.message(text: finalText, attributes: attributes, inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: aiReplyToMessageId.flatMap { EngineMessageReplySubject(messageId: $0, quote: nil) }, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])
                            }
                        }
                        return enqueueMessages(account: account, peerId: peerId, messages: [EnqueueMessage.message(text: text, attributes: [], inlineStickers: [:], mediaReference: nil, threadId: nil, replyToMessageId: replyToMessageId.flatMap { EngineMessageReplySubject(messageId: $0, quote: nil) }, replyToStoryId: nil, localGroupingKey: nil, correlationId: nil, bubbleUpEmojiOrStickersets: [])])"""

    content = content.replace(old_pattern, new_code, 1)

    with open(filepath, "w") as f:
        f.write(content)

    print(f"Patched {filepath}: notification reply translation")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_AppDelegate.swift>")
        sys.exit(1)

    patch_notification_reply(sys.argv[1])
