import SwiftUI

// MARK: - Platform Colors

extension Color {
    static let platformBackground = Color(UIColor.systemBackground)
    static let platformSecondaryBackground = Color(UIColor.secondarySystemBackground)
    static let platformGroupedBackground = Color(UIColor.systemGroupedBackground)
}

// MARK: - App Wide Shared Components

struct StatBadge: View {
    let label: String
    let value: String
    var color: Color = .primary
    
    var body: some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.platformSecondaryBackground)
        .cornerRadius(6)
    }
}

enum TrendDirection {
    case up(Double)
    case down(Double)
    case stable(Double)
}

struct MetricCard: View {
    let title: String
    let value: String
    var unit: String = ""
    let icon: String
    let iconColor: Color
    var trend: TrendDirection?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .font(.title3)
            }
            
            HStack(alignment: .lastTextBaseline) {
                Text(value)
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                if !unit.isEmpty {
                    Text(unit)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if let trend = trend {
                    TrendBadge(trend: trend)
                }
            }
        }
        .padding()
        .background(Color.platformBackground)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

struct TrendBadge: View {
    let trend: TrendDirection
    
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: trendIcon)
                .font(.caption2)
            Text(trendText)
                .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(trendColor.opacity(0.1))
        .foregroundColor(trendColor)
        .cornerRadius(4)
    }
    
    var trendIcon: String {
        switch trend {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .stable: return "arrow.right"
        }
    }
    
    var trendText: String {
        switch trend {
        case .up(let val): return String(format: "%.1f%%", val)
        case .down(let val): return String(format: "%.1f%%", val)
        case .stable(let val): return String(format: "%.1f%%", val)
        }
    }
    
    var trendColor: Color {
        switch trend {
        case .up: return .green
        case .down: return .red
        case .stable: return .secondary
        }
    }
}

// Global UI state view constants
struct ConnectionBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundColor(.orange)
            
            VStack(alignment: .leading) {
                Text("No Adapters Connected")
                    .fontWeight(.medium)
                Text("Connect hardware or enable simulated data")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
        .padding(.horizontal)
    }
}
