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

    # Remove "Devices" entry — find the line containing Settings_Devices and remove
    # the full 3-line append block (items[...].append(...\n...\n    }))
    devices_target = "presentationData.strings.Settings_Devices"
    if devices_target in content:
        # Find the line, then expand to the full append block
        idx = content.index(devices_target)
        # Walk back to find "items[" at line start
        block_start = content.rfind("\n", 0, idx)
        # Walk forward to find "}))""
        block_end = content.find("}))", idx) + 3
        if block_start >= 0 and block_end > 3:
            content = content[:block_start] + "\n        // AI Translation: removed Devices setting" + content[block_end:]
            print("Removed Devices settings entry")
        else:
            print("WARNING: Could not determine Devices block boundaries")
    else:
        print("WARNING: Could not find Devices settings entry")

    # Remove "Privacy and Security" entry — same approach
    privacy_target = "Settings_PrivacySettings"
    if privacy_target in content:
        idx = content.index(privacy_target)
        block_start = content.rfind("\n", 0, idx)
        block_end = content.find("}))", idx) + 3
        if block_start >= 0 and block_end > 3:
            content = content[:block_start] + "\n        // AI Translation: removed Privacy and Security setting" + content[block_end:]
            print("Removed Privacy and Security settings entry")
        else:
            print("WARNING: Could not determine Privacy block boundaries")
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
