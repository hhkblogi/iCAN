"""DriverKit extension (.dext) bundle rule."""

load("//bazel/driverkit:providers.bzl", "DriverKitCcInfo")
load("//bazel/driverkit:xcodeproj_compat.bzl", "make_xcodeproj_target_info")

_CLANG_WRAPPER = "//bazel/driverkit:clang_wrapper.sh"

def _driverkit_extension_impl(ctx):
    sdk_path = ctx.attr.driverkit_sdk_path
    deployment_target = ctx.attr.deployment_target
    bundle_id = ctx.attr.bundle_id
    executable_name = ctx.attr.executable_name or ctx.attr.name

    # Collect object files and link inputs from deps
    objects = []
    link_inputs = []
    for dep in ctx.attr.deps:
        if DriverKitCcInfo in dep:
            objects.extend(dep[DriverKitCcInfo].objects.to_list())
            link_inputs.extend(dep[DriverKitCcInfo].link_inputs.to_list())

    # Output executable
    out_executable = ctx.actions.declare_file(
        "{}.dext/{}".format(ctx.attr.name, executable_name),
    )

    # Link command via clang_wrapper (strips -fprofile-instr-generate)
    link_args = [
        ctx.file._clang_wrapper.path,
        "-target", "arm64-apple-driverkit" + deployment_target,
        "-isysroot", sdk_path,
        "-F", sdk_path + "/System/DriverKit/System/Library/Frameworks",
        "-L", sdk_path + "/System/DriverKit/usr/lib",
        "-framework", "DriverKit",
        "-framework", "USBDriverKit",
        "-o", out_executable.path,
    ]

    # Add object files
    for obj in objects:
        link_args.append(obj.path)

    # Add extra link libraries
    for lib in ctx.files.link_libs:
        link_args.append(lib.path)

    ctx.actions.run_shell(
        inputs = link_inputs + ctx.files.link_libs + [ctx.file._clang_wrapper],
        outputs = [out_executable],
        command = " ".join([_quote(a) for a in link_args]),
        mnemonic = "DriverKitLink",
        progress_message = "Linking DriverKit extension %s" % ctx.attr.name,
        execution_requirements = {
            "no-sandbox": "1",
            "no-remote": "1",
        },
    )

    # Process Info.plist with variable substitution
    out_plist = ctx.actions.declare_file(
        "{}.dext/Info.plist".format(ctx.attr.name),
    )

    substitutions = {
        "$(EXECUTABLE_NAME)": executable_name,
        "$(PRODUCT_BUNDLE_IDENTIFIER)": bundle_id,
        "$(PRODUCT_NAME)": executable_name,
        "$(PRODUCT_BUNDLE_PACKAGE_TYPE)": "DEXT",
    }

    ctx.actions.expand_template(
        template = ctx.file.infoplist,
        output = out_plist,
        substitutions = substitutions,
    )

    # Code sign the .dext bundle
    out_signature = ctx.actions.declare_file(
        "{}.dext/_CodeSignature/CodeResources".format(ctx.attr.name),
    )

    dext_dir = out_executable.dirname
    sign_identity = ctx.attr.codesign_identity or "-"

    ctx.actions.run_shell(
        inputs = [out_executable, out_plist],
        outputs = [out_signature],
        command = (
            "/usr/bin/codesign --force --sign {identity} " +
            "--timestamp=none " +
            "--generate-entitlement-der " +
            "{dext_dir} && " +
            "test -f {sig_path}"
        ).format(
            identity = _quote(sign_identity),
            dext_dir = _quote(dext_dir),
            sig_path = _quote(out_signature.path),
        ),
        mnemonic = "DriverKitCodesign",
        progress_message = "Code signing DriverKit extension %s" % ctx.attr.name,
        execution_requirements = {
            "no-sandbox": "1",
            "no-remote": "1",
        },
    )

    # Return all .dext bundle files
    dext_files = [out_executable, out_plist, out_signature]
    return [
        DefaultInfo(
            files = depset(dext_files),
        ),
        make_xcodeproj_target_info(
            ctx,
            deps = ["deps"],
            extra_files = ["infoplist", "link_libs"],
            is_top_level = True,
            bundle_id = "bundle_id",
            link_mnemonics = ["DriverKitLink", "DriverKitCodesign"],
        ),
    ]

def _quote(s):
    """Quote a shell argument."""
    return "'" + s.replace("'", "'\\''") + "'"

driverkit_extension = rule(
    implementation = _driverkit_extension_impl,
    attrs = {
        "deps": attr.label_list(
            mandatory = True,
            doc = "driverkit_cc_library dependencies providing object files.",
        ),
        "infoplist": attr.label(
            mandatory = True,
            allow_single_file = [".plist"],
            doc = "Info.plist template for the .dext bundle.",
        ),
        "bundle_id": attr.string(
            mandatory = True,
            doc = "Bundle identifier for the .dext extension.",
        ),
        "executable_name": attr.string(
            default = "",
            doc = "Name of the executable inside the .dext bundle. Defaults to rule name.",
        ),
        "driverkit_sdk_path": attr.string(
            default = "/Applications/Xcode.app/Contents/Developer/Platforms/DriverKit.platform/Developer/SDKs/DriverKit25.2.sdk",
            doc = "Path to the DriverKit SDK.",
        ),
        "deployment_target": attr.string(
            default = "25.2",
            doc = "DriverKit deployment target version.",
        ),
        "link_libs": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Additional libraries to link (e.g., stub libs).",
        ),
        "codesign_identity": attr.string(
            default = "-",
            doc = "Code signing identity. Use '-' for ad-hoc signing.",
        ),
        "_clang_wrapper": attr.label(
            default = Label("//bazel/driverkit:clang_wrapper.sh"),
            allow_single_file = True,
        ),
    },
    doc = "Builds a DriverKit extension (.dext) bundle from compiled DriverKit C++ code.",
)
