#!/usr/bin/env python3
"""Clear the IntentsSupported list in Telegram's SiriIntents extension.

Apple validator error 90626 ("No example phrase was provided for
INSomethingIntent in <lang>") fires when an Intents extension declares support
for an INIntent subclass in its `NSExtension.NSExtensionAttributes.IntentsSupported`
array without shipping example phrases for every declared locale. Telegram's
bundled Intents.strings files don't cover every (intent x locale) combination,
so each missing pair produces one warning.

The simplest way to eliminate every 90626 warning at once is to remove all
entries from the IntentsSupported array. That makes the extension decline to
handle those intents (SiriKit falls back to offering the app via the default
launch mechanism), which is acceptable for our TestFlight-only build — we
don't depend on Siri voice invocation for anything this project adds.
"""
import plistlib
import sys


def patch_intents_plist(filepath: str) -> None:
    with open(filepath, "rb") as f:
        p = plistlib.load(f)

    ext = p.get("NSExtension") or {}
    attrs = ext.get("NSExtensionAttributes") or {}

    intents = attrs.get("IntentsSupported")
    restricted = attrs.get("IntentsRestrictedWhileLocked")

    changed = False
    if intents:
        print(f"Clearing IntentsSupported (was {len(intents)} entries): {intents}")
        attrs["IntentsSupported"] = []
        changed = True
    if restricted:
        print(f"Clearing IntentsRestrictedWhileLocked (was {len(restricted)} entries): {restricted}")
        attrs["IntentsRestrictedWhileLocked"] = []
        changed = True

    if not changed:
        print("Already empty, skipping.")
        return

    ext["NSExtensionAttributes"] = attrs
    p["NSExtension"] = ext

    with open(filepath, "wb") as f:
        plistlib.dump(p, f)

    print(f"Patched {filepath}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path_to_IntentsExtension_Info.plist>")
        sys.exit(1)
    patch_intents_plist(sys.argv[1])
