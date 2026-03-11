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

    cmd = """
set -euo pipefail
EXECROOT="$PWD"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

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

# Create SystemExtensions directory
mkdir -p "$APP_DIR/SystemExtensions/{dext_dir_name}"

# Copy .dext files
{copy_commands}

# Re-sign the .dext
/usr/bin/codesign --force --sign {sign_identity} --timestamp=none "$APP_DIR/SystemExtensions/{dext_dir_name}" || true

# Re-sign the .app
/usr/bin/codesign --force --sign {sign_identity} --timestamp=none "$APP_DIR" || true

# Re-package as .ipa
cd extracted
zip -qr "$WORK/output.ipa" Payload
cp "$WORK/output.ipa" "$EXECROOT"/{output}
""".format(
        app_archive = _quote(app_archive.path),
        dext_dir_name = dext_dir_name,
        copy_commands = _gen_copy_commands(dext_files, dext_dir_name),
        sign_identity = _quote(sign_identity),
        output = _quote(out_ipa.path),
        app_name = app_name,
    )

    ctx.actions.run_shell(
        inputs = [app_archive] + dext_files,
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
            doc = "Code signing identity for re-signing.",
        ),
    },
    doc = "Embeds a .dext DriverKit extension into an ios_application .ipa bundle.",
)
