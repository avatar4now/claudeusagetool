import AppKit
import Combine
import SwiftUI
import WidgetKit
import os

/// Logs outcomes only, never credential values.
private let logger = Logger(subsystem: "dev.huan.ClaudeUsageWidget", category: "setup")

/// The first-run window, connected to the live monitor and login item.
struct SetupAssistant: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var loginItem: LoginItemController
    @StateObject private var model = SetupModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage(SettingsTab.storageKey) private var settingsTab = SettingsTab.account.rawValue

    var body: some View {
        SetupContent(model: model, snapshot: monitor.snapshot, appearance: monitor.appearance,
                     metric: Binding(get: { monitor.menuBarMetric }, set: { monitor.setMenuBarMetric($0) }),
                     opensAtLogin: Binding(get: { loginItem.state == .on || loginItem.state == .needsApproval },
                                           set: { loginItem.setEnabled($0) }),
                     loginAvailable: loginItem.isInstalledCopy,
                     onFindOrganizations: { Task { await model.findOrganizations(monitor: monitor) } },
                     onConnect: { Task { await model.connect(organizationId: model.chosenOrganizationId, monitor: monitor) } },
                     onCustomize: {
                         settingsTab = SettingsTab.appearance.rawValue
                         openWindow(id: AppWindow.settings)
                     },
                     onFinish: {
                         openWindow(id: AppWindow.dashboard)
                         dismissWindow(id: AppWindow.setup)
                     })
            .onAppear {
                model.detectBrowser()
                loginItem.refresh()
                WindowPresence.opened()
            }
            .onDisappear {
                model.forgetKey()
                WindowPresence.closed()
            }
    }
}

/// The setup steps: what the app does, connecting a claude.ai account, and the finishing touches.
/// It shows what the model holds and reports taps through closures, so it can be rendered and checked in isolation.
struct SetupContent: View {
    @ObservedObject var model: SetupModel
    let snapshot: UsageSnapshot?
    let appearance: Appearance
    @Binding var metric: MenuBarMetric
    @Binding var opensAtLogin: Bool
    let loginAvailable: Bool
    var onFindOrganizations: () -> Void = {}
    var onConnect: () -> Void = {}
    var onCustomize: () -> Void = {}
    var onFinish: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            StepDots(current: model.step)
                .padding(.top, 18)
            Group {
                switch model.step {
                case .welcome: welcome
                case .connect: connect
                case .organization: organization
                case .finish: finish
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 640, height: 600)
    }

    // MARK: Step 1: welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tint)
            Text("Keep an eye on your Claude limits")
                .font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "menubar.rectangle", title: "In your menu bar",
                        text: "The limit closest to full, with a warning when another one is nearly used up.")
                Feature(symbol: "rectangle.3.group", title: "On your desktop",
                        text: "A widget in three sizes that stays up to date, even when the app isn't open.")
                Feature(symbol: "chart.xyaxis.line", title: "In a dashboard",
                        text: "A forecast of when each limit runs out, and your usage by day and by hour.")
                Feature(symbol: "lock.shield", title: "Private",
                        text: "Your key stays in your Mac's keychain and is only ever sent to claude.ai.")
            }
            Spacer()
            HStack {
                Spacer()
                Button("Get Started") { model.step = .connect }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Step 2: the session key

    private var connect: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect your Claude account")
                .font(.title.bold())
            Text("The app reads your usage the same way claude.ai's own Usage page does, using the session key your browser keeps after you sign in.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            NumberedStep(number: 1) {
                HStack {
                    Text("Sign in to claude.ai in your browser.")
                    Spacer()
                    Button("Open claude.ai") { NSWorkspace.shared.open(SetupModel.claudeURL) }
                        .controlSize(.small)
                }
            }
            NumberedStep(number: 2) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Copy the cookie named sessionKey.")
                        Spacer()
                        Picker("Browser", selection: $model.browser) {
                            ForEach(SetupModel.Browser.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    Text(model.browser.instructions)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            NumberedStep(number: 3) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SecureField("Paste your session key", text: $model.sessionKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onSubmit(onFindOrganizations)
                        Button("Paste") { model.pasteFromClipboard() }
                    }
                    keyHint
                }
            }

            problemLine
            Spacer()
            HStack {
                Button("Back") { model.step = .welcome }
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button("Continue", action: onFindOrganizations)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.keyLooksRight || model.isWorking)
            }
        }
    }

    @ViewBuilder
    private var keyHint: some View {
        if model.clipboardCleared {
            Label("Pasted, and cleared from your clipboard.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else if model.sessionKey.isEmpty {
            Text("It starts with sk-ant-sid. It's hidden here as you paste it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if model.keyLooksRight {
            Label("That looks like a session key.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("That doesn't look like a session key. It should start with sk-ant-sid.", systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: Step 3: which organization (only when there's a choice)

    private var organization: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which account should it watch?")
                .font(.title.bold())
            Text("Your Claude login belongs to more than one organization. Choose the one whose limits you want to see.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.organizations.isEmpty {
                Text("claude.ai didn't list any organizations for this key. You can enter the organization ID yourself: open claude.ai/api/organizations in your browser and copy the \"uuid\" value.")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Organization", selection: $model.selectedOrganization) {
                    ForEach(model.organizations) { organization in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(organization.name)
                            Text(organization.canChat == false ? "API only · \(organization.id)" : organization.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(organization.id))
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            DisclosureGroup("Enter an organization ID yourself", isExpanded: $model.showsManualEntry) {
                TextField("Organization ID (uuid)", text: $model.manualOrganizationId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .padding(.top, 6)
            }

            problemLine
            Spacer()
            HStack {
                Button("Back") { model.step = .connect }
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button("Connect", action: onConnect)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.chosenOrganizationId.isEmpty || model.isWorking)
            }
        }
    }

    // MARK: Step 4: done

    private var finish: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text("You're connected")
            }
            .font(.title.bold())

            if snapshot != nil {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(LimitKind.allCases.filter { snapshot?.percent(for: $0) != nil }, id: \.self) { kind in
                        MenuUsageRow(display: LimitDisplay.make(kind, snapshot: snapshot, now: Date(), isStale: false,
                                                                appearance: appearance),
                                     dimmed: false)
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            }

            VStack(alignment: .leading, spacing: 12) {
                Feature(symbol: "rectangle.3.group", title: "Add the widget",
                        text: "Right-click your desktop, choose Edit Widgets, search for Claude Usage, and drag a size onto the desktop.")
                HStack(alignment: .firstTextBaseline) {
                    Feature(symbol: "menubar.rectangle", title: "Menu bar",
                            text: "Choose which limit the menu bar shows.")
                    Spacer()
                    Picker("Menu bar shows", selection: $metric) {
                        ForEach(MenuBarMetric.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack(alignment: .firstTextBaseline) {
                    Feature(symbol: "power", title: "Open at login",
                            text: loginAvailable
                                ? "Start the app when you log in, so the menu bar and widget stay current."
                                : "Available once the app is installed with scripts/update-app.sh.")
                    Spacer()
                    Toggle("Open at login", isOn: $opensAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .disabled(!loginAvailable)
                }
            }

            Spacer()
            HStack {
                Button("Customize the Look…", action: onCustomize)
                Spacer()
                Button("Open Dashboard", action: onFinish)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Shared pieces

    @ViewBuilder
    private var problemLine: some View {
        if let problem = model.problem {
            Label(problem, systemImage: model.problemSymbol)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the setup assistant knows while it runs. The key is kept only until it's saved, and never logged.
@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case welcome
        case connect
        case organization
        case finish
    }

    enum Browser: String, CaseIterable, Identifiable {
        case chromium
        case safari
        case firefox

        var id: String { rawValue }

        var title: String {
            switch self {
            case .chromium: return "Chrome, Arc, Edge, or Brave"
            case .safari: return "Safari"
            case .firefox: return "Firefox"
            }
        }

        var instructions: String {
            switch self {
            case .chromium:
                return "On claude.ai, choose View → Developer → Developer Tools. Open the Application tab, then Cookies → https://claude.ai. Click sessionKey and copy its Value."
            case .safari:
                return "First turn on Safari → Settings → Advanced → Show features for web developers. Then on claude.ai choose Develop → Show Web Inspector, open Storage → Cookies, and copy the value of sessionKey."
            case .firefox:
                return "On claude.ai, choose Tools → Browser Tools → Web Developer Tools. Open Storage → Cookies → https://claude.ai, and copy the value of sessionKey."
            }
        }
    }

    static let claudeURL = URL(string: "https://claude.ai")!

    @Published var step: Step = .welcome
    @Published var browser: Browser = .chromium
    @Published var sessionKey = "" {
        didSet { if sessionKey != oldValue { clipboardCleared = false } }
    }
    @Published private(set) var clipboardCleared = false
    @Published private(set) var organizations: [ClaudeOrganization] = []
    @Published var selectedOrganization: String?
    @Published var showsManualEntry = false
    @Published var manualOrganizationId = ""
    @Published private(set) var isWorking = false
    @Published private(set) var problem: String?
    @Published private(set) var problemSymbol = ProblemCause.fallbackSymbol

    var cleanedKey: String { SessionKeyInput.clean(sessionKey) }
    var keyLooksRight: Bool { SessionKeyInput.looksLikeSessionKey(cleanedKey) }

    /// A typed-in ID wins over the list, so a missing or wrong list never blocks setup.
    var chosenOrganizationId: String {
        let typed = manualOrganizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (selectedOrganization ?? "") : typed
    }

    /// Starts on the instructions for the default browser.
    func detectBrowser() {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: Self.claudeURL),
              let bundleID = Bundle(url: app)?.bundleIdentifier?.lowercased() else { return }
        if bundleID.contains("safari") {
            browser = .safari
        } else if bundleID.contains("firefox") {
            browser = .firefox
        } else {
            browser = .chromium
        }
    }

    /// Pastes the clipboard into the key field, then clears the clipboard so the key doesn't linger there.
    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string) else { return }
        sessionKey = SessionKeyInput.clean(text)
        if keyLooksRight {
            pasteboard.clearContents()
            clipboardCleared = true
        }
    }

    /// Asks claude.ai which organizations the key belongs to. With one clear choice it connects straight away.
    func findOrganizations(monitor: UsageMonitor) async {
        guard keyLooksRight, !isWorking else { return }
        isWorking = true
        problem = nil
        let result = await UsageFetcher.live.organizations(sessionKey: cleanedKey)
        isWorking = false
        switch result {
        case .success(let found):
            logger.notice("Setup found \(found.count, privacy: .public) organizations")
            organizations = found
            if let guess = OrganizationParser.bestGuess(found) {
                selectedOrganization = guess.id
                await connect(organizationId: guess.id, monitor: monitor)
            } else {
                selectedOrganization = found.first(where: { $0.canChat == true })?.id ?? found.first?.id
                showsManualEntry = found.isEmpty
                step = .organization
            }
        case .failure(let error):
            logger.error("Setup couldn't list organizations: \(error.message, privacy: .public)")
            show(error)
        }
    }

    /// Saves the key and organization in the keychain, then checks the connection with a real reading.
    func connect(organizationId: String, monitor: UsageMonitor) async {
        guard !isWorking else { return }
        isWorking = true
        problem = nil
        defer { isWorking = false }
        do {
            // Setup only changes the session key and organization; an OAuth token saved earlier stays.
            let existing = try? monitor.store.load()
            _ = try ConfigEditor.save(oauthToken: existing?.oauthToken ?? "", sessionKey: cleanedKey,
                                      organizationId: organizationId, store: monitor.store)
            monitor.credentialsChanged()
            WidgetCenter.shared.reloadAllTimelines()
        } catch let error as ConfigValidationError {
            problem = error.message
            problemSymbol = ProblemCause.setup.symbol
            return
        } catch let error as UsageError {
            show(error)
            return
        } catch {
            problem = "Couldn't save to your keychain."
            problemSymbol = ProblemCause.keychain.symbol
            return
        }

        switch await monitor.refresh(trigger: .connectionTest) {
        case .success:
            logger.notice("Setup connected")
            forgetKey()
            step = .finish
        case .failure(let error):
            logger.error("Setup's connection check failed: \(error.message, privacy: .public)")
            show(error)
        }
    }

    /// Drops the typed key from memory once it's saved, or when the window closes.
    func forgetKey() {
        sessionKey = ""
    }

    private func show(_ error: UsageError) {
        let cause = ProblemCause(error)
        problem = "\(cause.title). \(error.message)"
        problemSymbol = cause.symbol
    }
}

extension SetupModel {
    /// A model at one step with made-up content, for previews and offscreen checks. It never holds a real key.
    static func preview(step: Step, organizations: [ClaudeOrganization] = [], problem: String? = nil,
                        sampleKey: Bool = false) -> SetupModel {
        let model = SetupModel()
        model.step = step
        model.organizations = organizations
        model.selectedOrganization = organizations.first?.id
        model.problem = problem
        if sampleKey { model.sessionKey = "sk-ant-sid01-" + String(repeating: "x", count: 40) }
        return model
    }
}

// MARK: - Small pieces

/// Four dots at the top of the setup window; the current step is filled.
private struct StepDots: View {
    let current: SetupModel.Step

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SetupModel.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: step == current ? 22 : 8, height: 8)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(SetupModel.Step.allCases.count)")
    }
}

/// A symbol with a short title and a sentence, used to explain what the app does.
private struct Feature: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A numbered instruction in the connect step.
private struct NumberedStep<Content: View>: View {
    let number: Int
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.accentColor))
            content
        }
    }
}
