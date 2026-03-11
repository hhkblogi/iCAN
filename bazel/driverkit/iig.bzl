"""IIG (IOKit Interface Generator) compilation rule for DriverKit."""

load("//bazel/driverkit:providers.bzl", "IigInfo")
load("//bazel/driverkit:xcodeproj_compat.bzl", "make_xcodeproj_target_info")

_IIG_TOOL_PATH = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/iig"

def _iig_library_impl(ctx):
    bundle_id = ctx.attr.bundle_id
    sdk_path = ctx.attr.driverkit_sdk_path

    all_headers = []
    all_sources = []

    for src in ctx.files.srcs:
        basename = src.basename.replace(".iig", "")

        # Output goes into <bundle_id>/ subdirectory to match Xcode behavior
        out_header = ctx.actions.declare_file(
            "{}/{}.h".format(bundle_id, basename),
        )
        out_impl = ctx.actions.declare_file(
            "{}/{}.iig.cpp".format(bundle_id, basename),
        )

        # Build IIG command arguments
        cmd_args = [
            _IIG_TOOL_PATH,
            "--def", src.path,
            "--header", out_header.path,
            "--impl", out_impl.path,
            "--deployment-target", ctx.attr.deployment_target,
            "--",
            "-isysroot", sdk_path,
            "-iframework", sdk_path + "/System/DriverKit/System/Library/Frameworks",
            "-x", "c++",
            "-std=gnu++20",
            "-D__IIG=1",
            "-DDRIVERKIT=1",
        ]

        # Add user-provided include paths
        for inc in ctx.attr.includes:
            cmd_args.extend(["-I", inc])

        # Add the source directory as an include path for cross-references between .iig files
        cmd_args.extend(["-I", src.dirname])

        # The IIG compiler generates #include "ClassName.h" using the class name
        # (e.g., "USBCANDriver.h"), which may differ from the source filename
        # (e.g., "usb_can_driver.h"). Post-process the generated .iig.cpp to
        # fix the #include to match the actual output header filename.
        out_header_basename = out_header.basename
        iig_cmd = " ".join([_quote(a) for a in cmd_args])
        fix_cmd = "sed -i '' 's|^#include \"[^\"]*\\.h\"|#include \"{}\"|' {}".format(
            out_header_basename,
            _quote(out_impl.path),
        )
        full_cmd = "{iig} && {fix}".format(iig = iig_cmd, fix = fix_cmd)

        ctx.actions.run_shell(
            inputs = [src] + ctx.files.deps,
            outputs = [out_header, out_impl],
            command = full_cmd,
            mnemonic = "IigCompile",
            progress_message = "Generating IIG headers for %s" % src.short_path,
            execution_requirements = {
                "no-sandbox": "1",
                "no-remote": "1",
            },
        )

        all_headers.append(out_header)
        all_sources.append(out_impl)

    # The include dir is the bundle_id subdirectory itself
    # Headers are at <execroot>/bazel-out/.../bin/<package>/<bundle_id>/Foo.h
    # The .cpp files include them as "Foo.h" (not "<bundle_id>/Foo.h")
    include_dir = all_headers[0].dirname if all_headers else ""

    return [
        DefaultInfo(
            files = depset(all_headers + all_sources),
        ),
        IigInfo(
            headers = depset(all_headers),
            sources = depset(all_sources),
            bundle_id = bundle_id,
            include_dir = include_dir,
        ),
        CcInfo(
            compilation_context = cc_common.create_compilation_context(
                headers = depset(all_headers),
                includes = depset([include_dir]),
            ),
        ),
        make_xcodeproj_target_info(
            ctx,
            srcs = ["srcs"],
            deps = ["deps"],
        ),
    ]

def _quote(s):
    """Quote a shell argument."""
    return "'" + s.replace("'", "'\\''") + "'"

iig_library = rule(
    implementation = _iig_library_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".iig"],
            mandatory = True,
            doc = "IIG source files to compile.",
        ),
        "bundle_id": attr.string(
            mandatory = True,
            doc = "Bundle identifier for the DriverKit extension (determines output subdirectory).",
        ),
        "driverkit_sdk_path": attr.string(
            default = "/Applications/Xcode.app/Contents/Developer/Platforms/DriverKit.platform/Developer/SDKs/DriverKit25.1.sdk",
            doc = "Path to the DriverKit SDK.",
        ),
        "deployment_target": attr.string(
            default = "25.1",
            doc = "DriverKit deployment target version.",
        ),
        "includes": attr.string_list(
            default = [],
            doc = "Additional include paths for IIG compilation.",
        ),
        "deps": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Additional file dependencies (e.g., other .iig files for cross-references).",
        ),
    },
    provides = [DefaultInfo, IigInfo, CcInfo],
    doc = "Compiles .iig files using the IIG compiler to generate C++ headers and sources.",
)
