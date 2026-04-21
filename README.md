# iCAN

An iPadOS app for monitoring and testing CAN bus hardware via USB adapters, built with SwiftUI and Apple's DriverKit framework.

## Supported Hardware

| Protocol | USB VID | Adapters | App Store | Development |
|---|---|---|---|---|
| SLCAN | `0x16D0` | CANable, SH-C31G, and other SLCAN/LAWICEL serial adapters | ✅ Supported | ✅ Supported |
| gs_usb | `0x1D50` | candleLight, CANtact, and other gs_usb-compatible devices | ❌ Not supported | ✅ Supported |
| PCAN-USB | `0x0C72` | PEAK PCAN-USB Pro FD | ❌ Not supported | ✅ Supported |

DriverKit on iPadOS requires Apple to approve each USB Vendor ID for App Store
distribution. Only VID `0x16D0` is currently approved — the App Store build
of iCAN will only bind to SLCAN adapters. Development builds sign the dext
with entitlements that include all three VIDs (see
`usb_can_driver/USBCANDriver.entitlements`), so gs_usb and PCAN-USB adapters
continue to work when sideloaded onto your own iPad.

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
- [Bazel](https://bazel.build/) 8+ (pinned to 8.6.0 via `.bazelversion`)

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

# 4. Open ican.xcodeproj in Xcode, select your iPad, and run
open ican.xcodeproj
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
| `can_client/` | C++23 | App-to-driver IPC via IOKit, manages the shared memory ring buffer (SPSC lock-free, 256KB RX + per-channel 16KB TX rings) |
| `usb_can_driver/` | C++23 | DriverKit extension with compile-time codec dispatch via `CanProtocol` concept |
| `ican/` | Swift + C++23 | SwiftUI app. `CANDashboardViewModel` is the central state container. `ican/perf/` has C++ engines for low-latency testing |
| `stub_lib/` | — | DriverKit profile runtime linked into driver builds |
| `bazel/driverkit/` | Starlark | Custom Bazel rules for IIG compilation, DriverKit C++ builds, .dext bundling |

### IPC Flow

```
App writes TX ring → driver drains & encodes via codec → USB out
USB in → driver decodes → RX ring → app reads
TX entries: [uint16_t frameSize][can_frame/canfd_frame bytes]
RX entries: [uint16_t frameSize][uint64_t timestamp_us][can_frame/canfd_frame bytes]
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
bazel build //:app_ios                          # App only
bazel build //:app_ios_with_dext                # App + embedded DriverKit extension
bazel build //usb_can_driver:USBCANDriver    # .dext only

# Test
bazel test //...                             # Run all tests

# Build configs
bazel build -c dbg //:app_ios                 # Debug build
bazel build -c opt //:app_ios                 # Optimized build
```

Disk cache is configured at `~/.cache/bazel-disk` via `.bazelrc`.

## Testing

```bash
bazel test //ican:flight_window_test         # FlightWindow delivery tracker (17 tests)
bazel test //...                             # All tests
```

## Signing & Deployment

> See [docs/build-and-signing.md](docs/build-and-signing.md) for the full guide on build paths, provisioning profiles, and troubleshooting.

- iPad-only, minimum iPadOS 26.0
- Team ID loaded from `team_config.bzl` (gitignored — never hardcode)
- App bundle: `com.<TEAM>.iCAN`
- Driver bundle: `com.<TEAM>.iCAN.driver`
- The app requires the `com.apple.developer.driverkit.communicates-with-drivers` entitlement
- The pre-commit hook in `.githooks/` prevents accidental Team ID and `.mobileprovision` commits
- `scripts/embed_dext.sh` is the Xcode post-build hook that builds the .dext via Bazel, embeds it into the app bundle, and re-signs

### Development vs Distribution Profiles

The app uses two separate sets of provisioning profiles:

| | Development | App Store Distribution |
|---|---|---|
| **Purpose** | Day-to-day builds on your iPad via Xcode | App Store / TestFlight submission |
| **Build target** | `//:app_ios` (via Xcode) | `//:app_ios_appstore_with_dext --config=appstore` |
| **USB VIDs** | Wildcard `*` (all adapters) | Specific VIDs (requires Apple approval per VID) |
| **Signing** | Apple Development cert | Apple Distribution cert |
| **Profile type** | Xcode-managed (auto) | Manual (downloaded from portal) |

**Important:** Development and distribution provisioning profiles must not be mixed. If you download
new distribution profiles from the Apple Developer Portal, they may conflict with your development
profiles and cause install failures (`0xe800801f: Attempted to install a Beta profile without the
proper entitlement`). If this happens:

1. Remove the distribution profiles from `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`
2. Keep only the Xcode-managed development profiles (named `iOS Team Provisioning Profile: ...`)
3. Rebuild and deploy

To check whether matching development profiles are installed:
```bash
# Presence check — copies the matching profile to /dev/null (exits 0 if found, 1 if not)
scripts/find_profile.sh <TEAM_ID> com.<TEAM>.iCAN /dev/null dev
scripts/find_profile.sh <TEAM_ID> com.<TEAM>.iCAN.driver /dev/null dev
```

### App Store Submission

Requires Apple-approved DriverKit USB Transport entitlements (per VID) and an Apple Distribution
certificate. See `BUILD.bazel` for the `app_ios_appstore_with_dext` target configuration.

```bash
bazel build //:app_ios_appstore_with_dext --config=appstore
# Output: bazel-bin/app_ios_appstore_with_dext.ipa → upload via Transporter
```

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
