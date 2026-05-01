#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  stream_ios_device_logs.sh --device <name-or-id> [options] [-- app-args...]

Stream device-side development output with the best available local backend.

The default backend uses:
  xcrun devicectl device process launch --console

That is useful for agent loops because it installs no extra tools and exits when
the app exits. For device unified logs, use the xctrace backend to capture a
short native Logging trace and export its os-log table, or use the optional
idevicesyslog backend for live third-party syslog streaming.

Required for console backend unless ICAN_DEVICE is set:
  -d, --device <name-or-id>      Device name, CoreDevice UUID, UDID, or serial.

Options:
      --udid <udid>              Device UDID for idevicesyslog/xctrace.
      --bundle-id <id>           App bundle id. Default: com.hhkblogi.ican.
      --backend <name>           console, xctrace, or idevicesyslog. Default: console.
      --process <name>           Process filter for idevicesyslog. Default: app_ios.
      --time-limit <duration>    xctrace capture duration. Default: 10s.
      --log-output-dir <path>    Directory for default xctrace outputs. Default: /tmp.
      --output <path>            xctrace output .trace path. Default: <log-output-dir>/ican-logging.trace.
      --export <path>            xctrace os-log XML export. Default: <log-output-dir>/ican-os-log.xml.
      --filter <pattern>         Regex to print matching exported logs.
                                  Default: app_ios process + iCAN log categories.
      --no-terminate-existing    Do not relaunch the app before attaching console.
      --list-devices             Print devicectl's visible devices and exit.
  -h, --help                     Show this help.

Examples:
  bazel run //:stream_ios_device_logs -- --device <device-name-or-id>
  ICAN_DEVICE=<device-name-or-id> bazel run //:stream_ios_device_logs
  bazel run //:stream_ios_device_logs -- --backend xctrace --time-limit 15s
  bazel run //:stream_ios_device_logs -- --backend xctrace --log-output-dir /tmp/ican-logs
  bazel run //:stream_ios_device_logs -- --backend idevicesyslog --udid <device-udid>
  ICAN_LOG_BACKEND=idevicesyslog ICAN_DEVICE_UDID=<device-udid> bazel run //:stream_ios_device_logs
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

    local config_device_name
    config_device_name="$(read_bzl_string "$config" ICAN_DEVICE_NAME)"
    if [[ -z "$device_name" && -n "$config_device_name" ]]; then
        device_name="$config_device_name"
    fi

    local config_device
    config_device="$(read_bzl_string "$config" ICAN_DEVICE)"
    if [[ -z "$config_device" ]]; then
        config_device="$(read_bzl_string "$config" ICAN_DEVICE_ID)"
    fi
    if [[ -z "$config_device" ]]; then
        config_device="$config_device_name"
    fi

    if [[ -z "$device" && -n "$config_device" ]]; then
        device="$config_device"
    fi

    local config_device_udid
    config_device_udid="$(read_bzl_string "$config" ICAN_DEVICE_UDID)"
    if [[ -z "$device_udid" && -n "$config_device_udid" ]]; then
        device_udid="$config_device_udid"
    fi
}

resolve_xctrace_device() {
    if [[ -n "$device_udid" ]]; then
        printf '%s\n' "$device_udid"
        return
    fi

    [[ -n "$device_name" ]] || die "xctrace backend requires --device <name>, ICAN_DEVICE_NAME, ICAN_DEVICE_UDID, or --udid."

    local tmpdir
    tmpdir="${TMPDIR:-/tmp}"
    tmpdir="${tmpdir%/}"

    local devices_json
    devices_json="$(mktemp "$tmpdir/ican-xcdevice.XXXXXX")"
    trap 'rm -f "$devices_json"; trap - RETURN' RETURN
    if ! xcrun xcdevice list --timeout=5 >"$devices_json"; then
        die "xcrun xcdevice list failed while resolving the selected device for xctrace."
    fi

    ICAN_XCTRACE_DEVICE_NAME="$device_name" python3 - "$devices_json" <<'PY'
import json
import os
import sys

name = os.environ["ICAN_XCTRACE_DEVICE_NAME"]
with open(sys.argv[1], "r", encoding="utf-8") as f:
    devices = json.load(f)

matches = [
    device for device in devices
    if device.get("name") == name
    and device.get("platform") == "com.apple.platform.iphoneos"
]
available = [device for device in matches if device.get("available")]

if not available:
    sys.exit(1)

print(available[0]["identifier"])
PY
}

device="${ICAN_DEVICE:-}"
device_name="${ICAN_DEVICE_NAME:-}"
device_udid="${ICAN_DEVICE_UDID:-}"
bundle_id="${ICAN_BUNDLE_ID:-com.hhkblogi.ican}"
backend="${ICAN_LOG_BACKEND:-console}"
process_name="${ICAN_LOG_PROCESS:-app_ios}"
time_limit="${ICAN_LOG_TIME_LIMIT:-10s}"
log_output_dir="${ICAN_LOG_OUTPUT_DIR:-/tmp}"
xctrace_output="${ICAN_LOG_TRACE_OUTPUT:-}"
xctrace_export="${ICAN_LOG_EXPORT_OUTPUT:-}"
xctrace_output_explicit=0
xctrace_export_explicit=0
if [[ -n "${ICAN_LOG_TRACE_OUTPUT:-}" ]]; then
    xctrace_output_explicit=1
fi
if [[ -n "${ICAN_LOG_EXPORT_OUTPUT:-}" ]]; then
    xctrace_export_explicit=1
fi
filter_pattern="${ICAN_LOG_FILTER:-app_ios \\(|iCAN lifecycle|Lifecycle|CANConnection|SLCAN|CANClient|fmt=\"Dashboard\"|subsystem[^>]*com\\.hhkblogi\\.ican}"
terminate_existing=1
declare -a app_args=()

root="$(workspace_root)"
load_device_config "$root"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--device)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            device="$2"
            if is_id_like "$device"; then
                device_name=""
            else
                device_name="$device"
            fi
            shift 2
            ;;
        --udid)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            device_udid="$2"
            shift 2
            ;;
        --bundle-id)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            bundle_id="$2"
            shift 2
            ;;
        --backend)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            backend="$2"
            shift 2
            ;;
        --process)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            process_name="$2"
            shift 2
            ;;
        --time-limit)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            time_limit="$2"
            shift 2
            ;;
        --log-output-dir)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            log_output_dir="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            xctrace_output="$2"
            xctrace_output_explicit=1
            shift 2
            ;;
        --export)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            xctrace_export="$2"
            xctrace_export_explicit=1
            shift 2
            ;;
        --filter)
            [[ $# -ge 2 ]] || die "$1 requires a value"
            filter_pattern="$2"
            shift 2
            ;;
        --no-terminate-existing)
            terminate_existing=0
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

if [[ "$log_output_dir" != "/" ]]; then
    log_output_dir="${log_output_dir%/}"
fi
[[ -n "$log_output_dir" ]] || die "--log-output-dir requires a non-empty path"
if [[ "$xctrace_output_explicit" -eq 0 ]]; then
    xctrace_output="$log_output_dir/ican-logging.trace"
fi
if [[ "$xctrace_export_explicit" -eq 0 ]]; then
    xctrace_export="$log_output_dir/ican-os-log.xml"
fi

if [[ "$backend" == "idevicesyslog" ]]; then
    [[ -n "$device_udid" ]] || die "idevicesyslog requires --udid or ICAN_DEVICE_UDID. CoreDevice UUIDs from ICAN_DEVICE/ICAN_DEVICE_ID are not accepted by libimobiledevice. Run idevice_id -l to find the UDID."
elif [[ "$backend" == "xctrace" ]]; then
    [[ -n "$device_name" || -n "$device_udid" ]] || die "xctrace requires --device <name>, ICAN_DEVICE_NAME, ICAN_DEVICE_UDID, or --udid."
else
    [[ -n "$device" ]] || die "Pass --device or ICAN_DEVICE. Use --list-devices to inspect devices."
fi

case "$backend" in
    console)
        declare -a launch_args=(
            xcrun devicectl device process launch
            --device "$device"
            --console
        )
        if [[ "$terminate_existing" -eq 1 ]]; then
            launch_args+=(--terminate-existing)
        fi
        launch_args+=("$bundle_id")
        if [[ "${#app_args[@]}" -gt 0 ]]; then
            launch_args+=("${app_args[@]}")
        fi

        printf 'Launching %s on selected device with devicectl console attached...\n' "$bundle_id"
        "${launch_args[@]}"
        ;;
    idevicesyslog)
        command -v idevicesyslog >/dev/null 2>&1 || die "idevicesyslog is not installed. Install libimobiledevice or use --backend console."
        printf 'Streaming idevicesyslog for %s from selected device...\n' "$process_name"
        idevicesyslog --udid "$device_udid" --process "$process_name"
        ;;
    xctrace)
        xctrace_device="$(resolve_xctrace_device)" || die "xctrace could not resolve the selected device. Open Console.app device streaming or check xcrun xcdevice list."
        mkdir -p "$log_output_dir"
        rm -rf "$xctrace_output" "$xctrace_export"
        xctrace_record_log="$(mktemp "${TMPDIR:-/tmp}/ican-xctrace-record.XXXXXX")"
        printf 'Recording native device logs with xctrace for %s to %s...\n' "$time_limit" "$xctrace_output"
        if ! xcrun xctrace record \
            --template Logging \
            --device "$xctrace_device" \
            --all-processes \
            --time-limit "$time_limit" \
            --output "$xctrace_output" \
            --quiet >"$xctrace_record_log" 2>&1; then
            cat "$xctrace_record_log" >&2
            if grep -Eq "Timed out waiting for device to boot|Cannot record until the device is connected" "$xctrace_record_log"; then
                rm -f "$xctrace_record_log"
                die "xctrace could not start the Logging trace because Xcode/CoreDevice does not currently have the selected physical device in the Connected state. Open Xcode Devices and Simulators or Console.app, unlock/trust the device, then rerun."
            fi
            rm -f "$xctrace_record_log"
            die "xctrace record failed."
        fi
        if [[ -s "$xctrace_record_log" ]]; then
            cat "$xctrace_record_log" >&2
        fi
        rm -f "$xctrace_record_log"
        xctrace_export_log="$(mktemp "${TMPDIR:-/tmp}/ican-xctrace-export.XXXXXX")"
        set +e
        xcrun xctrace export \
            --input "$xctrace_output" \
            --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-log"]' \
            --output "$xctrace_export" >"$xctrace_export_log" 2>&1
        xctrace_export_status=$?
        set -e
        if [[ "$xctrace_export_status" -ne 0 ]]; then
            cat "$xctrace_export_log" >&2
            rm -f "$xctrace_export_log"
            die "xctrace recorded a trace but failed to export the os-log table. Trace saved at $xctrace_output."
        fi
        rm -f "$xctrace_export_log"
        printf 'Exported native os-log XML to %s\n' "$xctrace_export"
        if [[ -n "$filter_pattern" ]]; then
            printf 'Matching exported logs with pattern: %s\n' "$filter_pattern"
            set +e
            grep -E "$filter_pattern" "$xctrace_export"
            grep_status=$?
            set -e
            if [[ "$grep_status" -gt 1 ]]; then
                die "failed to evaluate --filter regex against exported logs."
            fi
        fi
        ;;
    *)
        die "Unsupported backend: $backend"
        ;;
esac
