#!/bin/bash
set -euo pipefail

TARGET_DIR="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PATCHES_DIR="${PROJECT_DIR}/telegram-ios/patches"

# Insert a line after the first occurrence of a pattern in a file.
# Uses Python for reliable cross-platform behavior (BSD sed's `a\` is buggy).
insert_after() {
    local file="$1"
    local pattern="$2"
    local new_line="$3"
    python3 -c "
import sys
with open(sys.argv[1], 'r') as f:
    lines = f.readlines()
found = False
result = []
for line in lines:
    result.append(line)
    if not found and sys.argv[2] in line.rstrip():
        result.append(sys.argv[3] + '\n')
        found = True
with open(sys.argv[1], 'w') as f:
    f.writelines(result)
if not found:
    print(f'WARNING: pattern \"{sys.argv[2]}\" not found in {sys.argv[1]}')
" "$file" "$pattern" "$new_line"
}

echo "Applying modifications to ${TARGET_DIR}..."

# 1. Add AITranslation dependency to TelegramUI/BUILD
echo "  [1/17] Adding AITranslation to TelegramUI/BUILD deps..."
BUILD_FILE="${TARGET_DIR}/submodules/TelegramUI/BUILD"
if grep -q "AITranslation" "$BUILD_FILE" 2>/dev/null; then
    echo "    Already present, skipping."
else
    insert_after "$BUILD_FILE" "deps = [" '        "//submodules/AITranslation:AITranslation",'
    echo "    Done."
fi

# 2. Add import + registration to AppDelegate.swift
echo "  [2/17] Patching AppDelegate.swift..."
APPDELEGATE="${TARGET_DIR}/submodules/TelegramUI/Sources/AppDelegate.swift"
if grep -q "import AITranslation" "$APPDELEGATE" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    insert_after "$APPDELEGATE" "import UIKit" "import AITranslation"
    insert_after "$APPDELEGATE" "testIsLaunched = true" "        registerAITranslationService()"
    echo "    Done."
fi

# 3. Patch EnqueueMessage.swift to whitelist TranslationMessageAttribute
echo "  [3/17] Patching EnqueueMessage.swift message attribute filter..."
ENQUEUE_MSG="${TARGET_DIR}/submodules/TelegramCore/Sources/PendingMessages/EnqueueMessage.swift"
if grep -q "case _ as TranslationMessageAttribute" "$ENQUEUE_MSG" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_enqueue_message_filter.py" "$ENQUEUE_MSG"
    echo "    Done."
fi

# 4. Auto-enable incoming translation state in ChatControllerLoadDisplayNode
echo "  [4/17] Enabling auto-incoming translation state..."
LOAD_DISPLAY_NODE="${TARGET_DIR}/submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift"
if grep -q "AI Translation: auto-enable incoming translation" "$LOAD_DISPLAY_NODE" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    # Add import first (needed for both this and step 5)
    if ! grep -q "import AITranslation" "$LOAD_DISPLAY_NODE" 2>/dev/null; then
        insert_after "$LOAD_DISPLAY_NODE" "import UIKit" "import AITranslation"
    fi
    python3 "${SCRIPT_DIR}/patch_incoming_translation.py" "$LOAD_DISPLAY_NODE"
    echo "    Done."
fi

# 5. Patch ChatControllerLoadDisplayNode.swift for main text input translation (fire-and-forget)
echo "  [5/17] Patching ChatControllerLoadDisplayNode.swift for outgoing translation..."
if grep -q "AI Translation: fire-and-forget" "$LOAD_DISPLAY_NODE" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    # import AITranslation should already be added by step 4, but ensure it
    if ! grep -q "import AITranslation" "$LOAD_DISPLAY_NODE" 2>/dev/null; then
        insert_after "$LOAD_DISPLAY_NODE" "import UIKit" "import AITranslation"
    fi
    python3 "${SCRIPT_DIR}/patch_load_display_node.py" "$LOAD_DISPLAY_NODE"
    echo "    Done."
fi

# 6. Patch ChatHistoryListNode.swift for incoming translation
echo "  [6/17] Patching ChatHistoryListNode.swift for incoming translation..."
HISTORY_LIST_NODE="${TARGET_DIR}/submodules/TelegramUI/Sources/ChatHistoryListNode.swift"
if grep -q "AI Translation: force-enable incoming" "$HISTORY_LIST_NODE" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_chat_history_list_node.py" "$HISTORY_LIST_NODE"
    echo "    Done."
fi

# 7. Reduce incoming translation throttle delay
echo "  [7/17] Reducing translation throttle delay..."
if grep -q "delay: 0.1" "$HISTORY_LIST_NODE" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_translation_throttle.py" "$HISTORY_LIST_NODE"
    echo "    Done."
fi

# 8. Patch PeerInfoScreen to add Translation Proxy settings entry
echo "  [8/17] Patching PeerInfoScreen for Translation Proxy settings..."
PEERINFO="${TARGET_DIR}/submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift"
if grep -q "import AITranslation" "$PEERINFO" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_peerinfo_settings.py" "$TARGET_DIR"
    echo "    Done."
fi

# 9. Patch Translate.swift to always use our translation service
echo "  [9/17] Patching Translate.swift for AI translation service..."
TRANSLATE_SWIFT="${TARGET_DIR}/submodules/TelegramCore/Sources/TelegramEngine/Messages/Translate.swift"
if ! grep -q "enableLocalIfPossible" "$TRANSLATE_SWIFT" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_translate_engine.py" "$TRANSLATE_SWIFT"
    echo "    Done."
fi

# 10. Patch ApplyUpdateMessage.swift to preserve TranslationMessageAttribute during server sync
echo "  [10/17] Patching ApplyUpdateMessage.swift..."
APPLY_UPDATE="${TARGET_DIR}/submodules/TelegramCore/Sources/State/ApplyUpdateMessage.swift"
if grep -q "Preserve local TranslationMessageAttribute" "$APPLY_UPDATE" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_apply_update_message.py" "$APPLY_UPDATE"
    echo "    Done."
fi

# 11. Add AITranslation dependency to ChatMessageTextBubbleContentNode BUILD
echo "  [11/17] Adding AITranslation dep to ChatMessageTextBubbleContentNode BUILD..."
TEXT_BUBBLE_BUILD="${TARGET_DIR}/submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/BUILD"
if grep -q "AITranslation" "$TEXT_BUBBLE_BUILD" 2>/dev/null; then
    echo "    Already present, skipping."
else
    insert_after "$TEXT_BUBBLE_BUILD" "deps = [" '        "//submodules/AITranslation:AITranslation",'
    echo "    Done."
fi

# 12. Patch ChatMessageTextBubbleContentNode.swift for translation display
echo "  [12/17] Patching ChatMessageTextBubbleContentNode.swift..."
TEXT_BUBBLE="${TARGET_DIR}/submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift"
if grep -q "three-way translateToLanguage fallback" "$TEXT_BUBBLE" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_text_bubble.py" "$TEXT_BUBBLE"
    echo "    Done."
fi

# 13. Patch ChatListItemStrings.swift for translated chat list preview
echo "  [13/17] Patching ChatListItemStrings.swift..."
CHAT_LIST_STRINGS="${TARGET_DIR}/submodules/ChatListUI/Sources/Node/ChatListItemStrings.swift"
if grep -q "TranslationMessageAttribute" "$CHAT_LIST_STRINGS" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_chat_list_strings.py" "$CHAT_LIST_STRINGS"
    echo "    Done."
fi

# 14. Patch ApplicationContext.swift for background incoming translation
echo "  [14/17] Patching ApplicationContext.swift for background translation..."
APP_CONTEXT="${TARGET_DIR}/submodules/TelegramUI/Sources/ApplicationContext.swift"
if grep -q "AIBackgroundTranslationObserver" "$APP_CONTEXT" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_application_context.py" "$APP_CONTEXT"
    echo "    Done."
fi

# 15. Patch AccountStateManager.swift for background translation callback
echo "  [15/17] Patching AccountStateManager.swift for background translation callback..."
ACCOUNT_STATE_MGR="${TARGET_DIR}/submodules/TelegramCore/Sources/State/AccountStateManager.swift"
if grep -q "aiNewIncomingMessagesCallback" "$ACCOUNT_STATE_MGR" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_account_state_manager.py" "$ACCOUNT_STATE_MGR"
    echo "    Done."
fi

# 16. Hide translation pop-up bar in ChatControllerNode
echo "  [16/20] Hiding translation bar in ChatControllerNode.swift..."
CHAT_CTRL_NODE="${TARGET_DIR}/submodules/TelegramUI/Sources/ChatControllerNode.swift"
if grep -q "AI Translation: hide translation bar" "$CHAT_CTRL_NODE" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_hide_translation_bar.py" "$CHAT_CTRL_NODE"
    echo "    Done."
fi

# 17. Patch ChatController.swift for media caption translation
echo "  [17/20] Patching ChatController.swift for media caption translation..."
CHAT_CTRL="${TARGET_DIR}/submodules/TelegramUI/Sources/ChatController.swift"
if grep -q "AI Translation: media caption translation guard" "$CHAT_CTRL" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_chat_controller.py" "$CHAT_CTRL"
    echo "    Done."
fi

# 18. Remove Devices and Privacy settings entries
echo "  [18/20] Removing Devices and Privacy settings entries..."
if grep -q "AI Translation: removed Devices setting" "$PEERINFO" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_remove_settings.py" "$PEERINFO"
    echo "    Done."
fi

# 19. Hide Telegram Service Notifications chat (peer 777000)
echo "  [19/20] Hiding Service Notifications chat from chat list..."
CHAT_LIST_ENTRIES="${TARGET_DIR}/submodules/ChatListUI/Sources/Node/ChatListNodeEntries.swift"
if grep -q "AI Translation: hide service notifications" "$CHAT_LIST_ENTRIES" 2>/dev/null; then
    echo "    Already patched, skipping."
else
    python3 "${SCRIPT_DIR}/patch_hide_service_chat.py" "$CHAT_LIST_ENTRIES"
    echo "    Done."
fi

# 20. Apply any additional .patch files
echo "  [20/20] Applying additional patch files..."
PATCH_COUNT=0
for patch_file in "${PATCHES_DIR}"/*.patch; do
    [ -f "$patch_file" ] || continue
    patch_name="$(basename "$patch_file")"
    echo "    Applying: ${patch_name}"
    if (cd "$TARGET_DIR" && git apply --check "$patch_file" 2>/dev/null); then
        (cd "$TARGET_DIR" && git apply "$patch_file")
        PATCH_COUNT=$((PATCH_COUNT + 1))
        echo "      OK"
    else
        echo "      WARNING: Patch ${patch_name} could not apply cleanly, skipping."
    fi
done
echo "    Additional patches applied: ${PATCH_COUNT}"

echo ""
echo "All modifications applied successfully."
