#!/usr/bin/env python3
"""Add missing NSLocationAlwaysAndWhenInUseUsageDescription to the main app's
Info.plist.

Telegram iOS' source plist ships only the pre-iOS-11 keys
(`NSLocationAlwaysUsageDescription` + `NSLocationWhenInUseUsageDescription`).
App Store Connect validation warns (error 90683) that apps referencing
"always" location APIs on iOS 11+ MUST also declare
`NSLocationAlwaysAndWhenInUseUsageDescription`, and iOS silently blocks
TestFlight installation when it's missing ("The requested app is not available
or does not exist.").
"""
import plistlib
import sys


NEW_KEY = "NSLocationAlwaysAndWhenInUseUsageDescription"
# Re-use the text of the existing "when in use" string so the user sees a
# consistent explanation for the upgraded always+whenInUse permission.
FALLBACK = (
    "When you send your location to your friends, Telegram needs access to "
    "show them your coordinates. We do not collect location information "
    "otherwise."
)


def patch_info_plist(filepath: str) -> None:
    with open(filepath, "rb") as f:
        p = plistlib.load(f)

    if NEW_KEY in p and p[NEW_KEY]:
        print(f"Already has {NEW_KEY}, skipping.")
        return

    # Borrow the existing WhenInUse description if present for consistency,
    # otherwise use FALLBACK.
    p[NEW_KEY] = p.get("NSLocationWhenInUseUsageDescription") or FALLBACK

    with open(filepath, "wb") as f:
        plistlib.dump(p, f)

    print(f"Added {NEW_KEY} to {filepath}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_Info.plist>")
        sys.exit(1)
    patch_info_plist(sys.argv[1])
