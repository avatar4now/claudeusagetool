import Foundation

// MARK: - Colors without SwiftUI

/// A color as red, green, and blue from 0 to 1, so palettes can be blended and tested without drawing anything.
struct RGB: Codable, Equatable, Sendable, CustomStringConvertible {
    var red: Double
    var green: Double
    var blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// A color part of the way to another one: 0 is this color, 1 is the other.
    func mixed(with other: RGB, by fraction: Double) -> RGB {
        let amount = min(max(fraction, 0), 1)
        return RGB(red + (other.red - red) * amount,
                   green + (other.green - green) * amount,
                   blue + (other.blue - blue) * amount)
    }

    /// How far apart two colors are. Used by tests to keep a palette's colors distinguishable.
    func distance(to other: RGB) -> Double {
        let r = red - other.red, g = green - other.green, b = blue - other.blue
        return (r * r + g * g + b * b).squareRoot()
    }

    var description: String { String(format: "RGB(%.2f, %.2f, %.2f)", red, green, blue) }
}

/// The colors one theme uses.
struct Palette: Equatable, Sendable {
    /// Plenty left.
    let calm: RGB
    /// Getting full.
    let caution: RGB
    /// Nearly or completely used.
    let alert: RGB
    /// Chart lines and bars for each limit.
    let allModels: RGB
    let fable: RGB
    let fiveHour: RGB

    func series(for kind: LimitKind) -> RGB {
        switch kind {
        case .fiveHour: return fiveHour
        case .weekly: return allModels
        case .fableWeekly: return fable
        }
    }
}

/// The color themes to choose from. Every chart color is mid-toned so it reads on light and dark backgrounds.
enum ColorTheme: String, CaseIterable, Codable, Sendable, Identifiable {
    case classic
    case clay
    case ocean
    case dusk
    case graphite
    case colorBlindSafe

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .clay: return "Clay"
        case .ocean: return "Ocean"
        case .dusk: return "Dusk"
        case .graphite: return "Graphite"
        case .colorBlindSafe: return "Color-blind safe"
        }
    }

    var palette: Palette {
        switch self {
        case .classic:
            return Palette(calm: RGB(0.20, 0.78, 0.40), caution: RGB(0.95, 0.75, 0.10), alert: RGB(0.90, 0.15, 0.12),
                           allModels: RGB(0.36, 0.56, 0.96), fable: RGB(0.96, 0.55, 0.24), fiveHour: RGB(0.30, 0.75, 0.62))
        case .clay:
            return Palette(calm: RGB(0.47, 0.66, 0.45), caution: RGB(0.90, 0.62, 0.22), alert: RGB(0.78, 0.27, 0.20),
                           allModels: RGB(0.85, 0.47, 0.34), fable: RGB(0.56, 0.36, 0.62), fiveHour: RGB(0.50, 0.62, 0.30))
        case .ocean:
            return Palette(calm: RGB(0.16, 0.68, 0.78), caution: RGB(0.98, 0.75, 0.25), alert: RGB(0.94, 0.36, 0.38),
                           allModels: RGB(0.22, 0.46, 0.88), fable: RGB(0.95, 0.46, 0.42), fiveHour: RGB(0.18, 0.72, 0.72))
        case .dusk:
            return Palette(calm: RGB(0.45, 0.56, 0.95), caution: RGB(0.86, 0.50, 0.86), alert: RGB(0.93, 0.27, 0.47),
                           allModels: RGB(0.56, 0.44, 0.94), fable: RGB(0.93, 0.42, 0.64), fiveHour: RGB(0.36, 0.70, 0.93))
        case .graphite:
            return Palette(calm: RGB(0.62, 0.64, 0.68), caution: RGB(0.42, 0.45, 0.52), alert: RGB(0.88, 0.25, 0.22),
                           allModels: RGB(0.30, 0.34, 0.42), fable: RGB(0.76, 0.77, 0.80), fiveHour: RGB(0.55, 0.57, 0.62))
        case .colorBlindSafe:
            // The Okabe–Ito colors, chosen to stay distinct with the common kinds of color blindness.
            return Palette(calm: RGB(0.00, 0.45, 0.70), caution: RGB(0.90, 0.62, 0.00), alert: RGB(0.84, 0.37, 0.00),
                           allModels: RGB(0.00, 0.45, 0.70), fable: RGB(0.90, 0.62, 0.00), fiveHour: RGB(0.00, 0.62, 0.45))
        }
    }
}

// MARK: - Choices

/// What the colors of bars and percentages are based on.
enum ColorMeaning: String, CaseIterable, Codable, Sendable, Identifiable {
    /// How full the limit is.
    case fullness
    /// Whether usage is ahead of an even pace through the window.
    case pace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fullness: return "How full it is"
        case .pace: return "Whether you're on pace"
        }
    }
}

/// Whether numbers show how much is used or how much is left.
enum NumberStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case used
    case left

    var id: String { rawValue }

    var title: String {
        switch self {
        case .used: return "Used"
        case .left: return "Left"
        }
    }
}

/// How reset times are written.
enum ResetStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// "Resets in 2h 10m"
    case countdown
    /// "Resets at 6:10 PM"
    case clockTime
    /// "Resets at 6:10 PM, in 2h 10m"
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .countdown: return "Countdown"
        case .clockTime: return "Clock time"
        case .both: return "Both"
        }
    }
}

/// The picture in the menu bar.
enum MenuBarIconStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// A gauge whose needle follows usage, and which changes into a warning, clock, or reset symbol when something
    /// needs attention.
    case status
    /// The same gauge. Kept so settings saved by earlier versions still load.
    case gauge
    /// A small ring that fills and changes color.
    case ring
    /// A battery showing what's left.
    case battery
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: return "Gauge"
        case .gauge: return "Gauge"
        case .ring: return "Color ring"
        case .battery: return "Battery"
        case .none: return "None"
        }
    }

    /// A symbol that stands for the style in Settings.
    var previewSymbol: String {
        switch self {
        case .status: return "gauge.with.dots.needle.33percent"
        case .gauge: return "gauge.with.dots.needle.67percent"
        case .ring: return "circle.dashed.inset.filled"
        case .battery: return "battery.75percent"
        case .none: return "textformat"
        }
    }
}

/// The words next to the menu bar picture.
enum MenuBarTextStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// "5h 30%"
    case labelAndPercent
    /// "30%"
    case percentOnly
    /// "5h 30% · 2h 10m"
    case percentAndReset
    /// Nothing, unless a hidden limit needs a warning.
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .labelAndPercent: return "Limit and percent"
        case .percentOnly: return "Percent only"
        case .percentAndReset: return "Percent and reset time"
        case .none: return "No text"
        }
    }
}

// MARK: - Appearance

/// How the app, the menu bar, and the widget look. The app saves it and hands it to the widget with each reading.
struct Appearance: Codable, Equatable, Sendable {
    var theme: ColorTheme = .classic
    var colorMeaning: ColorMeaning = .fullness
    /// Bars have fully turned the theme's caution color here...
    var yellowAt: Int = 50
    /// ...and its alert color here. Hidden limits at or above this are flagged in the menu bar.
    var redAt: Int = 90
    var numbers: NumberStyle = .used
    var resetStyle: ResetStyle = .countdown
    var menuBarIcon: MenuBarIconStyle = .status
    var menuBarText: MenuBarTextStyle = .labelAndPercent
    /// Fill the area under chart lines.
    var shadeCharts = true
    /// Show where an even pace would be: ticks on bars and the dashed line on the week chart.
    var showPaceGuides = true
    /// Show dashed forecast lines on the week chart.
    var showForecastLines = true

    static let standard = Appearance()

    /// How far ahead of pace counts as alert rather than caution when colors follow pace.
    static let paceAlertPoints = 15

    var palette: Palette { theme.palette }

    /// Keeps the levels in order and in range, and never leaves the menu bar item empty.
    func sanitized() -> Appearance {
        var copy = self
        copy.yellowAt = min(max(yellowAt, 5), 95)
        copy.redAt = min(max(redAt, copy.yellowAt + 5), 100)
        if copy.menuBarIcon == .none && copy.menuBarText == .none {
            copy.menuBarIcon = .status
        }
        return copy
    }

    // MARK: Colors

    /// Calm at 0%, blending to caution at the yellow level and to alert at the red level. The first stretch eases in,
    /// so a limit well below the yellow level still looks calm.
    func levelColor(for percent: Double) -> RGB {
        let yellow = Double(yellowAt)
        let red = Double(redAt)
        if percent <= 0 { return palette.calm }
        if percent < yellow {
            let fraction = percent / yellow
            return palette.calm.mixed(with: palette.caution, by: fraction * fraction)
        }
        if percent < red {
            return palette.caution.mixed(with: palette.alert, by: (percent - yellow) / (red - yellow))
        }
        return palette.alert
    }

    /// The color for a limit, or nil when its percentage is unknown. When colors follow pace and pace is known,
    /// using it evenly or less is calm, a little ahead is caution, and far ahead is alert.
    func color(percent: Double?, pace: PaceReading?) -> RGB? {
        guard let percent else { return nil }
        if colorMeaning == .pace, let pace, percent < 100 {
            switch pace.status {
            case .onPace, .under:
                return palette.calm
            case .ahead(let points):
                return points >= Self.paceAlertPoints ? palette.alert : palette.caution
            }
        }
        return levelColor(for: percent)
    }

    // MARK: Numbers

    /// The number to show for a whole percentage used: itself, or what's left.
    func shownPercent(_ used: Int) -> Int {
        numbers == .used ? used : max(0, 100 - used)
    }

    /// "94%" or "6% left".
    func percentText(_ used: Int?) -> String {
        guard let used else { return "—" }
        return numbers == .used ? "\(used)%" : "\(shownPercent(used))% left"
    }

    /// The bare number for a big display with a caption, such as "94" or "6".
    func numberText(_ used: Int?) -> String {
        used.map { "\(shownPercent($0))" } ?? "—"
    }

    /// The caption under a big number.
    var numberCaption: String { numbers == .used ? "used" : "left" }

    /// How much of a bar or ring to fill: the part used, or the part left.
    func barFraction(_ used: Int) -> Double {
        Double(min(max(shownPercent(used), 0), 100)) / 100
    }

    /// Where the even-pace tick goes on a bar: how much of the window has passed, or how much should be left by now.
    func paceMarkFraction(_ elapsed: Double) -> Double {
        numbers == .used ? elapsed : 1 - elapsed
    }
}

extension Appearance {
    // Declared in an extension so the memberwise initializer stays available. Each setting falls back to its default
    // on its own, so one unknown value (for example a theme added in a newer version) never resets the others.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Appearance()
        func value<T: Decodable>(_ key: CodingKeys, _ defaultValue: T) -> T {
            ((try? container.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? defaultValue
        }
        self.init()
        theme = value(.theme, fallback.theme)
        colorMeaning = value(.colorMeaning, fallback.colorMeaning)
        yellowAt = value(.yellowAt, fallback.yellowAt)
        redAt = value(.redAt, fallback.redAt)
        numbers = value(.numbers, fallback.numbers)
        resetStyle = value(.resetStyle, fallback.resetStyle)
        menuBarIcon = value(.menuBarIcon, fallback.menuBarIcon)
        menuBarText = value(.menuBarText, fallback.menuBarText)
        shadeCharts = value(.shadeCharts, fallback.shadeCharts)
        showPaceGuides = value(.showPaceGuides, fallback.showPaceGuides)
        showForecastLines = value(.showForecastLines, fallback.showForecastLines)
        self = sanitized()
    }
}

// MARK: - Simple choices

/// Three ready-made warning settings, so nobody has to pick two percentages by hand.
enum WarningLevel: String, CaseIterable, Identifiable, Sendable {
    case early
    case normal
    case late

    var id: String { rawValue }

    var title: String {
        switch self {
        case .early: return "Early"
        case .normal: return "Normal"
        case .late: return "Late"
        }
    }

    var yellowAt: Int {
        switch self {
        case .early: return 40
        case .normal: return 50
        case .late: return 65
        }
    }

    var redAt: Int {
        switch self {
        case .early: return 75
        case .normal: return 90
        case .late: return 95
        }
    }

    /// The setting these levels match, or nil when they were set by hand.
    init?(appearance: Appearance) {
        guard let match = Self.allCases.first(where: { $0.yellowAt == appearance.yellowAt && $0.redAt == appearance.redAt })
        else { return nil }
        self = match
    }

    func apply(to appearance: inout Appearance) {
        appearance.yellowAt = yellowAt
        appearance.redAt = redAt
    }
}

/// Ready-made menu bar looks, each pairing a picture with an amount of text.
enum MenuBarStyle: String, CaseIterable, Identifiable, Sendable {
    case gauge
    case ring
    case battery
    case withReset
    case numberOnly
    case ringOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gauge: return "Gauge"
        case .ring: return "Color ring"
        case .battery: return "Battery"
        case .withReset: return "With reset time"
        case .numberOnly: return "Just the number"
        case .ringOnly: return "Ring only"
        }
    }

    var icon: MenuBarIconStyle {
        switch self {
        case .gauge, .withReset: return .status
        case .ring, .ringOnly: return .ring
        case .battery: return .battery
        case .numberOnly: return .none
        }
    }

    var text: MenuBarTextStyle {
        switch self {
        case .gauge, .ring, .battery: return .labelAndPercent
        case .withReset: return .percentAndReset
        case .numberOnly: return .percentOnly
        case .ringOnly: return .none
        }
    }

    /// The style these settings match, or nil for a combination no style uses. Both gauge settings count as the gauge.
    init?(appearance: Appearance) {
        let icon = appearance.menuBarIcon == .gauge ? MenuBarIconStyle.status : appearance.menuBarIcon
        guard let match = Self.allCases.first(where: { $0.icon == icon && $0.text == appearance.menuBarText }) else { return nil }
        self = match
    }

    func apply(to appearance: inout Appearance) {
        appearance.menuBarIcon = icon
        appearance.menuBarText = text
    }
}

// MARK: - Menu bar symbols

enum MenuBarSymbols {
    /// A gauge whose needle points roughly at the percentage used.
    static func gauge(percentUsed: Double) -> String {
        switch percentUsed {
        case ..<17: return "gauge.with.dots.needle.0percent"
        case ..<42: return "gauge.with.dots.needle.33percent"
        case ..<59: return "gauge.with.dots.needle.50percent"
        case ..<84: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }

    /// A battery showing roughly what's left.
    static func battery(percentUsed: Double) -> String {
        let left = 100 - percentUsed
        switch left {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }
}
