import SwiftUI
import Charts

struct DashboardView: View {
    @ObservedObject var viewModel: CANDashboardViewModel

    /// Available interface tabs
    private var interfaceTabs: [String] {
        var tabs = ["All"]
        for adapter in viewModel.adapters where adapter.isCANOpen {
            tabs.append(adapter.name)
        }
        return tabs
    }

    /// Index of the selected adapter (nil for "All")
    private var selectedAdapterIndex: Int? {
        guard viewModel.dashboardInterfaceFilter != "All" else { return nil }
        return viewModel.adapters.firstIndex(where: { $0.name == viewModel.dashboardInterfaceFilter })
    }

    /// Filtered bus statuses
    private var filteredBusStatuses: [BusStatus] {
        if let idx = selectedAdapterIndex, idx < viewModel.busStatuses.count {
            return [viewModel.busStatuses[idx]]
        }
        return viewModel.busStatuses
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Interface tabs
                HStack(spacing: 4) {
                    ForEach(interfaceTabs, id: \.self) { tab in
                        Button {
                            viewModel.dashboardInterfaceFilter = tab
                        } label: {
                            Text(tab)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 14)
                                .foregroundColor(viewModel.dashboardInterfaceFilter == tab ? .white : .secondary)
                                .background(viewModel.dashboardInterfaceFilter == tab ? Color.indigo : Color.clear)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
                .padding(.horizontal)

                // Top Stats Row
                // Metrics Table
                VStack(spacing: 0) {
                    // Header row
                    HStack(spacing: 0) {
                        Text("Interface")
                            .frame(width: 80, alignment: .leading)
                        Text("Status")
                            .frame(width: 120, alignment: .leading)
                        Text("TX msg/s")
                            .frame(width: 90, alignment: .trailing)
                        Text("RX msg/s")
                            .frame(width: 90, alignment: .trailing)
                        Text("TX KB/s")
                            .frame(width: 80, alignment: .trailing)
                        Text("RX KB/s")
                            .frame(width: 80, alignment: .trailing)
                        Text("Bus Load")
                            .frame(width: 80, alignment: .trailing)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.platformSecondaryBackground.opacity(0.5))

                    Divider()

                    // Data rows
                    ForEach(Array(viewModel.adapters.enumerated()), id: \.offset) { idx, adapter in
                        let status = idx < viewModel.busStatuses.count ? viewModel.busStatuses[idx] : nil

                        HStack(spacing: 0) {
                            // Interface name
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(interfaceStatusColor(adapter))
                                    .frame(width: 6, height: 6)
                                Text(adapter.name)
                                    .monospaced()
                            }
                            .frame(width: 80, alignment: .leading)

                            // Status
                            Text(interfaceStatusText(adapter))
                                .foregroundColor(.secondary)
                                .frame(width: 120, alignment: .leading)

                            if adapter.isCANOpen, let status {
                                // TX msg/s
                                Text(String(format: "%.0f", status.txRate))
                                    .foregroundColor(.blue)
                                    .monospacedDigit()
                                    .frame(width: 90, alignment: .trailing)

                                // RX msg/s
                                Text(String(format: "%.0f", status.messageRate))
                                    .foregroundColor(.purple)
                                    .monospacedDigit()
                                    .frame(width: 90, alignment: .trailing)

                                // TX KB/s
                                Text(String(format: "%.1f", status.txRate * 12 / 1024))
                                    .foregroundColor(.blue)
                                    .monospacedDigit()
                                    .frame(width: 80, alignment: .trailing)

                                // RX KB/s
                                Text(String(format: "%.1f", status.messageRate * 12 / 1024))
                                    .foregroundColor(.purple)
                                    .monospacedDigit()
                                    .frame(width: 80, alignment: .trailing)

                                // Bus Load
                                let load = CANBusLoad.busLoadPercent(
                                    framesPerSec: status.txRate + status.messageRate,
                                    bitrate: adapter.selectedBitrate.rawValue,
                                    isFD: adapter.canFDEnabled,
                                    dataBytes: adapter.canFDEnabled ? 64 : 8
                                )
                                Text(String(format: "%.1f%%", load))
                                    .fontWeight(.medium)
                                    .foregroundColor(load > 80 ? .red : load > 50 ? .orange : .primary)
                                    .monospacedDigit()
                                    .frame(width: 80, alignment: .trailing)
                            } else {
                                // Empty placeholders for closed/not open
                                Text("—").frame(width: 90, alignment: .trailing)
                                Text("—").frame(width: 90, alignment: .trailing)
                                Text("—").frame(width: 80, alignment: .trailing)
                                Text("—").frame(width: 80, alignment: .trailing)
                                Text("—").frame(width: 80, alignment: .trailing)
                            }
                        }
                        .font(.caption)
                        .padding(.horizontal)
                        .padding(.vertical, 6)

                        if idx < viewModel.adapters.count - 1 {
                            Divider().padding(.horizontal)
                        }
                    }
                }
                .background(Color.platformSecondaryBackground)
                .cornerRadius(12)
                .padding(.horizontal)

                // Charts Suite Row
                HStack(spacing: 16) {
                    // Traffic over time Mini Chart
                    ChartCard(title: "Traffic Volume (msg/s)") {
                        if viewModel.messageDistribution.isEmpty {
                            ContentUnavailableView("Waiting for data...", systemImage: "chart.xyaxis.line")
                        } else {
                            Chart {
                                ForEach(viewModel.messageDistribution) { point in
                                    AreaMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("Messages", point.count)
                                    )
                                    .foregroundStyle(
                                        .linearGradient(
                                            colors: [.blue.opacity(0.5), .blue.opacity(0.1)],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )

                                    LineMark(
                                        x: .value("Time", point.timestamp),
                                        y: .value("Messages", point.count)
                                    )
                                    .foregroundStyle(.blue)
                                }
                            }
                            .chartXAxis(.hidden)
                            .chartYAxis {
                                AxisMarks(position: .leading)
                            }
                        }
                    }

                    // ID Distribution Chart
                    ChartCard(title: "Active CAN IDs") {
                        if viewModel.idDistribution.isEmpty {
                            ContentUnavailableView("Waiting for data...", systemImage: "chart.pie")
                        } else {
                            Chart(viewModel.idDistribution) { item in
                                BarMark(
                                    x: .value("Count", item.count),
                                    y: .value("CAN ID", item.canId)
                                )
                                .foregroundStyle(by: .value("ID", item.canId))
                                .annotation(position: .trailing) {
                                    Text("\(item.count)").font(.caption).foregroundColor(.secondary)
                                }
                            }
                            .chartLegend(.hidden)
                            .chartXAxis(.hidden)
                        }
                    }
                }
                .frame(height: 250)
                .padding(.horizontal)

                Spacer(minLength: 20)
            }
            .padding(.vertical)
        }
    }

    private func interfaceStatusText(_ adapter: SerialAdapter) -> String {
        if !adapter.isConnected {
            return "closed"
        }
        if !adapter.isCANOpen {
            return "connected, not open"
        }
        if let idx = viewModel.adapters.firstIndex(where: { $0 === adapter }),
           idx < viewModel.busStatuses.count {
            let status = viewModel.busStatuses[idx]
            let rxActive = status.messageRate > 0
            let txActive = status.txRate > 0
            var parts: [String] = []
            if rxActive { parts.append("RX(\(status.rxReaderCount))") }
            if txActive { parts.append("TX(\(status.txWriterCount))") }
            if !parts.isEmpty { return parts.joined(separator: ", ") }
        }
        return "open, idle"
    }

    // TODO: Use .yellow for error state (CAN bus errors, overruns) when error tracking is added
    private func interfaceStatusColor(_ adapter: SerialAdapter) -> Color {
        if !adapter.isConnected { return .red }
        if !adapter.isCANOpen { return .orange }
        return .green
    }
}

// Sub-components used by DashboardView
struct StatCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
        }
        .padding()
        .background(Color.platformSecondaryBackground)
        .cornerRadius(12)
    }
}

struct HardwareStatusCard: View {
    let status: BusStatus

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Circle()
                    .fill(status.isConnected ? (status.isActive ? Color.green : Color.orange) : Color.red)
                    .frame(width: 8, height: 8)
                Text(status.name)
                    .font(.headline)
                Spacer()
            }

            Divider()

            HStack {
                VStack(alignment: .leading) {
                    Text("Messages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("\(status.messageCount)")
                        .font(.body)
                        .fontWeight(.semibold)
                }
                Spacer()
                VStack(alignment: .trailing) {
                    Text("Rate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f/s", status.messageRate))
                        .font(.body)
                        .fontWeight(.semibold)
                }
            }
        }
        .padding()
        .background(Color.platformSecondaryBackground)
        .cornerRadius(12)
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading) {
            Text(title)
                .font(.headline)
                .padding([.top, .leading, .trailing])

            content()
                .padding()
        }
        .background(Color.platformSecondaryBackground)
        .cornerRadius(12)
    }
}
