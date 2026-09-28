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
                     onFindOrganizations: { model.lookUp(monitor: monitor) },
                     onConnect: { model.connectChosen(monitor: monitor) },
                     onSaveAnyway: { model.saveAnyway(monitor: monitor) },
                     onCustomize: {
                         settingsTab = SettingsTab.appearance.rawValue
                         openWindow(id: AppWindow.settings)
                     },
                     onFinish: {
                         openWindow(id: AppWindow.dashboard)
                         dismissWindow(id: AppWindow.setup)
                     })
            .enablesDashboardShortcut()
            .onAppear {
                model.detectBrowser()
                loginItem.refresh()
                WindowPresence.opened()
            }
            .onDisappear {
                model.close()
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
    var onSaveAnyway: () -> Void = {}
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
                            .disabled(model.isWorking)
                        Button("Paste") { model.pasteFromClipboard() }
                            .disabled(model.isWorking)
                    }
                    keyHint
                }
            }

            problemLine
            Spacer()
            HStack {
                Button("Back") { model.step = .welcome }
                    .disabled(model.isWorking)
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
            Text(model.organizations.count > 1
                 ? "Your Claude login belongs to more than one organization. Choose the one whose limits you want to see."
                 : "Choose the organization whose limits you want to see, or enter its ID.")
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
                    .disabled(model.isWorking)
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                if model.canSaveAnyway {
                    Button("Save Anyway", action: onSaveAnyway)
                        .help("Save this account now and let the app check it on its next refresh")
                        .disabled(model.isWorking)
                }
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

            if model.savedWithoutCheck || model.removedToken || model.clipboardCleared {
                VStack(alignment: .leading, spacing: 4) {
                    if model.savedWithoutCheck {
                        Label("Saved. The app checks the connection on its next refresh.", systemImage: "clock")
                    }
                    if model.removedToken {
                        Label("Your saved OAuth token was removed, so the app watches this account.", systemImage: "key")
                    }
                    if model.clipboardCleared {
                        Label("Your key was cleared from the clipboard.", systemImage: "doc.on.clipboard")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
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
        didSet {
            guard sessionKey != oldValue else { return }
            clipboardCleared = false
            paste.noteChange(from: oldValue, to: sessionKey)
        }
    }
    @Published private(set) var clipboardCleared = false
    @Published private(set) var organizations: [ClaudeOrganization] = []
    @Published var selectedOrganization: String?
    @Published var showsManualEntry = false
    @Published var manualOrganizationId = ""
    @Published private(set) var isWorking = false
    @Published private(set) var problem: String?
    @Published private(set) var problemSymbol = ProblemCause.fallbackSymbol
    /// True after a temporary problem, when the account can be saved now and checked later.
    @Published private(set) var canSaveAnyway = false
    /// True when saving this account removed an OAuth token saved earlier.
    @Published private(set) var removedToken = false
    /// True when the account was saved without a successful check.
    @Published private(set) var savedWithoutCheck = false

    /// The key the organization list was read with. Connecting always uses this copy, never the field,
    /// which can change while a request is out.
    private var lookedUpKey: String?
    /// What to save if the person chooses Save Anyway after a temporary problem.
    private var pendingSave: (key: String, organizationId: String)?
    private var paste = PasteTracker()
    private var work: Task<Void, Never>?

    var cleanedKey: String { SessionKeyInput.clean(sessionKey) }
    var keyLooksRight: Bool { SessionKeyInput.looksLikeSessionKey(cleanedKey) }

    /// A typed-in ID wins over the list, so a missing or wrong list never blocks setup.
    var chosenOrganizationId: String {
        let typed = manualOrganizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        return showsManualEntry && !typed.isEmpty ? typed : (selectedOrganization ?? "")
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
        if keyLooksRight, paste.clearIfUnchanged() {
            clipboardCleared = true
        }
    }

    // MARK: Actions

    /// Looks up the organizations for the key in the field, and connects straight away when the choice is clear.
    func lookUp(monitor: UsageMonitor) {
        guard keyLooksRight, !isWorking else { return }
        let key = cleanedKey
        begin { [weak self] in await self?.findOrganizations(key: key, monitor: monitor) }
    }

    /// Connects the organization chosen or typed in the organization step.
    func connectChosen(monitor: UsageMonitor) {
        let organizationId = chosenOrganizationId
        guard let key = lookedUpKey, !organizationId.isEmpty, !isWorking else { return }
        begin { [weak self] in await self?.verifyAndSave(key: key, organizationId: organizationId, monitor: monitor) }
    }

    /// Saves the account after a temporary problem, and lets the app check it on its next refresh.
    func saveAnyway(monitor: UsageMonitor) {
        guard let pending = pendingSave, !isWorking else { return }
        begin { [weak self] in
            guard let self, self.save(key: pending.key, organizationId: pending.organizationId, monitor: monitor) else { return }
            self.savedWithoutCheck = true
            self.finish()
            Task { await monitor.refresh(trigger: .manual) }
        }
    }

    /// Stops anything in flight, clears a pasted key from the clipboard, and forgets the key. Called when the
    /// window closes, so nothing is saved after the person has left.
    func close() {
        work?.cancel()
        work = nil
        forgetKey()
        _ = paste.clearIfUnchanged()
    }

    /// Drops the typed key from memory.
    func forgetKey() {
        sessionKey = ""
        lookedUpKey = nil
        pendingSave = nil
    }

    // MARK: Steps

    private func begin(_ operation: @escaping @MainActor () async -> Void) {
        work?.cancel()
        isWorking = true
        problem = nil
        canSaveAnyway = false
        work = Task { [weak self] in
            await operation()
            self?.isWorking = false
        }
    }

    private func findOrganizations(key: String, monitor: UsageMonitor) async {
        manualOrganizationId = ""
        showsManualEntry = false
        let result = await UsageFetcher.live.organizations(sessionKey: key)
        guard !Task.isCancelled else { return }
        lookedUpKey = key
        switch result {
        case .success(let found):
            logger.notice("Setup found \(found.count, privacy: .public) organizations")
            organizations = found
            selectedOrganization = OrganizationParser.bestGuess(found)?.id
                ?? found.first(where: { $0.canChat == true })?.id ?? found.first?.id
            if let guess = OrganizationParser.bestGuess(found) {
                await verifyAndSave(key: key, organizationId: guess.id, monitor: monitor)
                // If the automatic choice didn't work, show the choices and the manual entry.
                if step != .finish, lookedUpKey != nil { step = .organization }
            } else {
                showsManualEntry = found.isEmpty
                step = .organization
            }
        case .failure(let error):
            logger.error("Setup couldn't list organizations: \(error.message, privacy: .public)")
            show(error)
            if ProblemCause(error) == .signIn || error == .invalidCredentials {
                lookedUpKey = nil
            } else {
                // The list couldn't be read, but the ID can still be typed in by hand.
                organizations = []
                showsManualEntry = true
                step = .organization
            }
        }
    }

    /// Checks the new account on its own, with no OAuth token, before replacing anything already saved.
    private func verifyAndSave(key: String, organizationId: String, monitor: UsageMonitor) async {
        guard SessionKeyInput.looksLikeSessionKey(key) else {
            show(.invalidCredentials)
            return
        }
        let config: WidgetConfig
        do {
            config = try WidgetConfig.fromFields(oauthToken: "", sessionKey: key, organizationId: organizationId)
        } catch let error as ConfigValidationError {
            problem = error.message
            problemSymbol = ProblemCause.setup.symbol
            return
        } catch {
            show(.invalidCredentials)
            return
        }
        let result = await UsageFetcher.live.fetch(config: config)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let report):
            guard save(key: key, organizationId: organizationId, monitor: monitor) else { return }
            monitor.adopt(report)
            finish()
        case .failure(let error):
            logger.error("Setup's connection check failed: \(error.message, privacy: .public)")
            show(error)
            pendingSave = (key, organizationId)
            canSaveAnyway = SetupMessages.canSaveAnyway(after: error)
            if ProblemCause(error) == .signIn {
                // The key itself was refused, so go back to where it's entered.
                lookedUpKey = nil
                pendingSave = nil
                step = .connect
            }
        }
    }

    /// Saves the account in place of whatever was saved. A saved OAuth token goes too: the app always tries a token
    /// first, so it would keep showing that token's account.
    private func save(key: String, organizationId: String, monitor: UsageMonitor) -> Bool {
        let existing = try? monitor.store.load()
        do {
            _ = try ConfigEditor.save(oauthToken: "", sessionKey: key, organizationId: organizationId, store: monitor.store)
        } catch let error as ConfigValidationError {
            problem = error.message
            problemSymbol = ProblemCause.setup.symbol
            return false
        } catch let error as UsageError {
            show(error)
            return false
        } catch {
            show(.keychain(errSecIO))
            return false
        }
        removedToken = existing?.oauthToken != nil
        monitor.credentialsChanged()
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }

    private func finish() {
        logger.notice("Setup connected")
        forgetKey()
        if paste.clearIfUnchanged() { clipboardCleared = true }
        step = .finish
    }

    private func show(_ error: UsageError) {
        problem = SetupMessages.text(for: error)
        problemSymbol = ProblemCause(error).symbol
    }
}

/// Remembers when a whole key was pasted into a field, so the clipboard can be cleared afterwards without ever
/// reading it: it's cleared only if nothing else was copied since.
struct PasteTracker {
    private var changeCount: Int?

    mutating func noteChange(from old: String, to new: String) {
        let arrivedAtOnce = new.count - old.count > 16
        if arrivedAtOnce, SessionKeyInput.looksLikeSessionKey(SessionKeyInput.clean(new)) {
            changeCount = NSPasteboard.general.changeCount
        }
    }

    /// Clears the clipboard if it still holds what was pasted. Returns true when it did.
    mutating func clearIfUnchanged() -> Bool {
        defer { changeCount = nil }
        guard let changeCount, NSPasteboard.general.changeCount == changeCount else { return false }
        NSPasteboard.general.clearContents()
        return true
    }
}

extension SetupModel {
    /// A model at one step with made-up content, for previews and offscreen checks. It never holds a real key.
    static func preview(step: Step, organizations: [ClaudeOrganization] = [], problem: String? = nil,
                        sampleKey: Bool = false, canSaveAnyway: Bool = false) -> SetupModel {
        let model = SetupModel()
        model.step = step
        model.organizations = organizations
        model.selectedOrganization = organizations.first?.id
        model.problem = problem
        model.canSaveAnyway = canSaveAnyway
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
