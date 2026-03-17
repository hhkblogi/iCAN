import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var viewModel = CANDashboardViewModel()
    @State private var selectedTab: DashboardTab = .dashboard
    @State private var showConnectionSheet = false
    
    var body: some View {
        VStack(spacing: 0) {
            HeaderView(
                selectedBus: $viewModel.selectedBus,
                selectedTab: $selectedTab,
                viewModel: viewModel,
                showConnectionSheet: $showConnectionSheet
            )
            
            ZStack {
                switch selectedTab {
                case .dashboard:
                    DashboardView(viewModel: viewModel)
                case .messages:
                    MessageLogView(viewModel: viewModel)
                case .bandwidth:
                    BandwidthTestView(viewModel: viewModel)
                case .bidir:
                    BidirTestView(viewModel: viewModel)
                case .distBidir:
                    DistBidirTestView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.platformGroupedBackground)
        }
        .sheet(isPresented: $showConnectionSheet) {
            ConnectionSheet(viewModel: viewModel)
        }
    }
}
