import Foundation
import SwiftUI

struct CANLogMessage: Identifiable {
    let id = UUID()
    let timestamp: Date
    let bus: String
    let canId: String
    let dlc: Int
    let data: String
    let type: String
    let direction: String
    
    var timestampString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SS"
        return formatter.string(from: timestamp)
    }
}



struct BusStatus: Identifiable {
    let id = UUID()
    let name: String
    var messageRate: Double
    var messageCount: Int
    var busLoad: Double
    var isConnected: Bool
    var isActive: Bool
    
    var statusColor: Color {
        if !isConnected { return .red }
        if !isActive { return .orange }
        return .green
    }
}

struct MessageDistPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let count: Int
}

struct BusLoadPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let bus0Load: Double
    let bus1Load: Double
}

struct CANIdDistribution: Identifiable {
    let id = UUID()
    let canId: String
    let count: Int
}

struct MessageRatePoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let messageRate: Double
}

struct BandwidthHistoryPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let txRate: Double
    let rxRate: Double
}

struct BidirHistoryPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let txRateA1: Double
    let rxRateA1: Double
    let txRateA2: Double
    let rxRateA2: Double
}

struct CANDashboardMetrics {
    var messageRate: Double = 0
    var busLoad: Double = 0
    var throughput: Double = 0 // KB/s
    var totalMessages: Int = 0
    var messagesReceived: Int = 0
    var messagesSent: Int = 0
    var errorFrames: Int = 0
    var uptime: TimeInterval = 0
    var activeNodes: Int = 0
    var networkHealth: String = "Good"
    
    var uptimeString: String {
        let hours = Int(uptime) / 3600
        let minutes = (Int(uptime) % 3600) / 60
        let seconds = Int(uptime) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
