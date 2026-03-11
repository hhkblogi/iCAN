import SwiftUI
import Charts

struct ChartsView: View {
    @ObservedObject var viewModel: CANDashboardViewModel
    @State private var selectedSignal: SignalFilter = .all
    
    enum SignalFilter: String, CaseIterable {
        case all = "All"
        case engineSpeed = "Engine"
        case vehicleSpeed = "Speed"
        case throttle = "Throttle"
        case temperature = "Temp"
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Bus Load Over Time
                ChartCard(title: "Bus Load Over Time") {
                    if viewModel.busLoadHistory.isEmpty {
                        Text("Waiting for data...")
                            .foregroundColor(.secondary)
                            .frame(height: 200)
                    } else {
                        Chart {
                            ForEach(viewModel.busLoadHistory) { point in
                                AreaMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("Bus 0 Load", point.bus0Load)
                                )
                                .foregroundStyle(.blue.opacity(0.3))
                                
                                LineMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("Bus 0 Load", point.bus0Load)
                                )
                                .foregroundStyle(.blue)
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                                AxisValueLabel {
                                    if let v = value.as(Double.self) {
                                        Text("\(Int(v))%")
                                    }
                                }
                                AxisGridLine()
                            }
                        }
                        .chartXAxis {
                            AxisMarks { _ in
                                AxisValueLabel(format: .dateTime.hour().minute().second())
                            }
                        }
                        .frame(height: 200)
                    }
                }
                
                // Message Rate Over Time
                ChartCard(title: "Message Rate (msg/s)") {
                    if viewModel.messageRateHistory.isEmpty {
                        Text("Waiting for data...")
                            .foregroundColor(.secondary)
                            .frame(height: 200)
                    } else {
                        Chart {
                            ForEach(viewModel.messageRateHistory) { point in
                                LineMark(
                                    x: .value("Time", point.timestamp),
                                    y: .value("Rate", point.messageRate)
                                )
                                .foregroundStyle(.purple)
                            }
                        }
                        .chartXAxis {
                            AxisMarks { _ in
                                AxisValueLabel(format: .dateTime.hour().minute().second())
                            }
                        }
                        .chartYAxis {
                            AxisMarks(position: .leading)
                        }
                        .frame(height: 200)
                    }
                }
                
                // CAN ID Distribution
                ChartCard(title: "Active CAN IDs (Top 10)") {
                    if viewModel.idDistribution.isEmpty {
                        Text("Waiting for data...")
                            .foregroundColor(.secondary)
                            .frame(height: 200)
                    } else {
                        Chart(viewModel.idDistribution) { item in
                            BarMark(
                                x: .value("Count", item.count),
                                y: .value("CAN ID", item.canId)
                            )
                            .foregroundStyle(Color.blue.gradient)
                        }
                        .frame(height: 200)
                    }
                }
                
                // Message Distribution Over Time
                ChartCard(title: "Messages Per Second") {
                    if viewModel.messageDistribution.isEmpty {
                        Text("Waiting for data...")
                            .foregroundColor(.secondary)
                            .frame(height: 150)
                    } else {
                        Chart(viewModel.messageDistribution) { item in
                            BarMark(
                                x: .value("Time", item.timestamp),
                                y: .value("Messages", item.count)
                            )
                            .foregroundStyle(Color.purple.gradient)
                        }
                        .frame(height: 150)
                    }
                }
                
                Spacer(minLength: 20)
            }
            .padding(.top, 16)
            .padding(.horizontal)
        }
    }
}
