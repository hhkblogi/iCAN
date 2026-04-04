import SwiftUI

struct DiagnosticView: View {
    @State private var diagnostics = ""
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("System Extensions")
                    .font(.headline)
                Spacer()
                Button {
                    refreshDiagnostics()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                }
            }

            Text(diagnostics.isEmpty ? "No diagnostics available. Tap refresh." : diagnostics)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color.platformSecondaryBackground)
                .cornerRadius(8)

            Link("Open iPad Settings to approve DriverKit Extensions", destination: URL(string: UIApplication.openSettingsURLString)!)
                .font(.caption)
                .foregroundColor(.blue)
        }
        .onAppear {
            refreshDiagnostics()
        }
    }

    private func refreshDiagnostics() {
        isRefreshing = true

        // In a real app we'd use OSSystemExtensionManager to get status
        // Since we're in SwiftUI, we'll just show some basic info about what we found

        var info = "DriverKit Extension Status\n"
        info += "------------------------\n\n"

        info += "Environment: iPadOS\n"

        // DriverKit services register as IOUserService (not by user class name).
        // Find our driver by enumerating IOUserService instances named "USBCANDriver".
        var driverCount = 0
        if let match = IOServiceMatching("IOUserService") {
            var iter: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS {
                var candidate = IOIteratorNext(iter)
                while candidate != 0 {
                    var cName = [CChar](repeating: 0, count: 128)
                    IORegistryEntryGetName(candidate, &cName)
                    if String(cString: cName) == "USBCANDriver" {
                        driverCount += 1
                    }
                    IOObjectRelease(candidate)
                    candidate = IOIteratorNext(iter)
                }
                IOObjectRelease(iter)
            }
        }

        if driverCount > 0 {
            info += "Status: ACTIVE\n"
            info += "Found \(driverCount) instance(s) of USBCANDriver.\n"
        } else {
            info += "Status: INACTIVE OR NOT APPROVED\n"
            info += "No instances of USBCANDriver found in IORegistry.\n"
            info += "Ensure adapter is plugged in and extension is approved in Settings.\n"
        }

        // Check for USB CAN adapters across all known VID/PIDs
        let knownAdapters: [(name: String, vid: Int, pid: Int)] = [
            ("SLCAN (SH-C31G/CANable)", 0x16D0, 0x117E),
            ("gs_usb (candleLight)",     0x1D50, 0x606F),
            ("PCAN-USB Pro FD",          0x0C72, 0x0011),
        ]
        info += "\nHardware Status:\n"
        var totalUSBCount = 0
        for adapter in knownAdapters {
            guard let usbMatchCF = IOServiceMatching("IOUSBHostDevice") else { continue }
            let usbMatch = usbMatchCF as NSMutableDictionary
            usbMatch["idVendor"] = adapter.vid
            usbMatch["idProduct"] = adapter.pid
            var usbIter: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, usbMatch as CFDictionary, &usbIter) == KERN_SUCCESS {
                var count = 0
                while IOIteratorNext(usbIter) != 0 {
                    count += 1
                }
                IOObjectRelease(usbIter)
                if count > 0 {
                    let isPCAN = adapter.vid == 0x0C72 && adapter.pid == 0x0011
                    let channelNote = isPCAN ? " (2 channels per device)" : ""
                    info += "Found \(count) \(adapter.name) adapter(s)\(channelNote) (VID=0x\(String(adapter.vid, radix: 16)), PID=0x\(String(adapter.pid, radix: 16)))\n"
                }
                totalUSBCount += count
            }
        }
        if totalUSBCount == 0 {
            info += "No known CAN adapters detected.\n"
        }

        if totalUSBCount > 0 && driverCount == 0 {
            info += "\nACTION REQUIRED: Device exists but driver failed to attach.\n"
            info += "1. Unplug the adapter\n"
            info += "2. Wait 5 seconds\n"
            info += "3. Plug back in\n"
            info += "4. Check Settings app for a 'Driver' approval prompt\n"
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            diagnostics = info
            isRefreshing = false
        }
    }
}
