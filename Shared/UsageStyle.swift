import SwiftUI

extension RGB {
    var color: Color { Color(red: red, green: green, blue: blue) }
}

extension LimitDisplay {
    /// The limit's color in the chosen theme, or gray when its percentage is unknown.
    var color: Color { tint?.color ?? Color.secondary }
}

/// A rounded usage bar, used by the widget, the menu bar panel, and the dashboard.
/// The tick shows where an even spread would be by now. An unknown value draws an empty, dimmed track.
struct UsageProgressBar: View {
    let fraction: Double
    let tint: Color
    let height: CGFloat
    var paceFraction: Double? = nil
    var isUnknown: Bool = false

    init(fraction: Double, tint: Color, height: CGFloat, paceFraction: Double? = nil, isUnknown: Bool = false) {
        self.fraction = fraction
        self.tint = tint
        self.height = height
        self.paceFraction = paceFraction
        self.isUnknown = isUnknown
    }

    /// A bar for one limit, drawn the way its appearance asks: used or left, theme color, pace tick or none.
    init(display: LimitDisplay, height: CGFloat) {
        self.init(fraction: display.barFraction, tint: display.color, height: height,
                  paceFraction: display.paceMarkFraction, isUnknown: display.percent == nil)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.primary.opacity(isUnknown ? 0.06 : 0.12))
                if !isUnknown {
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(LinearGradient(colors: [tint.opacity(0.72), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(0, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                }
                if let paceFraction {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 2, height: height + 4)
                        .offset(x: max(0, min(geo.size.width - 2, geo.size.width * CGFloat(paceFraction) - 1)))
                }
            }
            .frame(height: geo.size.height)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// A ring that fills like a usage bar, with a tick where an even pace would be. Callers put their own text inside.
struct UsageRingTrack: View {
    let display: LimitDisplay
    var lineWidth: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2 - lineWidth / 2
            ZStack {
                Circle()
                    .inset(by: lineWidth / 2)
                    .stroke(Color.primary.opacity(display.percent == nil ? 0.06 : 0.12), lineWidth: lineWidth)
                if display.percent != nil {
                    Circle()
                        .inset(by: lineWidth / 2)
                        .trim(from: 0, to: CGFloat(min(max(display.barFraction, 0), 1)))
                        .stroke(display.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if let pace = display.paceMarkFraction {
                    Capsule()
                        .fill(Color.primary.opacity(0.75))
                        .frame(width: 2, height: lineWidth + 4)
                        .offset(y: -radius)
                        .rotationEffect(.degrees(360 * pace))
                }
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .accessibilityHidden(true)
    }
}
