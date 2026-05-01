//
//  iCANApp.swift
//  iCAN
//

import SwiftUI
import os.log

private let lifecycleLog = OSLog(subsystem: "com.hhkblogi.ican", category: "Lifecycle")

@main
struct iCANApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Keep these lifecycle markers at .error so short xctrace Logging captures
        // in scripts/stream_ios_device_logs.sh can reliably see app-owned rows.
        os_log(.error, log: lifecycleLog, "iCAN lifecycle: launch")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                os_log(.error, log: lifecycleLog, "iCAN lifecycle: active")
            case .inactive:
                os_log(.error, log: lifecycleLog, "iCAN lifecycle: inactive")
            case .background:
                os_log(.error, log: lifecycleLog, "iCAN lifecycle: background")
            @unknown default:
                os_log(.error, log: lifecycleLog, "iCAN lifecycle: unknown scene phase")
            }
        }
    }
}
