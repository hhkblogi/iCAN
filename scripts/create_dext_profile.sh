#!/bin/bash
# create_dext_profile.sh — Trigger Xcode to auto-create a managed provisioning
# profile for the DriverKit extension bundle ID.
#
# Creates a temporary Xcode project, runs xcodebuild with automatic signing,
# and lets Xcode create the "iOS Team Provisioning Profile" for the dext.
# The build will fail (no real source) but the profile persists.

set -eo pipefail

TEAM_ID="${1:?Usage: create_dext_profile.sh <team_id> <bundle_id>}"
BUNDLE_ID="${2:?Usage: create_dext_profile.sh <team_id> <bundle_id>}"
TMPDIR=$(mktemp -d /tmp/dext-profile-XXXXXX)
trap "rm -rf '$TMPDIR'" EXIT

echo "Creating temporary Xcode project for $BUNDLE_ID..."

# Create minimal source file
mkdir -p "$TMPDIR/Src"
cat > "$TMPDIR/Src/main.m" << 'OBJC'
int main(void) { return 0; }
OBJC

# Create minimal Info.plist
cat > "$TMPDIR/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>DextProfileHelper</string>
    <key>CFBundleName</key>
    <string>DextProfileHelper</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>MinimumOSVersion</key>
    <string>26.0</string>
</dict>
</plist>
PLIST

# Create minimal Xcode project
mkdir -p "$TMPDIR/DextProfileHelper.xcodeproj"
cat > "$TMPDIR/DextProfileHelper.xcodeproj/project.pbxproj" << PBXPROJ
{
    archiveVersion = 1;
    classes = {};
    objectVersion = 56;
    objects = {
        ROOT = { isa = PBXProject; buildConfigurationList = CFGLIST; compatibilityVersion = "Xcode 14.0"; mainGroup = MAIN; productRefGroup = PRODUCTS; targets = (TARGET); };
        MAIN = { isa = PBXGroup; children = (SRC, PRODUCTS); sourceTree = "<group>"; };
        SRC = { isa = PBXGroup; children = (SRCFILE); name = Src; path = Src; sourceTree = "<group>"; };
        SRCFILE = { isa = PBXFileReference; path = main.m; sourceTree = "<group>"; };
        PRODUCTS = { isa = PBXGroup; children = (PRODUCT); name = Products; sourceTree = "<group>"; };
        PRODUCT = { isa = PBXFileReference; explicitFileType = "compiled.mach-o.executable"; path = DextProfileHelper.app; sourceTree = BUILT_PRODUCTS_DIR; };
        TARGET = { isa = PBXNativeTarget; buildConfigurationList = TCFGLIST; buildPhases = (SOURCES); dependencies = (); name = DextProfileHelper; productName = DextProfileHelper; productReference = PRODUCT; productType = "com.apple.product-type.application"; };
        SOURCES = { isa = PBXSourcesBuildPhase; files = (SRCBUILD); };
        SRCBUILD = { isa = PBXBuildFile; fileRef = SRCFILE; };
        CFGLIST = { isa = XCConfigurationList; buildConfigurations = (CFG); };
        CFG = {
            isa = XCBuildConfiguration;
            name = Debug;
            buildSettings = {
                ALWAYS_SEARCH_USER_PATHS = NO;
                SDKROOT = iphoneos;
                IPHONEOS_DEPLOYMENT_TARGET = 26.0;
                TARGETED_DEVICE_FAMILY = 2;
            };
        };
        TCFGLIST = { isa = XCConfigurationList; buildConfigurations = (TCFG); };
        TCFG = {
            isa = XCBuildConfiguration;
            name = Debug;
            buildSettings = {
                CODE_SIGN_STYLE = Automatic;
                DEVELOPMENT_TEAM = $TEAM_ID;
                INFOPLIST_FILE = Info.plist;
                PRODUCT_BUNDLE_IDENTIFIER = $BUNDLE_ID;
                PRODUCT_NAME = DextProfileHelper;
                TARGETED_DEVICE_FAMILY = 2;
            };
        };
    };
    rootObject = ROOT;
}
PBXPROJ

echo "Running xcodebuild to trigger profile creation..."
cd "$TMPDIR"
xcodebuild -project DextProfileHelper.xcodeproj \
    -target DextProfileHelper \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -allowProvisioningUpdates \
    CODE_SIGN_STYLE=Automatic \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    2>&1 || true

echo ""
echo "Checking for auto-created profile..."
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
    [ -f "$f" ] || continue
    appid=$(security cms -D -i "$f" 2>/dev/null | xmllint --xpath '//key[text()="application-identifier"]/following-sibling::string[1]/text()' - 2>/dev/null)
    if [[ "$appid" == *"$BUNDLE_ID"* ]]; then
        name=$(security cms -D -i "$f" 2>/dev/null | grep -A1 '<key>Name</key>' | tail -1 | sed 's/.*<string>//;s/<.*//')
        echo "SUCCESS: Found profile '$name'"
        echo "  File: $f"
        exit 0
    fi
done

echo "Profile not found yet. Try opening the temporary project in Xcode manually."
echo "  Project: $TMPDIR/DextProfileHelper.xcodeproj"
