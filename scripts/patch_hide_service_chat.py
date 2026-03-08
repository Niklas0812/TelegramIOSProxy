#!/usr/bin/env python3
"""Hide Telegram Service Notifications chat (peer 777000) from the chat list.

Patches ChatListNodeEntries.swift to skip entries for peer ID 777000
in the chatListNodeEntriesForView() function. Uses the existing
"continue loop" pattern already present for pending removals.
"""
import sys
import re


def patch_hide_service_chat(filepath: str) -> None:
    with open(filepath, "r") as f:
        content = f.read()

    if "// AI Translation: hide service notifications" in content:
        print("Already patched, skipping.")
        return

    # The actual code has this pattern after peerId is extracted:
    #   if let peerId = peerId, state.pendingRemovalItemIds.contains(...) {
    #       continue loop
    #   }
    # We add our filter right before this existing filter.

    target = "if let peerId = peerId, state.pendingRemovalItemIds.contains"
    if target not in content:
        print("WARNING: Could not find pendingRemovalItemIds filter in ChatListNodeEntries.swift")
        print("Service Notifications chat will NOT be hidden.")
        return

    filter_code = (
        "// AI Translation: hide service notifications chat (peer 777000)\n"
        "        if let peerId = peerId, peerId.id._internalGetInt64Value() == 777000 {\n"
        "            continue loop\n"
        "        }\n"
        "        "
    )

    content = content.replace(target, filter_code + target, 1)

    with open(filepath, "w") as f:
        f.write(content)

    print(f"Patched {filepath}: hiding service notifications chat (peer 777000)")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_ChatListNodeEntries.swift>")
        sys.exit(1)

    patch_hide_service_chat(sys.argv[1])
