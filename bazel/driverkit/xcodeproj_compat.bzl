"""Compatibility helpers for rules_xcodeproj integration."""

load("@rules_xcodeproj//xcodeproj:defs.bzl", "XcodeProjAutomaticTargetProcessingInfo")

_EMPTY_LIST = []

def make_xcodeproj_target_info(
        ctx,
        srcs = _EMPTY_LIST,
        deps = _EMPTY_LIST,
        extra_files = _EMPTY_LIST,
        is_top_level = False,
        is_supported = True,
        bundle_id = None,
        entitlements = None,
        link_mnemonics = _EMPTY_LIST,
        target_type = "compile",
        xcode_targets = {}):
    """Create XcodeProjAutomaticTargetProcessingInfo for a custom rule."""
    return XcodeProjAutomaticTargetProcessingInfo(
        app_icons = None,
        args = None,
        bundle_id = bundle_id,
        collect_uncategorized_files = False,
        deps = deps,
        entitlements = entitlements,
        env = None,
        extra_files = extra_files,
        implementation_deps = _EMPTY_LIST,
        is_header_only_library = False,
        is_mixed_language = False,
        is_supported = is_supported,
        is_top_level = is_top_level,
        label = ctx.label,
        link_mnemonics = link_mnemonics,
        non_arc_srcs = _EMPTY_LIST,
        provisioning_profile = None,
        srcs = srcs,
        target_type = target_type,
        xcode_targets = xcode_targets,
    )
