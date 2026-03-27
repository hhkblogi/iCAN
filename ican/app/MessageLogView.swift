import SwiftUI

struct MessageLogView: View {
    @ObservedObject var viewModel: CANDashboardViewModel
    @State private var searchText = ""
    @State private var autoScroll = true

    /// Available interface tabs: "All" + each adapter with CAN channel open
    private var interfaceTabs: [String] {
        var tabs = ["All"]
        for adapter in viewModel.adapters where adapter.isCANOpen {
            tabs.append(adapter.name)
        }
        return tabs
    }

    var filteredMessages: [CANLogMessage] {
        viewModel.messages.filter { msg in
            let matchesInterface = viewModel.messageInterfaceFilter == "All" || msg.bus == viewModel.messageInterfaceFilter
            let matchesSearch = searchText.isEmpty ||
                msg.canId.localizedCaseInsensitiveContains(searchText) ||
                msg.data.localizedCaseInsensitiveContains(searchText)
            return matchesInterface && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Interface tabs + controls
            VStack(spacing: 8) {
                // Interface sub-tabs
                HStack(spacing: 4) {
                    ForEach(interfaceTabs, id: \.self) { tab in
                        Button {
                            viewModel.messageInterfaceFilter = tab
                        } label: {
                            Text(tab)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 14)
                                .foregroundColor(viewModel.messageInterfaceFilter == tab ? .white : .secondary)
                                .background(viewModel.messageInterfaceFilter == tab ? Color.indigo : Color.clear)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    // Message count
                    StatBadge(label: "Messages", value: "\(filteredMessages.count)")
                }

                // Search + controls
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search ID or Data", text: $searchText)
                            .disableAutocorrection(true)
                            #if !os(macOS)
                            .autocapitalization(.none)
                            #endif
                    }
                    .padding(8)
                    .background(Color.platformSecondaryBackground)
                    .cornerRadius(8)

                    // Live Toggle
                    Button {
                        viewModel.isLive.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(viewModel.isLive ? Color.green : Color.yellow)
                                .frame(width: 6, height: 6)
                            Text(viewModel.isLive ? "Live" : "Paused")
                                .font(.caption)
                        }
                        .foregroundColor(viewModel.isLive ? .green : .yellow)
                    }

                    // Clear
                    Button(role: .destructive) {
                        viewModel.clearMessages()
                    } label: {
                        Image(systemName: "trash")
                            .font(.title3)
                    }
                }
            }
            .padding()
            .background(Color.platformBackground)

            Divider()

            // Message Table
            ScrollViewReader { proxy in
                List {
                    // Header
                    HStack(spacing: 0) {
                        Text("Time").frame(width: 120, alignment: .leading)
                        if viewModel.messageInterfaceFilter == "All" {
                            Text("Interface").frame(width: 80, alignment: .leading)
                        }
                        Text("ID").frame(width: 80, alignment: .leading)
                        Text("DLC").frame(width: 40, alignment: .center)
                        Text("Data").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Type").frame(width: 70, alignment: .center)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .listRowBackground(Color.platformGroupedBackground)

                    ForEach(filteredMessages) { msg in
                        MessageRow(message: msg, showBus: viewModel.messageInterfaceFilter == "All")
                            .id(msg.id)
                    }
                }
                .listStyle(.plain)
                .onChange(of: filteredMessages.count) {
                    if autoScroll, let last = filteredMessages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }
}

// Sub-components
struct MessageRow: View {
    let message: CANLogMessage
    var showBus: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            Text(message.timestampString)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 120, alignment: .leading)

            if showBus {
                Text(message.bus)
                    .font(.caption)
                    .foregroundColor(.blue)
                    .frame(width: 80, alignment: .leading)
            }

            Text(message.canId)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.bold)
                .foregroundColor(message.type == "Error" ? .red : .primary)
                .frame(width: 80, alignment: .leading)

            Text("\(message.dlc)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 40, alignment: .center)

            Text(message.data)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(message.type)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(typeColor.opacity(0.2))
                .foregroundColor(typeColor)
                .cornerRadius(4)
                .frame(width: 70, alignment: .center)
        }
        .padding(.vertical, 4)
        .listRowBackground(message.type == "Error" ? Color.red.opacity(0.1) : Color.clear)
    }

    var typeColor: Color {
        switch message.type {
        case "Standard": return .secondary
        case "Extended": return .green
        case "Error": return .red
        default: return .gray
        }
    }
}
