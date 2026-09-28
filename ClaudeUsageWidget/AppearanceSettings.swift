import SwiftUI

/// Settings → Appearance, connected to the live monitor.
struct AppearanceSettings: View {
    @ObservedObject var monitor: UsageMonitor

    var body: some View {
        AppearanceSettingsContent(appearance: Binding(get: { monitor.appearance }, set: { monitor.setAppearance($0) }),
                                  metric: Binding(get: { monitor.menuBarMetric }, set: { monitor.setMenuBarMetric($0) }),
                                  snapshot: monitor.snapshot)
    }
}

/// Settings → Appearance. Three everyday choices up front (colors, menu bar, used or left), and the rest behind
/// More Options. A pure view with no live state, so it can be rendered and checked in isolation.
struct AppearanceSettingsContent: View {
    @Binding var appearance: Appearance
    @Binding var metric: MenuBarMetric
    let snapshot: UsageSnapshot?
    var now = Date()
    @AppStorage("appearanceShowsMoreOptions") private var showsMore = false

    /// Real numbers when there are some, sample ones before the first reading.
    private var shown: UsageSnapshot { snapshot ?? AppearancePreview.sample(now: now) }

    var body: some View {
        Form {
            Section {
                AppearancePreview(snapshot: shown, appearance: appearance, metric: metric, now: now)
            } footer: {
                Text(snapshot == nil ? "Sample numbers until your first reading." : "Your current numbers, drawn with these settings.")
                    .foregroundStyle(.secondary)
            }

            Section("Colors") {
                ThemePicker(selection: $appearance.theme)
            }

            Section("Menu bar") {
                MenuBarStylePicker(appearance: $appearance, snapshot: shown, metric: metric, now: now)
                Picker("Limit to show", selection: $metric) {
                    ForEach(MenuBarMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }

            Section {
                Picker("Numbers", selection: $appearance.numbers) {
                    Text("How much is used").tag(NumberStyle.used)
                    Text("How much is left").tag(NumberStyle.left)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("Numbers")
            } footer: {
                Text(appearance.numbers == .used
                     ? "For example, \"94% used\"."
                     : "For example, \"6% left\". Bars and rings show what's left, like a battery.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showsMore.toggle() }
                } label: {
                    HStack {
                        Text(showsMore ? "Fewer Options" : "More Options")
                        Spacer()
                        if !showsMore {
                            Text("Warnings, pace colors, reset times, charts")
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(showsMore ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if showsMore {
                moreOptions
            }

            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("The widget uses the same colors and numbers.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { appearance = .standard }
                        .disabled(appearance == .standard)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: More options

    @ViewBuilder
    private var moreOptions: some View {
        Section("Warnings") {
            WarningPicker(appearance: $appearance)
        }

        Section {
            Picker("Colors follow", selection: $appearance.colorMeaning) {
                Text("How full it is").tag(ColorMeaning.fullness)
                Text("Your pace").tag(ColorMeaning.pace)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text("What colors mean")
        } footer: {
            Text(appearance.colorMeaning == .fullness
                 ? "Each limit turns yellow, then red, as it fills up."
                 : "A limit stays green while you use it evenly through its window, and turns red only if you're on track to run out early.")
                .foregroundStyle(.secondary)
        }

        Section {
            Picker("Reset times", selection: $appearance.resetStyle) {
                ForEach(ResetStyle.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text("Reset times")
        } footer: {
            Text("For example, \"\(UsageFormatting.resetPhrase(until: now.addingTimeInterval(2 * 3600 + 10 * 60), now: now, style: appearance.resetStyle) ?? "")\".")
                .foregroundStyle(.secondary)
        }

        Section("Charts") {
            Toggle("Shade under chart lines", isOn: $appearance.shadeCharts)
            Toggle("Show where an even pace would be", isOn: $appearance.showPaceGuides)
            Toggle("Show where each weekly limit is heading", isOn: $appearance.showForecastLines)
        }
    }
}

// MARK: - Preview

/// A ring for the limit the menu bar shows, and the panel's bars, drawn with the chosen colors and numbers.
struct AppearancePreview: View {
    let snapshot: UsageSnapshot
    let appearance: Appearance
    var metric: MenuBarMetric = .auto
    var now = Date()

    /// Numbers to show before the first reading arrives.
    static func sample(now: Date) -> UsageSnapshot {
        UsageSnapshot(fiveHourPercent: 42, fiveHourResetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60),
                      weeklyPercent: 68, weeklyResetsAt: now.addingTimeInterval(2 * 86_400 + 5 * 3600),
                      fableWeeklyPercent: 91, fableWeeklyResetsAt: now.addingTimeInterval(2 * 86_400 + 5 * 3600))
    }

    var body: some View {
        let limits = LimitKind.allCases.filter { snapshot.percent(for: $0) != nil }
        let shownLimit = Headline.make(for: snapshot, metric: metric, now: now, warningAt: Double(appearance.redAt)).limit
        let featured = LimitDisplay.make(shownLimit ?? limits.first ?? .weekly, snapshot: snapshot, now: now, isStale: false,
                                         appearance: appearance)
        HStack(alignment: .center, spacing: 20) {
            ZStack {
                UsageRingTrack(display: featured, lineWidth: 8)
                VStack(spacing: -1) {
                    Text(featured.numberText)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(featured.color)
                    Text(featured.percent == nil ? " " : "% \(appearance.numberCaption)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(limits, id: \.self) { kind in
                    MenuUsageRow(display: LimitDisplay.make(kind, snapshot: snapshot, now: now, isStale: false,
                                                            appearance: appearance),
                                 dimmed: false)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Menu bar styles

/// The six ready-made menu bar looks, each drawn the way it will appear, with your numbers.
struct MenuBarStylePicker: View {
    @Binding var appearance: Appearance
    let snapshot: UsageSnapshot
    let metric: MenuBarMetric
    var now = Date()

    var body: some View {
        let current = MenuBarStyle(appearance: appearance)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(MenuBarStyle.allCases) { style in
                Button {
                    style.apply(to: &appearance)
                } label: {
                    MenuBarStyleTile(style: style, appearance: appearance, snapshot: snapshot, metric: metric, now: now,
                                     isSelected: style == current)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(style == current ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

struct MenuBarStyleTile: View {
    let style: MenuBarStyle
    let appearance: Appearance
    let snapshot: UsageSnapshot
    let metric: MenuBarMetric
    let now: Date
    let isSelected: Bool

    /// The current settings with this style's picture and text.
    private var look: Appearance {
        var look = appearance
        style.apply(to: &look)
        return look
    }

    var body: some View {
        let look = self.look
        let headline = Headline.make(for: snapshot, metric: metric, now: now, warningAt: Double(look.redAt))
        VStack(spacing: 8) {
            MenuBarLabel(headline: headline, isStale: false, problem: nil, appearance: look,
                         display: headline.limit.map {
                             LimitDisplay.make($0, snapshot: snapshot, now: now, isStale: false, appearance: look)
                         },
                         now: now)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(.bar))
            Text(style.title)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(isSelected ? 0.08 : 0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(style.title) menu bar style")
    }
}

// MARK: - Themes

/// A swatch for each theme: its chart colors on top and its calm-to-alert colors underneath.
struct ThemePicker: View {
    @Binding var selection: ColorTheme

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(ColorTheme.allCases) { theme in
                Button {
                    selection = theme
                } label: {
                    ThemeSwatch(theme: theme, isSelected: theme == selection)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(theme == selection ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }
}

struct ThemeSwatch: View {
    let theme: ColorTheme
    let isSelected: Bool

    var body: some View {
        let palette = theme.palette
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ForEach([palette.allModels, palette.fable, palette.fiveHour], id: \.description) { color in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.color)
                        .frame(height: 16)
                }
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [palette.calm.color, palette.caution.color, palette.alert.color],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 6)
            Text(theme.title)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(isSelected ? 0.08 : 0.03)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.title) theme")
    }
}

// MARK: - Warnings

/// When bars turn yellow and red: Early, Normal, or Late, with exact levels available under Custom.
struct WarningPicker: View {
    @Binding var appearance: Appearance
    @State private var editsByHand = false

    private enum Choice: Hashable {
        case level(WarningLevel)
        case custom
    }

    private var choice: Choice {
        if editsByHand { return .custom }
        return WarningLevel(appearance: appearance).map(Choice.level) ?? .custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Warn me", selection: Binding(get: { choice }, set: { newValue in
                switch newValue {
                case .level(let level):
                    editsByHand = false
                    level.apply(to: &appearance)
                case .custom:
                    editsByHand = true
                }
            })) {
                ForEach(WarningLevel.allCases) { Text($0.title).tag(Choice.level($0)) }
                Text("Custom").tag(Choice.custom)
            }
            .pickerStyle(.segmented)

            if choice == .custom {
                Stepper(value: $appearance.yellowAt, in: 5...95, step: 5) {
                    LabeledContent("Yellow at", value: "\(appearance.yellowAt)%")
                }
                Stepper(value: $appearance.redAt, in: min(appearance.yellowAt + 5, 100)...100, step: 5) {
                    LabeledContent("Red at", value: "\(appearance.redAt)%")
                }
            }

            LevelStrip(appearance: appearance)
                .frame(height: 30)
            Text("Bars turn yellow at \(appearance.yellowAt)% and red at \(appearance.redAt)%. The menu bar also flags a limit it isn't showing once that limit turns red.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The level colors from 0% to 100%, with marks at the yellow and red levels.
struct LevelStrip: View {
    let appearance: Appearance

    var body: some View {
        let stops = stride(from: 0.0, through: 100, by: 5).map {
            Gradient.Stop(color: appearance.levelColor(for: $0).color, location: $0 / 100)
        }
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 10)
                ForEach([appearance.yellowAt, appearance.redAt], id: \.self) { level in
                    let x = geometry.size.width * CGFloat(level) / 100
                    VStack(spacing: 1) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.7))
                            .frame(width: 1.5, height: 14)
                        Text("\(level)%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .position(x: min(max(x, 12), geometry.size.width - 12), y: 15)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colors turn yellow at \(appearance.yellowAt) percent and red at \(appearance.redAt) percent")
    }
}
