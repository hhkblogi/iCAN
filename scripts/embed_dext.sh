#!/bin/bash
# embed_dext.sh — Called from copy_outputs.sh (injected by post_build hook).
# Embeds the .dext DriverKit extension into the app bundle and re-signs
# for device deployment. Bazel BwB mode signs ad-hoc; this script re-signs
# with a real Apple Development identity + complete entitlements.
#
# Only acts on the iCAN product; skips other targets and simulator builds.
#
# Values are derived at runtime — no hardcoded team IDs, bundle IDs, or
# profile UUIDs. The script reads from:
#   - Built app/dext Info.plists (bundle IDs)
#   - Source .entitlements files (custom entitlements)
#   - Provisioning profiles directory (auto-discovered by bundle ID)
#   - Keychain (signing identity)

[[ "${PRODUCT_NAME:-}" == "iCAN" ]] || exit 0
[[ "$PLATFORM_NAME" == *simulator* ]] && exit 0
[[ "$ACTION" == "indexbuild" ]] && exit 0

APP="$TARGET_BUILD_DIR/$PRODUCT_NAME.app"
[ -d "$APP" ] || exit 0

# Temp file cleanup on any exit
TMPFILES=()
cleanup() { rm -f "${TMPFILES[@]}"; }
trap cleanup EXIT

cd "$SRCROOT"
BAZEL="${BAZEL_PATH:-/opt/homebrew/bin/bazel}"

# Build the dext if needed (incremental — fast when already cached)
"$BAZEL" build //usb_can_driver:USBCANDriver 2>&1

DEXT="$("$BAZEL" info bazel-bin 2>/dev/null)/usb_can_driver/USBCANDriver.dext"
[ -d "$DEXT" ] || DEXT="bazel-bin/usb_can_driver/USBCANDriver.dext"
[ -d "$DEXT" ] || { echo "warning: USBCANDriver.dext not found, skipping embed" >&2; exit 0; }

# Copy dext into app bundle
mkdir -p "$APP/SystemExtensions"
rsync -a --delete "$DEXT/" "$APP/SystemExtensions/USBCANDriver.dext/"
chmod -R u+w "$APP/SystemExtensions/USBCANDriver.dext"
chmod -R u+w "$APP"

# Read bundle IDs from built bundles
APP_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist" 2>/dev/null)
DEXT_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/SystemExtensions/USBCANDriver.dext/Info.plist" 2>/dev/null)
[ -n "$APP_BUNDLE_ID" ] || { echo "error: cannot read app bundle ID" >&2; exit 1; }
[ -n "$DEXT_BUNDLE_ID" ] || { echo "error: cannot read dext bundle ID" >&2; exit 1; }

# Auto-discover dext provisioning profile by bundle ID
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
DEXT_PROFILE=""
if [ -d "$PROFILES_DIR" ]; then
    # Search both .provisionprofile (macOS) and .mobileprovision (iOS) extensions
    for f in "$PROFILES_DIR"/*.provisionprofile "$PROFILES_DIR"/*.mobileprovision; do
        [ -f "$f" ] || continue
        appid=$(security cms -D -i "$f" 2>/dev/null | \
            xmllint --xpath '//key[text()="application-identifier"]/following-sibling::string[1]/text()' - 2>/dev/null)
        if [[ "$appid" == *"$DEXT_BUNDLE_ID" ]]; then
            DEXT_PROFILE="$f"
            break
        fi
    done
fi

if [ -n "$DEXT_PROFILE" ]; then
    cp "$DEXT_PROFILE" "$APP/SystemExtensions/USBCANDriver.dext/embedded.provisionprofile"
    # Extract team ID from the profile
    TEAM_ID=$(security cms -D -i "$DEXT_PROFILE" 2>/dev/null | \
        xmllint --xpath '//key[text()="TeamIdentifier"]/following-sibling::array[1]/string[1]/text()' - 2>/dev/null)
else
    echo "warning: no provisioning profile found for $DEXT_BUNDLE_ID" >&2
    echo "  iPad will not show the 'Enable extensions' toggle in Settings > Privacy & Security" >&2
    echo "  Fix: open iCAN.xcodeproj, build USBCANDriver target once to download profile" >&2
fi

# Auto-discover and embed the app provisioning profile (replace Bazel's ad-hoc one)
APP_PROFILE=""
if [ -d "$PROFILES_DIR" ]; then
    for f in "$PROFILES_DIR"/*.provisionprofile "$PROFILES_DIR"/*.mobileprovision; do
        [ -f "$f" ] || continue
        appid=$(security cms -D -i "$f" 2>/dev/null | \
            xmllint --xpath '//key[text()="application-identifier"]/following-sibling::string[1]/text()' - 2>/dev/null)
        # Match app bundle ID exactly (not the dext)
        if [[ "$appid" == *"$APP_BUNDLE_ID" && "$appid" != *"$DEXT_BUNDLE_ID" ]]; then
            APP_PROFILE="$f"
            break
        fi
    done
fi

if [ -n "$APP_PROFILE" ]; then
    cp "$APP_PROFILE" "$APP/embedded.mobileprovision"
else
    echo "warning: no provisioning profile found for $APP_BUNDLE_ID" >&2
fi

# Fallback: extract team ID from signing identity if not from profile
if [ -z "$TEAM_ID" ]; then
    TEAM_ID=$(security find-identity -v -p codesigning 2>/dev/null | \
        grep "Apple Development" | head -1 | sed 's/.*(\([A-Z0-9]*\)).*/\1/')
fi
[ -n "$TEAM_ID" ] || { echo "error: cannot determine team ID" >&2; exit 1; }

# Build complete entitlements by merging source .entitlements files with
# auto-injected keys (application-identifier, team-identifier, get-task-allow,
# keychain-access-groups) that Xcode normally adds during signing.
APP_ENT=$(mktemp /tmp/app-ent.XXXXX.plist)
TMPFILES+=("$APP_ENT")
cp "$SRCROOT/ican/iCAN.entitlements" "$APP_ENT"
/usr/libexec/PlistBuddy \
    -c "Add :application-identifier string ${TEAM_ID}.${APP_BUNDLE_ID}" \
    -c "Add :com.apple.developer.team-identifier string ${TEAM_ID}" \
    -c "Add :get-task-allow bool true" \
    -c "Add :keychain-access-groups array" \
    -c "Add :keychain-access-groups:0 string ${TEAM_ID}.${APP_BUNDLE_ID}" \
    "$APP_ENT" 2>/dev/null

DEXT_ENT=$(mktemp /tmp/dext-ent.XXXXX.plist)
TMPFILES+=("$DEXT_ENT")
cp "$SRCROOT/usb_can_driver/USBCANDriver.entitlements" "$DEXT_ENT"
/usr/libexec/PlistBuddy \
    -c "Add :application-identifier string ${TEAM_ID}.${DEXT_BUNDLE_ID}" \
    -c "Add :com.apple.developer.team-identifier string ${TEAM_ID}" \
    "$DEXT_ENT" 2>/dev/null

# Find signing identity
ID=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')
if [ -z "$ID" ]; then
    echo "error: no Apple Development signing identity found in keychain" >&2
    echo "  Fix: open Xcode > Settings > Accounts, sign in and download certificates" >&2
    exit 1
fi

# Sign inner bundle (dext) first, then outer bundle (app)
codesign --force --sign "$ID" --timestamp=none --entitlements "$DEXT_ENT" \
  "$APP/SystemExtensions/USBCANDriver.dext"
codesign --force --sign "$ID" --timestamp=none --entitlements "$APP_ENT" \
  "$APP"
