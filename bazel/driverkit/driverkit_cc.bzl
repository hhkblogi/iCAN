"""DriverKit C++ compilation rule."""

load("//bazel/driverkit:providers.bzl", "DriverKitCcInfo", "IigInfo")
load("//bazel/driverkit:xcodeproj_compat.bzl", "make_xcodeproj_target_info")

_CLANG_PATH = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"

def _driverkit_cc_library_impl(ctx):
    sdk_path = ctx.attr.driverkit_sdk_path
    deployment_target = ctx.attr.deployment_target
    bundle_id = ctx.attr.bundle_id

    all_objects = []
    all_sources = list(ctx.files.srcs)

    # Collect IIG-generated sources and headers from deps
    iig_headers = []
    iig_include_dirs = []
    for dep in ctx.attr.deps:
        if IigInfo in dep:
            iig_info = dep[IigInfo]
            all_sources.extend(iig_info.sources.to_list())
            iig_headers.extend(iig_info.headers.to_list())
            iig_include_dirs.append(iig_info.include_dir)

    # Collect manual header files
    hdrs = ctx.files.hdrs

    # Common compiler flags
    base_copts = [
        "-target", "arm64-apple-driverkit" + deployment_target,
        "-isysroot", sdk_path,
        "-iframework", sdk_path + "/System/DriverKit/System/Library/Frameworks",
        "-std=gnu++23",
        "-fno-exceptions",
        "-fno-rtti",
        "-fno-profile-instr-generate",
        "-DDRIVERKIT=1",
    ]

    # Add include paths
    for inc_dir in iig_include_dirs:
        base_copts.extend(["-I", inc_dir])

    # Add header search paths for local headers
    src_dirs = {}
    for src in ctx.files.srcs:
        src_dirs[src.dirname] = True
    for hdr in hdrs:
        src_dirs[hdr.dirname] = True
    for d in src_dirs:
        base_copts.extend(["-I", d])

    # Add user copts
    base_copts.extend(ctx.attr.copts)

    # Compile each source file
    for src in all_sources:
        # Map source extension to .o (order matters: .cpp/.cc before .c)
        basename = src.basename
        for ext in [".cpp", ".cxx", ".cc", ".c"]:
            if basename.endswith(ext):
                basename = basename[:-len(ext)] + ".o"
                break
        obj = ctx.actions.declare_file(basename)

        cmd_args = [_CLANG_PATH, "-c"] + base_copts + [
            "-o", obj.path,
            src.path,
        ]

        ctx.actions.run_shell(
            inputs = [src] + hdrs + iig_headers + ctx.files._extra_inputs,
            outputs = [obj],
            command = " ".join([_quote(a) for a in cmd_args]),
            mnemonic = "DriverKitCppCompile",
            progress_message = "Compiling DriverKit C++ %s" % src.short_path,
            execution_requirements = {
                "no-sandbox": "1",
                "no-remote": "1",
            },
        )

        all_objects.append(obj)

    # Build CcInfo for rules_xcodeproj indexing
    all_include_dirs = list(iig_include_dirs)
    for d in src_dirs:
        all_include_dirs.append(d)

    cc_compilation_context = cc_common.create_compilation_context(
        headers = depset(hdrs + iig_headers),
        includes = depset(all_include_dirs),
        system_includes = depset([
            sdk_path,
            sdk_path + "/System/DriverKit/System/Library/Frameworks",
        ]),
    )

    return [
        DefaultInfo(
            files = depset(all_objects),
        ),
        DriverKitCcInfo(
            objects = depset(all_objects),
            link_inputs = depset(all_objects + ctx.files.link_libs),
        ),
        CcInfo(
            compilation_context = cc_compilation_context,
        ),
        make_xcodeproj_target_info(
            ctx,
            srcs = ["srcs"],
            deps = ["deps"],
            extra_files = ["hdrs"],
            link_mnemonics = ["DriverKitLink"],
        ),
    ]

def _quote(s):
    """Quote a shell argument."""
    return "'" + s.replace("'", "'\\''") + "'"

driverkit_cc_library = rule(
    implementation = _driverkit_cc_library_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".cpp", ".c", ".cc", ".cxx"],
            mandatory = True,
            doc = "C++ source files to compile.",
        ),
        "hdrs": attr.label_list(
            allow_files = [".h", ".hpp"],
            default = [],
            doc = "Header files.",
        ),
        "deps": attr.label_list(
            default = [],
            doc = "Dependencies (e.g., iig_library targets).",
        ),
        "bundle_id": attr.string(
            default = "",
            doc = "Bundle identifier for the DriverKit extension.",
        ),
        "driverkit_sdk_path": attr.string(
            default = "/Applications/Xcode.app/Contents/Developer/Platforms/DriverKit.platform/Developer/SDKs/DriverKit25.2.sdk",
            doc = "Path to the DriverKit SDK.",
        ),
        "deployment_target": attr.string(
            default = "25.2",
            doc = "DriverKit deployment target version.",
        ),
        "copts": attr.string_list(
            default = [],
            doc = "Additional compiler options.",
        ),
        "link_libs": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Additional static libraries needed for linking.",
        ),
        "_extra_inputs": attr.label_list(
            allow_files = True,
            default = [],
        ),
    },
    provides = [DefaultInfo, DriverKitCcInfo, CcInfo],
    doc = "Compiles C++ source files with the DriverKit SDK toolchain.",
)
