# Examples

## can-client-demo

A minimal iPadOS app that demonstrates **third-party access** to iCAN's USB CAN driver.

This app has a different bundle ID from iCAN and shares no UI code with it.
It proves that any iPadOS app with the `communicates-with-drivers` entitlement
can connect to the USBCANDriver dext installed by iCAN and read/write CAN frames.

### Prerequisites

1. **iCAN must be installed on the iPad** — it provides the DriverKit extension
2. A USB CAN adapter must be connected
3. The driver must be approved in Settings > Privacy & Security > Drivers

### Build

```bash
bazel build //examples/can-client-demo:app_ios
```

Or use Xcode (both apps appear in the same project):
```bash
bazel run //:xcodeproj
open ican.xcodeproj
# Select "app_ios (can-client-demo)" scheme → your iPad → Cmd+R
```

### Entitlements

The demo app requires a single entitlement:

```xml
<key>com.apple.developer.driverkit.communicates-with-drivers</key>
<true/>
```

Third-party developers building their own CAN apps need:
1. Register an App ID on the Apple Developer Portal
2. Enable the **DriverKit Communicates with Drivers** capability
3. Add the entitlement above to their app's entitlements file
4. Link against the `can_client` library (or reimplement the IOKit IPC protocol)

### How it works

```
can-client-demo app
        |
        | IOKit: IOServiceOpen (finds USBCANDriver by VID/PID)
        | IOConnectMapMemory64 (maps shared ring buffer)
        |
┌───────┴───────────────┐
│  USBCANDriver .dext   │  ← installed by iCAN, runs system-wide
│  (DriverKit extension)│
└───────┬───────────────┘
        |
    USB adapter
```

The `can_client` library handles all IOKit IPC automatically. Third-party apps
just call `CANClient.open()`, `openChannel()`, `read()`, `write()`.
