import SwiftUI
import Charts
import Combine
import SystemExtensions
import os.log

// Dashboard Tabs
enum DashboardTab: String, CaseIterable {
    case ports = "Interfaces"
    case dashboard = "Dashboard"
    case messages = "Messages"
    case bandwidth = "Test 1"
    case bidir = "Test 2"

    var icon: String {
        switch self {
        case .ports: return "cable.connector"
        case .dashboard: return "gauge.with.dots.needle.bottom.100percent"
        case .messages: return "list.bullet.rectangle.portrait"
        case .bandwidth: return "speedometer"
        case .bidir: return "arrow.left.arrow.right"
        }
    }
}

// Bus Selection
enum BusSelection: String, CaseIterable {
    case all = "All Buses"
    case bus0 = "CAN Bus 0"
    case bus1 = "CAN Bus 1"
}

struct HeaderView: View {
    @Binding var selectedTab: DashboardTab
    @ObservedObject var viewModel: CANDashboardViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Tab Bar
            HStack(spacing: 4) {
                ForEach(DashboardTab.allCases, id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                            Text(tab.rawValue)
                        }
                        .fontWeight(.medium)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .foregroundColor(selectedTab == tab ? .white : .secondary)
                        .background(selectedTab == tab ? Color.blue : Color.clear)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                // Compact connection status
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.connectionStatusColor)
                        .frame(width: 8, height: 8)
                    Text(viewModel.connectionStatusText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if viewModel.isCANOpen {
                        Text("CAN Open")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()
        }
        .background(.ultraThinMaterial)
    }
}
