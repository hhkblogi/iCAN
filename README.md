# iCAN

An iPadOS app for monitoring and testing CAN bus hardware via USB adapters using Apple's DriverKit framework.

## Supported Hardware

| Protocol | Adapters |
|---|---|
| SLCAN | Any serial CAN adapter using the SLCAN/LAWICEL text protocol |
| gs_usb | candleLight, canable, CANtact, and other gs_usb-compatible devices |
| PCAN-USB | PEAK PCAN-USB Pro FD |

## Requirements

- iPad with M1 chip or later
- iPadOS 26.0+
- USB-C connection to CAN adapter
- Apple Developer account (DriverKit entitlement required)

## Quick Start

```bash
# 1. Clone and bootstrap
git clone https://github.com/hhkblogi/iCAN.git
cd iCAN
./scripts/setup.sh

# 2. Set your Apple Developer Team ID
#    Edit team_config.bzl and set TEAM_ID

# 3. Generate Xcode project
bazel run //:xcodeproj

# 4. Open in Xcode, select your iPad, and run
```

## Architecture

```
┌──────────────────────────────────────────────┐
│          ican/ — SwiftUI iPad App            │
│  Views + ViewModels + C++ perf layer         │
└──────────────────┬───────────────────────────┘
                   │ IOKit IPC + lock-free shared ring buffer
┌──────────────────┴───────────────────────────┐
│      usb_can_driver/ — DriverKit .dext       │
│  Protocol codecs: SLCAN, gs_usb, PCAN-USB   │
└──────────────────┬───────────────────────────┘
                   │ USB
              Hardware Adapter
```

**Key modules:**

- **protocol/** — Header-only CAN frame types shared by all modules
- **can_client/** — C++ library for app-to-driver IPC via IOKit and a lock-free SPSC ring buffer
- **usb_can_driver/** — DriverKit extension with compile-time codec dispatch
- **ican/** — SwiftUI app with C++ performance engines for low-latency CAN testing

## Build

Requires [Bazel](https://bazel.build/) 8.x with bzlmod enabled.

```bash
bazel build //:iCAN                        # App only
bazel build //:iCAN_with_dext              # App + DriverKit extension
bazel test //...                           # Run all tests
```

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.
