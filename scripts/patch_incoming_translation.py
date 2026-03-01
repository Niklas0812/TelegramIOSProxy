#!/usr/bin/env python3
"""Patch ChatControllerLoadDisplayNode.swift for translation rendering + streaming catch-up.

Sets translationState(isEnabled: true) so Telegram's rendering code activates translation
display. The actual translation is handled by our streaming catch-up (not Telegram's batch
pipeline — AIExperimentalTranslationService is a no-op that returns empty results).
"""
import sys
import re


def patch_incoming_translation(filepath: str) -> None:
    with open(filepath, "r") as f:
        content = f.read()

    # Target line: presentationInterfaceState = presentationInterfaceState.updatedTranslationState(contentData.state.translationState)
    # We add our override right after it.

    target = "presentationInterfaceState = presentationInterfaceState.updatedTranslationState(contentData.state.translationState)"

    if target not in content:
        print("ERROR: Could not find updatedTranslationState line")
        print("Incoming auto-translation will NOT work.")
        return

    override_code = """presentationInterfaceState = presentationInterfaceState.updatedTranslationState(contentData.state.translationState)

            // AI Translation: enable translation rendering
            if AITranslationSettings.enabled && AITranslationSettings.autoTranslateIncoming {
                let existingState = presentationInterfaceState.translationState
                if existingState == nil || existingState?.isEnabled != true {
                    presentationInterfaceState = presentationInterfaceState.updatedTranslationState(
                        ChatPresentationTranslationState(isEnabled: true, fromLang: "de", toLang: "en")
                    )
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.updateChatPresentationInterfaceState(interactive: false) { state in
                            return state.updatedTranslationState(
                                ChatPresentationTranslationState(isEnabled: true, fromLang: "de", toLang: "en")
                            )
                        }
                    }
                }
                // Streaming catch-up: fires on EVERY chat open (deduped by catchUpInProgress set)
                if case let .peer(chatPeerId) = self.chatLocation {
                    AIBackgroundTranslationObserver.translateMessages(peerId: chatPeerId, context: self.context)
                }
            }"""

    content = content.replace(target, override_code, 1)

    with open(filepath, "w") as f:
        f.write(content)

    print(f"Patched {filepath}: translation rendering + streaming catch-up")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_ChatControllerLoadDisplayNode.swift>")
        sys.exit(1)

    patch_incoming_translation(sys.argv[1])
