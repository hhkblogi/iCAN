import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var viewModel = CANDashboardViewModel()
    @State private var selectedTab: DashboardTab = .ports

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                selectedTab: $selectedTab,
                viewModel: viewModel
            )

            ZStack {
                switch selectedTab {
                case .ports:
                    PortsView(viewModel: viewModel)
                case .dashboard:
                    DashboardView(viewModel: viewModel)
                case .messages:
                    MessageLogView(viewModel: viewModel)
                case .bandwidth:
                    BandwidthTestView(viewModel: viewModel)
                case .bidir:
                    BidirTestView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.platformGroupedBackground)
        }
    }
}
