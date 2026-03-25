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
    case bidir = "Bidirectional"

    var icon: String {
        switch self {
        case .ports: return "cable.connector"
        case .dashboard: return "gauge.with.dots.needle.bottom.100percent"
        case .messages: return "list.bullet.rectangle.portrait"
        case .bidir: return "arrow.left.arrow.right"
        }
    }

    var isTest: Bool {
        self == .bidir
    }

    /// Tabs shown as top-level buttons
    static var mainTabs: [DashboardTab] { [.ports, .dashboard, .messages] }

    /// Test sub-tabs
    static var testTabs: [DashboardTab] { [.bidir] }
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
    @State private var lastTestTab: DashboardTab = .bidir

    var body: some View {
        VStack(spacing: 0) {
            // Main Tab Bar
            HStack(spacing: 4) {
                // Main tabs
                ForEach(DashboardTab.mainTabs, id: \.self) { tab in
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

                // Tests tab
                Button {
                    if !selectedTab.isTest {
                        selectedTab = lastTestTab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "flask")
                        Text("Tests")
                    }
                    .fontWeight(.medium)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .foregroundColor(selectedTab.isTest ? .white : .secondary)
                    .background(selectedTab.isTest ? Color.blue : Color.clear)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                Spacer()

                // Compact connection status
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.connectionStatusColor)
                        .frame(width: 8, height: 8)
                    Text("Connected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(viewModel.connectionStatusText)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Test sub-tabs (shown when a test is selected)
            if selectedTab.isTest {
                HStack(spacing: 4) {
                    ForEach(DashboardTab.testTabs, id: \.self) { tab in
                        Button {
                            selectedTab = tab
                            lastTestTab = tab
                        } label: {
                            Text(tab.rawValue)
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 14)
                            .foregroundColor(selectedTab == tab ? .white : .secondary)
                            .background(selectedTab == tab ? Color.indigo : Color.clear)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
            }

            Divider()
        }
        .background(.ultraThinMaterial)
    }
}
