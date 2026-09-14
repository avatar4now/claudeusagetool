import SwiftUI

extension Color {
    /// Green when there's plenty left, shading to red near the limit.
    static func usageColor(for utilization: Int) -> Color {
        switch utilization {
        case ..<30: return Color(red: 0.2, green: 0.8, blue: 0.4)    // green
        case 30..<50: return Color(red: 0.4, green: 0.8, blue: 0.3)  // light green
        case 50..<65: return Color(red: 0.9, green: 0.8, blue: 0.1)  // yellow
        case 65..<80: return Color(red: 1.0, green: 0.6, blue: 0.1)  // orange
        case 80..<90: return Color(red: 1.0, green: 0.3, blue: 0.2)  // red-orange
        default:      return Color(red: 0.9, green: 0.1, blue: 0.1)  // red
        }
    }

    static func progressGradient(for utilization: Int) -> LinearGradient {
        let color = usageColor(for: utilization)
        return LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing)
    }
}

/// A rounded usage bar, used by the widget and the menu bar panel.
struct UsageProgressBar: View {
    let utilization: Int
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.primary.opacity(0.12))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.progressGradient(for: utilization))
                    .frame(width: max(0, geo.size.width * CGFloat(min(utilization, 100)) / 100.0))
            }
        }
        .frame(height: height)
    }
}
