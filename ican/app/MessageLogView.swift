import SwiftUI

struct MessageLogView: View {
    @ObservedObject var viewModel: CANDashboardViewModel
    @State private var searchText = ""
    @State private var showFilters = false
    @State private var busFilter: BusFilter = .all
    @State private var typeFilter: TypeFilter = .all
    @State private var autoScroll = true
    
    enum BusFilter: String, CaseIterable {
        case all = "All Buses"
        case bus0 = "Adapter 1"
        case bus1 = "Adapter 2"
    }
    
    enum TypeFilter: String, CaseIterable {
        case all = "All Types"
        case standard = "Standard"
        case extended = "Extended"
        case error = "Error"
    }
    
    var filteredMessages: [CANLogMessage] {
        viewModel.messages.filter { msg in
            let matchesSearch = searchText.isEmpty ||
                                msg.canId.localizedCaseInsensitiveContains(searchText) ||
                                msg.data.localizedCaseInsensitiveContains(searchText)
            
            let matchesBus: Bool
            switch busFilter {
            case .all: matchesBus = true
            case .bus0: matchesBus = msg.bus == "Adapter 1"
            case .bus1: matchesBus = msg.bus == "Adapter 2"
            }
            
            let matchesType = typeFilter == .all || msg.type.lowercased() == typeFilter.rawValue.lowercased()
            
            return matchesSearch && matchesBus && matchesType
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Controls
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    // Search
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
                    
                    // Filter Toggle
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showFilters.toggle() }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle" + (showFilters ? ".fill" : ""))
                            .font(.title3)
                    }
                    
                    // Live Toggle
                    Button {
                        viewModel.isLive.toggle()
                    } label: {
                        Image(systemName: viewModel.isLive ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title3)
                            .foregroundColor(viewModel.isLive ? .orange : .green)
                    }
                    
                    // Export (placeholder logic for now)
                    Button {
                        // viewModel.exportMessages()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title3)
                    }
                    
                    // Clear
                    Button(role: .destructive) {
                        viewModel.clearMessages()
                    } label: {
                        Image(systemName: "trash")
                            .font(.title3)
                    }
                }
                
                // Filter Panel
                if showFilters {
                    HStack(spacing: 16) {
                        Picker("Bus", selection: $busFilter) {
                            ForEach(BusFilter.allCases, id: \.self) { filter in Text(filter.rawValue).tag(filter) }
                        }
                        .pickerStyle(.segmented)
                        
                        Picker("Type", selection: $typeFilter) {
                            ForEach(TypeFilter.allCases, id: \.self) { filter in Text(filter.rawValue).tag(filter) }
                        }
                        .pickerStyle(.segmented)
                        
                        Spacer()
                        
                        Toggle("Auto-scroll", isOn: $autoScroll)
                            .fixedSize()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                
                // Stats Row
                HStack {
                    StatBadge(label: "Total", value: "\(viewModel.messages.count)")
                    StatBadge(label: "Filtered", value: "\(filteredMessages.count)")
                    StatBadge(label: "Errors", value: "\(viewModel.errorCount)", color: viewModel.errorCount > 0 ? .red : .primary)
                    
                    Spacer()
                    
                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.isLive ? Color.green : Color.yellow)
                            .frame(width: 6, height: 6)
                        Text(viewModel.isLive ? "Live" : "Paused")
                            .font(.caption)
                            .foregroundColor(viewModel.isLive ? .green : .yellow)
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
                        Text("Time").frame(width: 100, alignment: .leading)
                        Text("Bus").frame(width: 80, alignment: .leading)
                        Text("ID").frame(width: 80, alignment: .leading)
                        Text("DLC").frame(width: 40, alignment: .center)
                        Text("Data").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Type").frame(width: 70, alignment: .center)
                        Text("Dir").frame(width: 50, alignment: .center)
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .listRowBackground(Color.platformGroupedBackground)
                    
                    ForEach(filteredMessages) { msg in
                        MessageRow(message: msg)
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
    
    var body: some View {
        HStack(spacing: 0) {
            Text(message.timestampString)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 100, alignment: .leading)
            
            Text(message.bus)
                .font(.caption)
                .foregroundColor(busColor)
                .frame(width: 80, alignment: .leading)
            
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
            
            Text(message.direction)
                .font(.caption)
                .foregroundColor(message.direction == "RX" ? .blue : .green)
                .frame(width: 50, alignment: .center)
        }
        .padding(.vertical, 4)
        .listRowBackground(message.type == "Error" ? Color.red.opacity(0.1) : Color.clear)
    }
    
    var busColor: Color {
        switch message.bus {
        case "Adapter 1": return .blue
        case "Adapter 2": return .purple
        default: return .gray
        }
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
