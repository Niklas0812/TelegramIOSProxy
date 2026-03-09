#!/usr/bin/env python3
"""Patch ChatMessageInteractiveFileNode.swift to auto-translate audio transcriptions.

When a voice message is transcribed (user presses "A" button), Telegram's rendering
code already checks for TranslationMessageAttribute and displays translated text
when translateToLanguage is set. This patch triggers our translation service when
a transcription is displayed without a translation (isTranslating == true).

The translation is stored as TranslationMessageAttribute, which Telegram's rendering
code picks up automatically on re-render — shimmer stops, English text shown.
"""
import sys


def patch_transcription_translation(filepath: str) -> None:
    with open(filepath, "r") as f:
        content = f.read()

    # 1. Add import AITranslation
    if "import AITranslation" not in content:
        content = content.replace("import UIKit", "import UIKit\nimport AITranslation", 1)
        print("Added import AITranslation")

    if "// AI Translation: auto-translate audio transcription" in content:
        print("Already patched, skipping.")
        return

    # 2. Inject translation trigger after updateIsTranslating(isTranslating)
    # Target: strongSelf.updateIsTranslating(isTranslating)
    target = "strongSelf.updateIsTranslating(isTranslating)"

    if target not in content:
        print("ERROR: Could not find updateIsTranslating call in ChatMessageInteractiveFileNode.swift")
        print("Audio transcription translation will NOT work.")
        return

    injection = """strongSelf.updateIsTranslating(isTranslating)

                            // AI Translation: auto-translate audio transcription
                            if isTranslating, let aiContext = strongSelf.context, let aiArgs = strongSelf.arguments {
                                let aiTranscription = transcribedText(message: aiArgs.message)
                                if case let .success(aiText, false) = aiTranscription {
                                    AIBackgroundTranslationObserver.translateTranscription(
                                        messageId: aiArgs.message.id,
                                        text: aiText,
                                        peerId: aiArgs.message.id.peerId,
                                        context: aiContext
                                    )
                                }
                            }"""

    content = content.replace(target, injection, 1)

    with open(filepath, "w") as f:
        f.write(content)

    print(f"Patched {filepath}: audio transcription auto-translation")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_ChatMessageInteractiveFileNode.swift>")
        sys.exit(1)

    patch_transcription_translation(sys.argv[1])
