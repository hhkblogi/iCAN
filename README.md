# iCAN

An iPadOS app for monitoring and testing CAN bus hardware via USB adapters, built with SwiftUI and Apple's DriverKit framework.

## Supported Hardware

| Protocol | Adapters |
|---|---|
| SLCAN | Any serial CAN adapter using the SLCAN/LAWICEL text protocol (e.g. CANable, SH-C31G) |
| gs_usb | candleLight, CANtact, and other gs_usb-compatible devices |
| PCAN-USB | PEAK PCAN-USB Pro FD |

## Features

- **Real-time dashboard** with per-interface TX/RX rates, bus load, and traffic charts
- **Message log** with per-interface filtering and CAN ID decoding
- **Multi-adapter support** with independent CAN channels and mixed codec diagnostics
- **DriverKit extension** with compile-time codec dispatch and zero-copy shared ring buffer IPC

**Work in progress:**

- DBC file parser for signal-level decoding and display
- CAN client SDK for third-party iPadOS apps to access USB CAN adapters via the shared driver

## Requirements

- iPad with Apple Silicon (M-series chip)
- iPadOS 26.0+
- USB-C connection to CAN adapter
- Apple Developer account (DriverKit entitlement required)
- [Bazel](https://bazel.build/) 8+

## Quick Start

```bash
# 1. Clone and bootstrap
git clone https://github.com/hhkblogi/iCAN.git
cd iCAN
./scripts/setup.sh

# 2. Set your Apple Developer Team ID
#    Edit team_config.bzl and set TEAM_ID to your 10-character Team ID

# 3. Generate Xcode project
bazel run //:xcodeproj

# 4. Open iCAN.xcodeproj in Xcode, select your iPad, and run
open iCAN.xcodeproj
```

`scripts/setup.sh` creates `team_config.bzl` from the template and activates the pre-commit hook that prevents accidental Team ID commits.

## Architecture

```
┌──────────────────────────────────────────────┐
│          ican/ — SwiftUI iPad App            │
│  Views + ViewModels + C++ perf layer         │
└──────────────────┬───────────────────────────┘
                   │ IOKit IPC + lock-free shared ring buffer (V5)
┌──────────────────┴───────────────────────────┐
│      usb_can_driver/ — DriverKit .dext       │
│  Protocol codecs: SLCAN, gs_usb, PCAN-USB    │
└──────────────────┬───────────────────────────┘
                   │ USB
              Hardware Adapter
```

### Modules

| Module | Language | Description |
|---|---|---|
| `protocol/` | C++ (header-only) | CAN frame types (`can_frame`, `canfd_frame`, error frames) shared by all modules |
| `can_client/` | C++23 | App-to-driver IPC via IOKit, manages the shared memory ring buffer (SPSC lock-free, 64KB RX + 16KB TX) |
| `usb_can_driver/` | C++23 | DriverKit extension with compile-time codec dispatch via `CanProtocol` concept |
| `ican/` | Swift + C++23 | SwiftUI app. `CANDashboardViewModel` is the central state container. `ican/perf/` has C++ engines for low-latency testing |
| `stub_lib/` | — | DriverKit profile runtime linked into driver builds |
| `bazel/driverkit/` | Starlark | Custom Bazel rules for IIG compilation, DriverKit C++ builds, .dext bundling |

### IPC Flow

```
App writes TX ring → driver drains & encodes via codec → USB out
USB in → driver decodes → RX ring → app reads
Ring entries: [uint16_t size][canfd_frame][uint64_t timestamp_us]
```

### Languages & Interop

- **C++23** — Driver, can_client, perf layer (no exceptions, no RTTI in driver code)
- **Swift** — All UI via SwiftUI with C++ interop (`-cxx-interoperability-mode=default`)
- **Bridging** — `ican/iCAN-Bridging-Header.h` exposes C++ to Swift. `CANClient` uses pimpl (`shared_ptr`) for safe cross-language ownership

## Build

```bash
# Generate Xcode project (main development workflow)
bazel run //:xcodeproj

# Build targets
bazel build //:iCAN                          # App only
bazel build //:iCAN_with_dext                # App + embedded DriverKit extension
bazel build //usb_can_driver:USBCANDriver    # .dext only

# Test
bazel test //...                             # Run all tests

# Build configs
bazel build -c dbg //:iCAN                   # Debug build
bazel build -c opt //:iCAN                   # Optimized build
```

Disk cache is configured at `~/.cache/bazel-disk` via `.bazelrc`.

## Testing

```bash
bazel test //ican:flight_window_test         # FlightWindow delivery tracker (17 tests)
bazel test //...                             # All tests
```

## Signing & Deployment

- iPad-only, minimum iPadOS 26.0
- Team ID loaded from `team_config.bzl` (gitignored — never hardcode)
- App bundle: `com.<TEAM>.iCAN`
- Driver bundle: `com.<TEAM>.iCAN.driver`
- The app requires the `com.apple.developer.driverkit.communicates-with-drivers` entitlement
- The pre-commit hook in `.githooks/` prevents accidental Team ID and provisioning profile commits
- `scripts/embed_dext.sh` is the Xcode post-build hook that builds the .dext via Bazel, embeds it into the app bundle, and re-signs

## Protocol Attribution

The USB protocol codecs in `usb_can_driver/codecs/` are clean-room implementations.
Protocol constants and wire formats are derived from publicly observable USB traffic
and the following open-source references:

- **PCAN uCAN protocol:** Linux kernel `drivers/net/can/usb/peak_usb/pcan_usb_fd.c` (GPL-2.0).
  No code was copied; only the wire-level protocol specification (message types, command
  opcodes, bit timing register layout) was used as a reference. The uCAN wire format is
  a hardware interface specification, not a copyrightable work.
- **gs_usb protocol:** Linux kernel `drivers/net/can/usb/gs_usb.c` (GPL-2.0). Same approach.
- **SLCAN protocol:** Public LAWICEL text protocol specification.

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.
