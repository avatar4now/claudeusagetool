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

/// Settings → Appearance: colors, numbers, reset times, the menu bar, and charts, with a live preview.
/// A pure view with no live state, so it can be rendered and checked in isolation.
struct AppearanceSettingsContent: View {
    @Binding var appearance: Appearance
    @Binding var metric: MenuBarMetric
    let snapshot: UsageSnapshot?

    var body: some View {
        Form {
            Section {
                AppearancePreview(snapshot: snapshot, metric: metric, appearance: appearance)
            } header: {
                Text("Preview")
            } footer: {
                Text(snapshot == nil ? "Sample numbers until your first reading." : "Your current numbers.")
                    .foregroundStyle(.secondary)
            }

            Section("Colors") {
                ThemePicker(selection: $appearance.theme)
                Picker("Colors show", selection: $appearance.colorMeaning) {
                    ForEach(ColorMeaning.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                LevelSettings(appearance: appearance, yellowAt: $appearance.yellowAt, redAt: $appearance.redAt)
            }

            Section("Numbers and times") {
                Picker("Numbers show", selection: $appearance.numbers) {
                    ForEach(NumberStyle.allCases) { style in
                        Text(style == .used ? "How much is used" : "How much is left").tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Reset times", selection: $appearance.resetStyle) {
                    ForEach(ResetStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Example") {
                    Text(UsageFormatting.resetPhrase(until: Date().addingTimeInterval(2 * 3600 + 10 * 60), now: Date(),
                                                     style: appearance.resetStyle) ?? "")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Menu bar") {
                Picker("Shows", selection: $metric) {
                    ForEach(MenuBarMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Icon", selection: $appearance.menuBarIcon) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        Label(style.title, systemImage: style.previewSymbol).tag(style)
                    }
                }
                Picker("Text", selection: $appearance.menuBarText) {
                    ForEach(MenuBarTextStyle.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                Toggle("Shade the area under chart lines", isOn: $appearance.shadeCharts)
                Toggle("Show pace markers", isOn: $appearance.showPaceGuides)
                Toggle("Show forecast lines on the week chart", isOn: $appearance.showForecastLines)
            } header: {
                Text("Charts")
            } footer: {
                Text("Pace markers are the ticks on bars and rings, and the dashed even-pace line, that show where an even spread through the window would be by now.")
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("The widget uses the same colors, numbers, and reset times. Whether desktop widgets stay in color when you're not using the desktop is set in System Settings → Desktop & Dock → Widget style.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Restore Defaults") { appearance = .standard }
                        .disabled(appearance == .standard)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Preview

/// The menu bar item and the panel's rows, drawn with the chosen look.
struct AppearancePreview: View {
    let snapshot: UsageSnapshot?
    let metric: MenuBarMetric
    let appearance: Appearance
    var now = Date()

    /// Numbers to show before the first reading arrives.
    static func sample(now: Date) -> UsageSnapshot {
        UsageSnapshot(fiveHourPercent: 42, fiveHourResetsAt: now.addingTimeInterval(2 * 3600 + 10 * 60),
                      weeklyPercent: 68, weeklyResetsAt: now.addingTimeInterval(2 * 86_400 + 5 * 3600),
                      fableWeeklyPercent: 91, fableWeeklyResetsAt: now.addingTimeInterval(2 * 86_400 + 5 * 3600))
    }

    var body: some View {
        let shown = snapshot ?? Self.sample(now: now)
        let headline = Headline.make(for: shown, metric: metric, now: now, warningAt: Double(appearance.redAt))
        let limits = LimitKind.allCases.filter { shown.percent(for: $0) != nil }
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Menu bar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                MenuBarLabel(headline: headline, isStale: false, problem: nil, appearance: appearance,
                             display: headline.limit.map {
                                 LimitDisplay.make($0, snapshot: shown, now: now, isStale: false, appearance: appearance)
                             },
                             now: now)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.bar))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
            }
            .frame(width: 170, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(limits, id: \.self) { kind in
                    MenuUsageRow(display: LimitDisplay.make(kind, snapshot: shown, now: now, isStale: false,
                                                            appearance: appearance),
                                 dimmed: false)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Themes

/// A swatch for each theme: its chart colors on top and its calm-to-alert colors underneath.
struct ThemePicker: View {
    @Binding var selection: ColorTheme

    var body: some View {
        LabeledContent("Theme") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(ColorTheme.allCases) { theme in
                    ThemeSwatch(theme: theme, isSelected: theme == selection)
                        .onTapGesture { selection = theme }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(theme == selection ? .isSelected : [])
                }
            }
        }
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

// MARK: - Levels

/// Where bars turn yellow and red, with a strip that shows the colors across 0 to 100%.
struct LevelSettings: View {
    let appearance: Appearance
    @Binding var yellowAt: Int
    @Binding var redAt: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper(value: $yellowAt, in: 5...95, step: 5) {
                LabeledContent("Yellow at", value: "\(yellowAt)%")
            }
            Stepper(value: $redAt, in: min(yellowAt + 5, 100)...100, step: 5) {
                LabeledContent("Red at", value: "\(redAt)%")
            }
            LevelStrip(appearance: appearance)
                .frame(height: 30)
            Text(appearance.colorMeaning == .pace
                 ? "With colors following pace, these levels apply when pace isn't known yet. The red level also sets when the menu bar warns about a limit it isn't showing."
                 : "The red level also sets when the menu bar warns about a limit it isn't showing.")
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
