"""Wrapper rule to embed a .dext DriverKit extension into an ios_application."""

load("@rules_apple//apple:providers.bzl", "AppleBundleInfo")
load("//bazel/driverkit:xcodeproj_compat.bzl", "make_xcodeproj_target_info")

def _ios_application_with_dext_impl(ctx):
    # Collect the base .app bundle from the ios_application
    app_files = ctx.attr.app[DefaultInfo].files.to_list()

    # Find the .app directory (the ipa or app output)
    app_archive = None
    for f in app_files:
        if f.path.endswith(".ipa") or f.path.endswith(".app"):
            app_archive = f
            break

    if not app_archive:
        fail("Could not find .app or .ipa output from app target")

    # Collect .dext bundle files
    dext_files = ctx.attr.dext[DefaultInfo].files.to_list()

    # Output: modified .ipa with embedded .dext
    out_ipa = ctx.actions.declare_file(ctx.attr.name + ".ipa")

    # Build the embedding command
    # 1. Copy the base .ipa
    # 2. Unzip, embed .dext into Payload/<AppName>.app/SystemExtensions/
    # 3. Re-sign and re-zip

    dext_dir_name = None
    dext_file_paths = []
    for f in dext_files:
        # Files are like USBCANDriver.dext/USBCANDriver, USBCANDriver.dext/Info.plist
        parts = f.short_path.split("/")
        for i, p in enumerate(parts):
            if p.endswith(".dext"):
                dext_dir_name = p
                break
        dext_file_paths.append(f.path)

    if not dext_dir_name:
        fail("Could not determine .dext directory name from dext target outputs")

    # Shell script to embed .dext into .ipa
    app_name = ctx.attr.app_name
    sign_identity = ctx.attr.codesign_identity or "-"

    # Optional distribution signing inputs
    extra_inputs = []
    dext_profile_path = ""
    if ctx.file.dext_provisioning_profile:
        dext_profile_path = ctx.file.dext_provisioning_profile.path
        extra_inputs.append(ctx.file.dext_provisioning_profile)

    cmd = """
set -euo pipefail
EXECROOT="$PWD"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SIGN_IDENTITY={sign_identity}
DEXT_PROFILE={dext_profile}

# Copy and extract base .ipa
cp {app_archive} "$WORK/base.ipa"
cd "$WORK"
unzip -q base.ipa -d extracted

# Find the .app directory
APP_DIR=$(find extracted/Payload -name '*.app' -maxdepth 1 | head -1)
if [ -z "$APP_DIR" ]; then
    echo "ERROR: Could not find .app in ipa" >&2
    exit 1
fi

# Distribution vs ad-hoc path
if [ -n "$DEXT_PROFILE" ] && [ "$SIGN_IDENTITY" != "-" ]; then
    # --- App Store distribution path ---

    # Extract the dext's bundle ID from its Info.plist and use it as the
    # final dext directory name (Apple requires dext bundle name to equal
    # CFBundleIdentifier + .dext). The source bundle is named {dext_dir_name}.
    SRC_DEXT_DIR="$APP_DIR/SystemExtensions/{dext_dir_name}"
    mkdir -p "$SRC_DEXT_DIR"
{copy_commands}
    chmod -R u+w "$SRC_DEXT_DIR"

    DEXT_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC_DEXT_DIR/Info.plist")
    FINAL_DEXT_NAME="$DEXT_BUNDLE_ID.dext"
    FINAL_DEXT_PATH="$APP_DIR/SystemExtensions/$FINAL_DEXT_NAME"
    if [ "{dext_dir_name}" != "$FINAL_DEXT_NAME" ]; then
        mv "$SRC_DEXT_DIR" "$FINAL_DEXT_PATH"
    fi

    # Preserve the app's existing entitlements before re-signing. The outer
    # ios_application target signs with proper entitlements (including
    # application-identifier); we must re-apply them when we re-sign.
    # The `:-` form writes clean XML to stdout.
    APP_ENTITLEMENTS="$WORK/app_entitlements.plist"
    /usr/bin/codesign -d --entitlements :- "$APP_DIR" 2>/dev/null > "$APP_ENTITLEMENTS"

    # Build merged dext entitlements from the provisioning profile's
    # allowed entitlements. Using the profile as the source of truth
    # guarantees the bundle entitlements are a valid subset (e.g., USB
    # transport VIDs must match exactly what Apple has approved).
    # We keep only DriverKit-related keys, application-identifier, and
    # team-identifier — other profile keys like beta-reports-active and
    # keychain-access-groups don't belong in a dext binary.
    DEXT_MERGED_ENT="$WORK/dext_entitlements.plist"
    python3 -c "
import sys, plistlib, subprocess
with open('$EXECROOT/$DEXT_PROFILE', 'rb') as f:
    cms = f.read()
profile_xml = subprocess.check_output(['security', 'cms', '-D', '-i', '/dev/stdin'], input=cms)
profile = plistlib.loads(profile_xml)
profile_ents = profile.get('Entitlements', {{}})

# Keys to carry over to the signed dext entitlements
allowed_keys = {{
    'application-identifier',
    'com.apple.developer.team-identifier',
    'com.apple.developer.driverkit',
    'com.apple.developer.driverkit.allow-third-party-userclients',
    'com.apple.developer.driverkit.transport.usb',
    'com.apple.developer.driverkit.transport.hid',
    'com.apple.developer.driverkit.family.networking',
    'com.apple.developer.driverkit.family.serial',
}}
ents = {{k: v for k, v in profile_ents.items() if k in allowed_keys}}

with open('$DEXT_MERGED_ENT', 'wb') as f:
    plistlib.dump(ents, f)
"

    # Embed provisioning profile in the dext
    cp "$EXECROOT/$DEXT_PROFILE" "$FINAL_DEXT_PATH/embedded.mobileprovision"
    chmod u+w "$FINAL_DEXT_PATH/embedded.mobileprovision"

    # Sign the dext with merged entitlements (inner bundle first).
    # --generate-entitlement-der: embed DER-encoded entitlements (required by App Store)
    # --timestamp: use Apple's TSA for distribution (not --timestamp=none)
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$DEXT_MERGED_ENT" \
        --options runtime --timestamp \
        --generate-entitlement-der "$FINAL_DEXT_PATH"

    # Re-sign the outer app with its original entitlements (do NOT use --deep,
    # which would re-sign the dext and strip its entitlements).
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" \
        --entitlements "$APP_ENTITLEMENTS" \
        --options runtime --timestamp \
        --generate-entitlement-der "$APP_DIR"
else
    # --- Development / ad-hoc path ---
    mkdir -p "$APP_DIR/SystemExtensions/{dext_dir_name}"
{copy_commands}
    DEXT_PATH="$APP_DIR/SystemExtensions/{dext_dir_name}"
    chmod -R u+w "$DEXT_PATH"
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$DEXT_PATH" || true
    /usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$APP_DIR" || true
fi

# Re-package as .ipa
cd extracted
zip -qr "$WORK/output.ipa" Payload
cp "$WORK/output.ipa" "$EXECROOT"/{output}
""".format(
        app_archive = _quote(app_archive.path),
        dext_dir_name = dext_dir_name,
        copy_commands = _gen_copy_commands(dext_files, dext_dir_name),
        sign_identity = _quote(sign_identity),
        dext_profile = _quote(dext_profile_path),
        output = _quote(out_ipa.path),
        app_name = app_name,
    )

    ctx.actions.run_shell(
        inputs = [app_archive] + dext_files + extra_inputs,
        outputs = [out_ipa],
        command = cmd,
        mnemonic = "EmbedDext",
        progress_message = "Embedding .dext into %s" % ctx.attr.name,
        execution_requirements = {
            "no-sandbox": "1",
            "no-remote": "1",
        },
    )

    # Forward AppleBundleInfo from the inner ios_application so
    # rules_xcodeproj recognizes this as an iOS app target
    providers = [
        DefaultInfo(
            files = depset([out_ipa]),
        ),
        make_xcodeproj_target_info(
            ctx,
            deps = [],
            is_supported = False,
            is_top_level = False,
            target_type = None,
            link_mnemonics = ["EmbedDext"],
        ),
    ]

    # Forward AppleBundleInfo from the inner ios_application
    if AppleBundleInfo in ctx.attr.app:
        providers.append(ctx.attr.app[AppleBundleInfo])

    return providers

def _gen_copy_commands(dext_files, dext_dir_name):
    """Generate shell commands to copy .dext files into the .app bundle."""
    cmds = []
    for f in dext_files:
        # Extract relative path within the .dext directory
        path = f.short_path
        idx = path.find(dext_dir_name + "/")
        if idx >= 0:
            rel_path = path[idx + len(dext_dir_name) + 1:]
            # Handle subdirectories (like _CodeSignature/)
            parent = "/".join(rel_path.split("/")[:-1])
            if parent:
                cmds.append('mkdir -p "$APP_DIR/SystemExtensions/{dext}/{parent}"'.format(
                    dext = dext_dir_name,
                    parent = parent,
                ))
            cmds.append('cp "$EXECROOT"/"{src}" "$APP_DIR/SystemExtensions/{dext}/{rel}"'.format(
                src = f.path,
                dext = dext_dir_name,
                rel = rel_path,
            ))
    return "\n".join(cmds)

def _quote(s):
    """Quote a shell argument."""
    return "'" + s.replace("'", "'\\''") + "'"

ios_application_with_dext = rule(
    implementation = _ios_application_with_dext_impl,
    attrs = {
        "app": attr.label(
            mandatory = True,
            doc = "The base ios_application target.",
        ),
        "dext": attr.label(
            mandatory = True,
            doc = "The driverkit_extension target producing the .dext bundle.",
        ),
        "app_name": attr.string(
            mandatory = True,
            doc = "The name of the .app bundle (e.g., 'iCAN').",
        ),
        "codesign_identity": attr.string(
            default = "-",
            doc = "Code signing identity for re-signing. Use '-' for ad-hoc (dev) or 'Apple Distribution: ...' for App Store.",
        ),
        "dext_provisioning_profile": attr.label(
            allow_single_file = [".mobileprovision", ".provisionprofile"],
            doc = "Distribution provisioning profile to embed in the dext (required for App Store).",
        ),
    },
    doc = "Embeds a .dext DriverKit extension into an ios_application .ipa bundle.",
)
