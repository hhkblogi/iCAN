import SwiftUI
import Charts

struct DashboardView: View {
    @ObservedObject var viewModel: CANDashboardViewModel
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Top Stats Row
                HStack(spacing: 16) {
                    StatCard(
                        title: "System Status",
                        value: viewModel.metrics.networkHealth,
                        icon: "network",
                        color: viewModel.metrics.networkHealth == "Excellent" ? .green :
                                viewModel.metrics.networkHealth == "Good" ? .blue : .orange
                    )
                    
                    StatCard(
                        title: "Message Rate",
                        value: String(format: "%.0f msg/s", viewModel.metrics.messageRate),
                        icon: "speedometer",
                        color: .blue
                    )
                    
                    StatCard(
                        title: "Throughput",
                        value: String(format: "%.1f KB/s", viewModel.metrics.throughput),
                        icon: "arrow.up.arrow.down",
                        color: .purple
                    )
                    
                    StatCard(
                        title: "Bus Load",
                        value: String(format: "%.1f%%", viewModel.metrics.busLoad),
                        icon: "chart.pie.fill",
                        color: viewModel.metrics.busLoad > 80 ? .red :
                                viewModel.metrics.busLoad > 50 ? .orange : .green
                    )
                }
                .padding(.horizontal)
                
                // Hardware Status Cards
                HStack(spacing: 16) {
                    ForEach(viewModel.busStatuses) { status in
                        HardwareStatusCard(status: status)
                    }
                }
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
}

// Sub-components used by DashboardView
struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: icon)
                    .foregroundColor(color)
                    .font(.title3)
            }
            
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
