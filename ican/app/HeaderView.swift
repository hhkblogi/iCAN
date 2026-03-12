import SwiftUI
import Charts
import Combine
import SystemExtensions
import os.log

// Dashboard Tabs
enum DashboardTab: String, CaseIterable {
    case dashboard = "Dashboard"
    case charts = "Charts"
    case messages = "Messages"
    case bandwidth = "Test 1"
    case bidir = "Test 2"
    case distBidir = "Test 3"

    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.100percent"
        case .charts: return "chart.xyaxis.line"
        case .messages: return "list.bullet.rectangle.portrait"
        case .bandwidth: return "speedometer"
        case .bidir: return "arrow.left.arrow.right"
        case .distBidir: return "rectangle.on.rectangle"
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
    @Binding var selectedBus: BusSelection
    @Binding var selectedTab: DashboardTab
    @ObservedObject var viewModel: CANDashboardViewModel
    @Binding var showConnectionSheet: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Logo
                HStack(spacing: 10) {
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .mask(Image(systemName: "bolt.car.fill").font(.system(size: 24, weight: .bold)))
                    .frame(width: 30, height: 30)
                    
                    Text("AutoCAN Dashboard")
                        .font(.title3)
                        .fontWeight(.bold)
                }
                
                Spacer()

                // CAN Open Status Indicator
                if viewModel.isCANOpen {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("CAN Open")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.platformSecondaryBackground)
                    .cornerRadius(8)
                }
                
                // Connection Status Button
                Button {
                    showConnectionSheet = true
                } label: {
                    HStack {
                        Circle()
                            .fill(viewModel.connectionStatusColor)
                            .frame(width: 8, height: 8)
                        Text(viewModel.connectionStatusText)
                            .fontWeight(.medium)
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.platformSecondaryBackground)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // Bus Selector
                Menu {
                    ForEach(BusSelection.allCases, id: \.self) { bus in
                        Button {
                            selectedBus = bus
                        } label: {
                            HStack {
                                Text(bus.rawValue)
                                if selectedBus == bus {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                        Text(selectedBus.rawValue)
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.platformSecondaryBackground)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
            
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
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
            
            Divider()
        }
        .background(.ultraThinMaterial)
    }
}
