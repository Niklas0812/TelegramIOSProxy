#!/usr/bin/env python3
"""Fix fake provisioning profiles for Telegram-iOS builds.

This script handles three issues:
1. Creates missing profiles that Telegram/BUILD references but don't exist
   (e.g. BroadcastUpload.mobileprovision at release-11.13)
2. Fixes expired ExpirationDate (original profiles expired 2025-10-29)
3. Fixes entitlements in created profiles to match the correct bundle_id suffix
"""

import sys
import os
import re
import subprocess
import plistlib
import tempfile
import datetime
import shutil


# Expected mapping: profile name -> bundle_id suffix
PROFILE_SUFFIX_MAP = {
    'Telegram': '',
    'Share': '.Share',
    'Widget': '.Widget',
    'NotificationContent': '.NotificationContent',
    'NotificationService': '.NotificationService',
    'Intents': '.SiriIntents',
    'BroadcastUpload': '.BroadcastUpload',
    'WatchApp': '.watchkitapp',
    'WatchExtension': '.watchkitapp.watchkitextension',
}

TEAM_ID = '5RPK5SFG6M'
BUNDLE_ID = 'com.niklas.translategram2'

# Registered device UDIDs (must also be added in Apple Developer portal)
PROVISIONED_DEVICES = [
    '80dccdbc6d929e5c1dabf7208465a6532728614b',   # Tim's iPhone
    '00008030-00165014346B402E',                    # iPhone 11
    'cb3e3ebfa10b4aebbdb900c6a65bdd4209687f92',    # iPhone 8
    '00008110-001E48DE1E84401E',                    # New device 1
    '00008020001C2D1234567890ABCDEF12',             # New device 2
    '00008101-001679810E11001E',                    # New device 3
    '00008030-000145213C04802E',                    # New device 4
]


def create_missing_profiles(profiles_dir, telegram_build_path):
    """Create any missing .mobileprovision files by copying from an existing one."""
    with open(telegram_build_path, "r") as f:
        build_content = f.read()

    referenced = set(re.findall(
        r'@build_configuration//provisioning:(\w+)\.mobileprovision', build_content
    ))

    existing = set()
    for fname in os.listdir(profiles_dir):
        if fname.endswith('.mobileprovision'):
            existing.add(fname.replace('.mobileprovision', ''))

    missing = referenced - existing
    if not missing:
        print(f"[1] All {len(referenced)} referenced profiles exist")
        return

    # Use Share as template
    template = os.path.join(profiles_dir, "Share.mobileprovision")
    if not os.path.exists(template):
        template = os.path.join(profiles_dir, next(iter(existing)) + ".mobileprovision")

    for name in missing:
        dest = os.path.join(profiles_dir, f"{name}.mobileprovision")
        shutil.copyfile(template, dest)
        print(f"[1] Created missing profile: {name}.mobileprovision")


def extract_cert_der(p12_path):
    """Extract the DER-encoded certificate from a .p12 file."""
    p12_password = os.environ.get("P12_PASSWORD", "")
    # Extract PEM cert from p12
    pem = subprocess.check_output([
        "openssl", "pkcs12", "-in", p12_path,
        "-clcerts", "-nokeys", "-passin", f"pass:{p12_password}"
    ])
    # Convert PEM to DER
    proc = subprocess.run(
        ["openssl", "x509", "-outform", "der"],
        input=pem, capture_output=True
    )
    if proc.returncode != 0:
        raise RuntimeError(f"Failed to convert cert to DER: {proc.stderr.decode()}")
    return proc.stdout


def setup_keychain(p12_path):
    """Create a temporary keychain and import the signing certificate."""
    keychain_name = "fake-codesigning-temp.keychain"
    keychain_password = "temp_password_12345"

    # Delete if exists
    subprocess.run(["security", "delete-keychain", keychain_name], capture_output=True)

    subprocess.check_call([
        "security", "create-keychain", "-p", keychain_password, keychain_name
    ])
    subprocess.check_call(["security", "set-keychain-settings", keychain_name])
    subprocess.check_call([
        "security", "unlock-keychain", "-p", keychain_password, keychain_name
    ])

    p12_password = os.environ.get("P12_PASSWORD", "")
    subprocess.check_call([
        "security", "import", p12_path,
        "-k", keychain_name, "-P", p12_password,
        "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"
    ])

    # Add to search list
    result = subprocess.check_output(["security", "list-keychains", "-d", "user"])
    existing = [k.strip().strip(b'"').decode() for k in result.split(b'\n') if k.strip()]
    subprocess.check_call([
        "security", "list-keychains", "-d", "user", "-s", keychain_name
    ] + existing)

    subprocess.check_call([
        "security", "set-key-partition-list",
        "-S", "apple-tool:,apple:",
        "-s", "-k", keychain_password, keychain_name
    ])

    # Get signing identity
    identity_name = "Apple Distribution: Telegram FZ-LLC (C67CF9S4VU)"
    try:
        output = subprocess.check_output([
            "security", "find-identity", "-v", "-p", "codesigning", keychain_name
        ]).decode()
        for line in output.split('\n'):
            if '"' in line:
                identity_name = line.split('"')[1]
                break
    except Exception:
        pass

    print(f"[2] Using identity: {identity_name}")
    return keychain_name, identity_name


def fix_profiles(profiles_dir, keychain_name, identity_name, signing_cert_der):
    """Fix expiration date, entitlements, and DeveloperCertificates for all profiles."""
    new_expiration = datetime.datetime.now() + datetime.timedelta(days=3650)
    count = 0

    for fname in sorted(os.listdir(profiles_dir)):
        if not fname.endswith('.mobileprovision'):
            continue

        profile_name = fname.replace('.mobileprovision', '')
        file_path = os.path.join(profiles_dir, fname)

        try:
            plist_data = subprocess.check_output([
                "security", "cms", "-D", "-i", file_path
            ])
        except subprocess.CalledProcessError:
            print(f"  WARNING: Could not decode {fname}, skipping")
            continue

        profile_dict = plistlib.loads(plist_data)

        # Fix expiration date
        old_exp = profile_dict.get('ExpirationDate', 'unknown')
        profile_dict['ExpirationDate'] = new_expiration
        profile_dict['CreationDate'] = datetime.datetime.now()

        # Fix entitlements to match the expected bundle_id suffix
        if profile_name in PROFILE_SUFFIX_MAP:
            suffix = PROFILE_SUFFIX_MAP[profile_name]
            expected_app_id = f"{TEAM_ID}.{BUNDLE_ID}{suffix}"
            expected_name = f"match AppStore {BUNDLE_ID}{suffix}"

            entitlements = profile_dict.get('Entitlements', {})
            old_app_id = entitlements.get('application-identifier', '')

            entitlements['application-identifier'] = expected_app_id
            # Fix keychain access groups
            entitlements['keychain-access-groups'] = [expected_app_id]
            # Ensure app group entitlement is present (required for shared container)
            app_group_id = f"group.{BUNDLE_ID}"
            entitlements['com.apple.security.application-groups'] = [app_group_id]
            # Ensure get-task-allow for debug/sideload
            entitlements['get-task-allow'] = True

            profile_dict['Entitlements'] = entitlements
            profile_dict['Name'] = expected_name

            # Set provisioned devices so all registered devices can install
            profile_dict['ProvisionedDevices'] = list(PROVISIONED_DEVICES)

            # Fix ApplicationIdentifierPrefix if present
            if 'ApplicationIdentifierPrefix' in profile_dict:
                profile_dict['ApplicationIdentifierPrefix'] = [TEAM_ID]

        # Replace DeveloperCertificates with our self-signed cert so that
        # rules_apple's process-and-sign can match the identity in the keychain
        if signing_cert_der:
            profile_dict['DeveloperCertificates'] = [signing_cert_der]

        # Write modified plist
        with tempfile.NamedTemporaryFile(suffix='.plist', delete=False) as tmp:
            plistlib.dump(profile_dict, tmp)
            tmp_path = tmp.name

        try:
            with tempfile.NamedTemporaryFile(suffix='.mobileprovision', delete=False) as out:
                out_path = out.name

            subprocess.check_call([
                "security", "cms", "-S",
                "-N", identity_name,
                "-k", keychain_name,
                "-i", tmp_path,
                "-o", out_path
            ])

            os.replace(out_path, file_path)
            app_id = profile_dict['Entitlements']['application-identifier']
            print(f"  Fixed: {fname} (exp: {old_exp} -> {new_expiration.date()}, app-id: {app_id})")
            count += 1

        except subprocess.CalledProcessError as e:
            print(f"  WARNING: Could not re-sign {fname}: {e}")
            if os.path.exists(out_path):
                os.unlink(out_path)
        finally:
            os.unlink(tmp_path)

    print(f"\n[3] Fixed {count} profiles")


def main():
    if len(sys.argv) < 2:
        print("Usage: fix_profile_expiration.py <telegram-ios-build-dir>")
        sys.exit(1)

    build_dir = sys.argv[1]
    profiles_dir = os.path.join(build_dir, "build-system", "fake-codesigning", "profiles")
    certs_dir = os.path.join(build_dir, "build-system", "fake-codesigning", "certs")
    p12_path = os.path.join(certs_dir, "SelfSigned.p12")
    telegram_build = os.path.join(build_dir, "Telegram", "BUILD")

    if not os.path.exists(p12_path):
        print(f"ERROR: Certificate not found at {p12_path}")
        sys.exit(1)

    # Step 1: Create any missing profiles
    create_missing_profiles(profiles_dir, telegram_build)

    # Extract the DER-encoded signing certificate from the .p12
    signing_cert_der = extract_cert_der(p12_path)
    print(f"[1.5] Extracted signing cert ({len(signing_cert_der)} bytes)")

    # Step 2-3: Setup keychain and fix all profiles
    keychain_name = None
    try:
        keychain_name, identity_name = setup_keychain(p12_path)
        fix_profiles(profiles_dir, keychain_name, identity_name, signing_cert_der)
    finally:
        if keychain_name:
            subprocess.run(["security", "delete-keychain", keychain_name], capture_output=True)

    print("\nAll profile fixes applied successfully.")


if __name__ == "__main__":
    main()
