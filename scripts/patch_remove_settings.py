#!/usr/bin/env python3
"""Remove 'Devices' and 'Privacy and Security' settings entries from PeerInfoScreen.swift.

Removes the items[...].append(...) blocks that create these two buttons in the
Telegram settings screen. The openSettings() case handlers are left in place
(they just never get called since the buttons are gone).
"""
import sys
import re


def patch_remove_settings(filepath: str) -> None:
    with open(filepath, "r") as f:
        content = f.read()

    if "// AI Translation: removed Devices setting" in content:
        print("Already patched, skipping.")
        return

    original_len = len(content)

    # Remove "Devices" entry — matches the multi-line items[...].append(...) block
    # containing Settings_Devices. Uses [\s\S]*? for nested parentheses (label: .text(...))
    devices_pattern = re.compile(
        r'\n\s*items\[[^\]]+\]!\s*\.append\(PeerInfoScreenDisclosureItem\([\s\S]*?'
        r'Settings_Devices[\s\S]*?'
        r'interaction\.openSettings\(\.devices\)\s*\n\s*\}\)\)',
        re.DOTALL
    )
    match = devices_pattern.search(content)
    if match:
        content = content[:match.start()] + "\n        // AI Translation: removed Devices setting" + content[match.end():]
        print("Removed Devices settings entry")
    else:
        print("WARNING: Could not find Devices settings entry")

    # Remove "Privacy and Security" entry
    privacy_pattern = re.compile(
        r'\n\s*items\[[^\]]+\]!\s*\.append\(PeerInfoScreenDisclosureItem\([^)]*?'
        r'(?:Settings_PrivacySettings|PrivacySettings|privacyAndSecurity)[^)]*?'
        r'action:\s*\{[^}]*?\}\)\)',
        re.DOTALL
    )
    match = privacy_pattern.search(content)
    if match:
        content = content[:match.start()] + "\n        // AI Translation: removed Privacy and Security setting" + content[match.end():]
        print("Removed Privacy and Security settings entry")
    else:
        print("WARNING: Could not find Privacy and Security settings entry")

    if len(content) != original_len:
        with open(filepath, "w") as f:
            f.write(content)
        print(f"Patched {filepath}: removed settings entries")
    else:
        print("No changes made")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_PeerInfoScreen.swift>")
        sys.exit(1)

    patch_remove_settings(sys.argv[1])
