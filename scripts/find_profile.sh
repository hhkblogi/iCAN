#!/bin/bash
# find_profile.sh — Find a provisioning profile by bundle ID and team ID.
# Usage: find_profile.sh <team_id> <bundle_id> <output_path>
#
# Searches both Xcode-managed and manually-installed profile directories.
# Matches by application-identifier (team_id.bundle_id) in the profile's
# entitlements, not by profile name.

set -eo pipefail

TEAM_ID="$1"
BUNDLE_ID="$2"
OUTPUT="$3"
EXPECTED_APPID="${TEAM_ID}.${BUNDLE_ID}"

USER_HOME="${HOME:-$(eval echo ~)}"

PROFILE_DIRS=(
    "$USER_HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    "$USER_HOME/Library/MobileDevice/Provisioning Profiles"
)

for dir in "${PROFILE_DIRS[@]}"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*.mobileprovision "$dir"/*.provisionprofile; do
        [ -f "$f" ] || continue
        appid=$(security cms -D -i "$f" 2>/dev/null | \
            xmllint --xpath '//key[text()="application-identifier"]/following-sibling::string[1]/text()' - 2>/dev/null) || continue
        if [ "$appid" = "$EXPECTED_APPID" ]; then
            cp "$f" "$OUTPUT"
            exit 0
        fi
    done
done

echo "ERROR: No provisioning profile found for $EXPECTED_APPID" >&2
echo "  Install a profile for bundle ID '$BUNDLE_ID' (team $TEAM_ID)" >&2
exit 1
