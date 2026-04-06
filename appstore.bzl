# Conditionally registers App Store distribution targets.
#
# When APPSTORE_IDENTITY is empty (the default), no distribution targets
# are created. This allows `bazel build //...` and `bazel run //:xcodeproj`
# to work for developers who only need dev builds.

load("//bazel/driverkit:defs.bzl", "ios_application_with_dext")
load("@rules_apple//apple:ios.bzl", "ios_application")

def appstore_targets(appstore_identity, team_id, app_bundle_id, find_profile_tool):
    """Creates App Store distribution targets when APPSTORE_IDENTITY is configured.

    Args:
        appstore_identity: Signing identity string (e.g. "Apple Distribution: Name (TEAM)").
                           When empty, no targets are created.
        team_id: Apple Developer Team ID.
        app_bundle_id: App bundle identifier (e.g. "com.hhkblogi.ican").
        find_profile_tool: Label for the find_profile.sh script.
    """
    if not appstore_identity:
        return

    native.genrule(
        name = "appstore_profile",
        outs = ["iCAN_AppStore.mobileprovision"],
        cmd = "$(location " + find_profile_tool + ") " + team_id + " " + app_bundle_id + " $@ appstore",
        tools = [find_profile_tool],
        local = True,
        tags = [
            "manual",
            "no-cache",
        ],
    )

    native.genrule(
        name = "dext_appstore_profile",
        outs = ["iCAN_Dext_AppStore.mobileprovision"],
        cmd = "$(location " + find_profile_tool + ") " + team_id + " " + app_bundle_id + ".driver $@ appstore",
        tools = [find_profile_tool],
        local = True,
        tags = [
            "manual",
            "no-cache",
        ],
    )

    ios_application(
        name = "app_ios_appstore",
        app_icons = ["//ican:AppIcon"],
        bundle_id = app_bundle_id,
        entitlements = "//ican:iCAN.entitlements",
        families = ["ipad"],
        infoplists = ["//ican:Info.plist"],
        minimum_os_version = "26.0",
        provisioning_profile = ":appstore_profile",
        tags = ["manual"],
        deps = ["//ican:iCANLib"],
    )

    ios_application_with_dext(
        name = "app_ios_appstore_with_dext",
        app = ":app_ios_appstore",
        app_name = "iCAN",
        codesign_identity = appstore_identity,
        dext = "//usb_can_driver:USBCANDriver",
        dext_provisioning_profile = ":dext_appstore_profile",
        tags = ["manual"],
    )
