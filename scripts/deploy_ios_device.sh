#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  deploy_ios_device.sh --device <name-or-id> [options] [-- app-args...]

Build, install, and optionally launch the generated Xcode development app on a
real iPad/iPhone using xcodebuild + devicectl.

Required unless ICAN_DEVICE is set:
  -d, --device <name-or-id>      Device name, CoreDevice UUID, UDID, or serial.

Options:
      --destination <spec>       Override xcodebuild destination.
      --project <path>           Xcode project path. Default: ican.xcodeproj.
      --scheme <name>            Xcode scheme. Default: app_ios.
      --configuration <name>     Xcode configuration. Default: Debug.
      --derived-data <path>      DerivedData path. Default: /tmp/ican-xcode-derived-data.
      --bundle-id <id>           App bundle id. Default: com.hhkblogi.ican.
      --app <path>               Install this .app instead of resolving from DerivedData.
      --build-only               Build but do not install or launch.
      --install-only             Install --app without building.
      --no-launch                Install but do not launch.
      --console                  Launch with devicectl --console attached.
      --allow-provisioning-updates
                                  Pass -allowProvisioningUpdates to xcodebuild.
      --verbose-build            Show full xcodebuild output. Default is quiet.
      --list-devices             Print devicectl's visible devices and exit.
  -h, --help                     Show this help.

Examples:
  bazel run //:deploy_ios_device -- --device <device-name-or-id>
  ICAN_DEVICE=<device-name-or-id> bazel run //:deploy_ios_device -- --no-launch
  ./scripts/deploy_ios_device.sh --device <device-name-or-id> --console
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

workspace_root() {
    if [[ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]]; then
        printf '%s\n' "$BUILD_WORKSPACE_DIRECTORY"
        return
    fi

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$script_dir/.." && pwd
}

is_id_like() {
    [[ "$1" =~ ^[A-Fa-f0-9-]{24,}$ ]]
}

default_destination_for_device() {
    local device="$1"
    if is_id_like "$device"; then
        printf 'id=%s\n' "$device"
    else
        printf 'platform=iOS,name=%s\n' "$device"
    fi
}

read_bzl_string() {
    local file="$1"
    local key="$2"
    awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            value = $0
            sub(/^[^=]*=[[:space:]]*/, "", value)
            if (value ~ /^"/) {
                sub(/^"/, "", value)
                sub(/"[[:space:]]*(#.*)?$/, "", value)
                print value
                exit
            }
        }
    ' "$file"
}

load_device_config() {
    local root="$1"
    local config="$root/device_config.bzl"
    [[ -f "$config" ]] || return 0

    local config_device config_destination
    config_device="$(read_bzl_string "$config" ICAN_DEVICE)"
    if [[ -z "$config_device" ]]; then
        config_device="$(read_bzl_string "$config" ICAN_DEVICE_ID)"
    fi
    if [[ -z "$config_device" ]]; then
        config_device="$(read_bzl_string "$config" ICAN_DEVICE_NAME)"
    fi
    config_destination="$(read_bzl_string "$config" ICAN_XCODE_DESTINATION)"

    if [[ -z "$device" && -n "$config_device" ]]; then
        device="$config_device"
    fi
    if [[ -z "$destination" && -n "$config_destination" ]]; then
        destination="$config_destination"
    fi
}

check_devicectl_json_outcome() {
    local json_file="$1"
    local action="$2"

    python3 - "$json_file" "$action" <<'PY'
import json
import sys

json_file = sys.argv[1]
action = sys.argv[2]

try:
    with open(json_file, "r", encoding="utf-8") as f:
        payload = json.load(f)
except Exception as exc:
    print(f"error: {action} did not produce readable devicectl JSON: {exc}", file=sys.stderr)
    sys.exit(1)

outcome = payload.get("info", {}).get("outcome")
if outcome == "success":
    sys.exit(0)

message = None
error = payload.get("error")
if isinstance(error, dict):
    user_info = error.get("userInfo")
    if isinstance(user_info, dict):
        localized = user_info.get("NSLocalizedDescription")
        if isinstance(localized, dict):
            message = localized.get("string")
        elif isinstance(localized, str):
            message = localized

if message:
    print(f"error: {action} failed: {message}", file=sys.stderr)
else:
    print(f"error: {action} failed: devicectl JSON outcome is {outcome!r}", file=sys.stderr)
sys.exit(1)
PY
}

resolve_app_path() {
    local explicit_app="$1"
    local derived_data="$2"
    local configuration="$3"

    if [[ -n "$explicit_app" ]]; then
        [[ -d "$explicit_app" ]] || die "--app does not point to an .app directory: $explicit_app"
        printf '%s\n' "$explicit_app"
        return
    fi

    local products_dir="$derived_data/Build/Products"
    [[ -d "$products_dir" ]] || die "Build products directory not found: $products_dir"

    local -a candidates=()
    while IFS= read -r -d '' candidate; do
        candidates+=("$candidate")
    done < <(find "$products_dir" \
        -path "*/${configuration}-iphoneos/*.app" \
        -type d \
        -print0)

    if [[ "${#candidates[@]}" -eq 0 ]]; then
        die "No ${configuration}-iphoneos .app found under $products_dir"
    fi

    if [[ "${#candidates[@]}" -gt 1 ]]; then
        printf 'Found multiple .app products:\n' >&2
        printf '  %s\n' "${candidates[@]}" >&2
        die "Pass --app <path> to select one explicitly."
    fi

    printf '%s\n' "${candidates[0]}"
}

device="${ICAN_DEVICE:-}"
destination="${ICAN_XCODE_DESTINATION:-}"
destination_explicit=0
if [[ -n "${ICAN_XCODE_DESTINATION:-}" ]]; then
    destination_explicit=1
fi
project="${ICAN_XCODEPROJ:-ican.xcodeproj}"
scheme="${ICAN_XCODE_SCHEME:-app_ios}"
configuration="${ICAN_XCODE_CONFIGURATION:-Debug}"
derived_data="${ICAN_DERIVED_DATA:-/tmp/ican-xcode-derived-data}"
bundle_id="${ICAN_BUNDLE_ID:-com.hhkblogi.ican}"
app_path=""
build=1
install=1
launch=1
console=0
allow_provisioning_updates=0
verbose_build="${ICAN_XCODEBUILD_VERBOSE:-0}"
declare -a app_args=()

root="$(workspace_root)"
load_device_config "$root"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            device="$2"
            if [[ "$destination_explicit" -eq 0 ]]; then
                destination=""
            fi
            shift 2
            ;;
        --destination)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            destination="$2"
            destination_explicit=1
            shift 2
            ;;
        --project)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            project="$2"
            shift 2
            ;;
        --scheme)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            scheme="$2"
            shift 2
            ;;
        --configuration)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            configuration="$2"
            shift 2
            ;;
        --derived-data)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            derived_data="$2"
            shift 2
            ;;
        --bundle-id)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            bundle_id="$2"
            shift 2
            ;;
        --app)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            app_path="$2"
            shift 2
            ;;
        --build-only)
            build=1
            install=0
            launch=0
            shift
            ;;
        --install-only)
            build=0
            install=1
            launch=0
            shift
            ;;
        --no-launch)
            launch=0
            shift
            ;;
        --console)
            console=1
            shift
            ;;
        --allow-provisioning-updates)
            allow_provisioning_updates=1
            shift
            ;;
        --verbose-build)
            verbose_build=1
            shift
            ;;
        --list-devices)
            xcrun devicectl list devices
            exit
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            app_args=("$@")
            break
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

cd "$root"

if [[ "$install" -eq 1 || "$launch" -eq 1 || "$build" -eq 1 ]]; then
    [[ -n "$device" || -n "$destination" ]] || die "Pass --device, ICAN_DEVICE, or --destination. Use --list-devices to inspect devices."
fi

if [[ "$build" -eq 1 ]]; then
    [[ -f "$project/project.pbxproj" ]] || die "Missing $project. Run: bazel run //:xcodeproj"
    if [[ -z "$destination" ]]; then
        destination="$(default_destination_for_device "$device")"
    fi

    declare -a xcodebuild_args=(
        -project "$project"
        -scheme "$scheme"
        -configuration "$configuration"
        -destination "$destination"
        -derivedDataPath "$derived_data"
    )
    if [[ "$verbose_build" != "1" ]]; then
        xcodebuild_args+=(-quiet)
    fi
    if [[ "$allow_provisioning_updates" -eq 1 ]]; then
        xcodebuild_args+=(-allowProvisioningUpdates)
    fi
    xcodebuild_args+=(build)

    printf 'Building %s/%s for selected device...\n' "$project" "$scheme"
    xcodebuild "${xcodebuild_args[@]}"
fi

if [[ "$install" -eq 1 ]]; then
    [[ -n "$device" ]] || die "Install requires --device or ICAN_DEVICE."
    app_path="$(resolve_app_path "$app_path" "$derived_data" "$configuration")"
    printf 'Installing %s on selected device...\n' "$app_path"
    xcrun devicectl device install app --device "$device" "$app_path"
fi

if [[ "$launch" -eq 1 ]]; then
    [[ -n "$device" ]] || die "Launch requires --device or ICAN_DEVICE."
    declare -a launch_args=(
        xcrun devicectl device process launch
        --device "$device"
        --terminate-existing
    )
    if [[ "$console" -eq 1 ]]; then
        launch_args+=(--console)
    else
        tmpdir="${TMPDIR:-/tmp}"
        tmpdir="${tmpdir%/}"
        launch_json="$(mktemp "$tmpdir/ican-devicectl-launch-json.XXXXXX")"
        launch_log="$(mktemp "$tmpdir/ican-devicectl-launch-log.XXXXXX")"
        launch_args+=(--json-output "$launch_json")
    fi
    launch_args+=("$bundle_id")
    if [[ "${#app_args[@]}" -gt 0 ]]; then
        launch_args+=("${app_args[@]}")
    fi

    printf 'Launching %s on selected device...\n' "$bundle_id"
    if [[ "$console" -eq 1 ]]; then
        "${launch_args[@]}"
    else
        if ! "${launch_args[@]}" >"$launch_log" 2>&1; then
            cat "$launch_log" >&2
            rm -f "$launch_json" "$launch_log"
            die "devicectl launch failed."
        fi
        if [[ -s "$launch_log" ]]; then
            cat "$launch_log"
        fi
        if ! check_devicectl_json_outcome "$launch_json" "devicectl launch"; then
            rm -f "$launch_json" "$launch_log"
            exit 1
        fi
        rm -f "$launch_json" "$launch_log"
    fi
fi
