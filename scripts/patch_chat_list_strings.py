#!/usr/bin/env python3
"""Patch ChatListItemStrings.swift to show translated text in chat list preview.

The chat list overview shows the last message preview using raw message.text.
When incoming messages are translated (TranslationMessageAttribute stored on the message),
the chat list preview still shows the original German text. This patch checks for
TranslationMessageAttribute and uses the translated text for the preview.

ChatListItemStrings is also used by the "/" quick reply preview dropdown
(CommandChatInputContextPanelNode constructs ChatListItem for each shortcut). This
patch also checks the quick reply translation cache so the dropdown displays English.
"""
import sys


def patch_chat_list_strings(filepath: str) -> None:
    with open(filepath, "r") as f:
        content = f.read()

    # Add import AITranslation — needed for AIBackgroundTranslationObserver lookup
    if "import AITranslation" not in content:
        # Try inserting after any existing import
        for anchor in ["import TelegramCore", "import Foundation", "import UIKit"]:
            if anchor in content:
                content = content.replace(anchor, f"{anchor}\nimport AITranslation", 1)
                print(f"Added import AITranslation after {anchor}")
                break

    # Target: the loop that extracts messageText from messages
    old = """        for message in messages {
            if !message.text.isEmpty {
                messageText = message.text
                break
            }
        }"""

    if old not in content:
        print("ERROR: Could not find messageText extraction loop in ChatListItemStrings.swift")
        print("Chat list preview will NOT show translated text.")
        return

    new = """        // AI Translation: quick reply cache fallback
        for message in messages {
            if !message.text.isEmpty {
                messageText = message.text
                if let translation = message.attributes.first(where: { $0 is TranslationMessageAttribute }) as? TranslationMessageAttribute, !translation.text.isEmpty {
                    messageText = translation.text
                } else if let qrEnglish = AIBackgroundTranslationObserver.quickReplyTranslations[message.id], !qrEnglish.isEmpty {
                    // Quick reply template: show the pre-translated English from our cache
                    messageText = qrEnglish
                }
                break
            }
        }"""

    content = content.replace(old, new, 1)

    with open(filepath, "w") as f:
        f.write(content)

    print(f"Patched {filepath}: chat list preview + quick reply dropdown now show translated text")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_ChatListItemStrings.swift>")
        sys.exit(1)

    patch_chat_list_strings(sys.argv[1])
