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

    # Remove "Devices" entry — the append block AND the devicesLabel variable
    # (Swift treats unused variables as errors with -whole-module-optimization)
    devices_target = "presentationData.strings.Settings_Devices"
    if devices_target in content:
        # 1. Remove the items[].append() block
        idx = content.index(devices_target)
        block_start = content.rfind("\n", 0, idx)
        block_end = content.find("}))", idx) + 3
        if block_start >= 0 and block_end > 3:
            content = content[:block_start] + "\n        // AI Translation: removed Devices setting" + content[block_end:]
            print("Removed Devices settings entry")

        # 2. Remove the devicesLabel variable declaration + if/else block
        devices_label_target = "let devicesLabel: String"
        if devices_label_target in content:
            dl_idx = content.index(devices_label_target)
            dl_start = content.rfind("\n", 0, dl_idx)
            # Find the closing "}" of the outer if/else, then the empty line after
            # Pattern: let devicesLabel ... if ... { ... } else { ... }
            # Count braces to find the matching close
            brace_start = content.find("{", dl_idx)
            if brace_start >= 0:
                depth = 0
                pos = brace_start
                while pos < len(content):
                    if content[pos] == "{":
                        depth += 1
                    elif content[pos] == "}":
                        depth -= 1
                        if depth == 0:
                            # Found outermost closing brace
                            dl_end = pos + 1
                            content = content[:dl_start] + content[dl_end:]
                            print("Removed devicesLabel variable")
                            break
                    pos += 1
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
