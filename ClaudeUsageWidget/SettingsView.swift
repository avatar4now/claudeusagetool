import AppKit
import KeyboardShortcuts
import SwiftUI
import WidgetKit
import os

/// Logs outcomes only, never credential values.
private let logger = Logger(subsystem: "dev.huan.ClaudeUsageWidget", category: "app")

struct SettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var updates: UpdateChecker

    @State private var sessionKey = ""
    /// Notices a pasted key, so the clipboard can be cleared once it's saved.
    @State private var paste = PasteTracker()
    /// The key as loaded from the keychain; showing it isn't a paste.
    @State private var loadedKey = ""
    @State private var organizationId = ""
    @State private var oauthToken = ""
    @State private var statusMessage = ""
    @State private var isSuccess = false
    @State private var isChecking = false
    @State private var confirmingClearHistory = false
    @State private var historySummary = ""

    private static let organizationsURL = URL(string: "https://claude.ai/api/organizations")!

    @AppStorage(SettingsTab.storageKey) private var tab = SettingsTab.account.rawValue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TabView(selection: $tab) {
            accountTab
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(SettingsTab.account.rawValue)
            AppearanceSettings(monitor: monitor)
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(SettingsTab.appearance.rawValue)
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general.rawValue)
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about.rawValue)
        }
        .padding(.top, 6)
        .frame(minWidth: 640, minHeight: 640, idealHeight: 820)
        .enablesDashboardShortcut()
        .onAppear {
            loadConfig()
            loginItem.refresh()
            updateHistorySummary()
            WindowPresence.opened()
        }
        .onDisappear {
            WindowPresence.closed()
        }
        .onChange(of: monitor.historyRevision) { updateHistorySummary() }
        // Setup can save new credentials while this window is open; show them, so Save can't bring back old ones.
        .onChange(of: monitor.credentialsRevision) { loadConfig() }
        .onChange(of: sessionKey) { old, new in
            if new != loadedKey { paste.noteChange(from: old, to: new) }
        }
    }

    // MARK: Account

    private var accountTab: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Setting up or switching accounts?")
                            .font(.headline)
                        Text("The setup assistant walks you through it and finds your organization for you.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Set Up Assistant…") { openWindow(id: AppWindow.setup) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

                GroupBox("Session Key (recommended)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("On claude.ai, open your browser's Developer Tools, go to Application → Cookies, and copy the sessionKey value.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        SecureField("Session Key (sk-ant-sid01-...)", text: $sessionKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        HStack(spacing: 4) {
                            Text("Organization ID: copy the \"uuid\" shown at")
                                .foregroundStyle(.secondary)
                            Link("claude.ai/api/organizations", destination: Self.organizationsURL)
                        }
                        .font(.caption)
                        TextField("Organization ID (uuid)", text: $organizationId)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .padding(8)
                }

                GroupBox("OAuth Token (optional)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tokens from claude setup-token can't read usage, so leave this blank unless you have a token that can.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        SecureField("OAuth Bearer Token", text: $oauthToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .padding(8)
                }

                if !statusMessage.isEmpty {
                    HStack(spacing: 6) {
                        if isChecking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(isChecking ? Color.secondary : (isSuccess ? Color.green : Color.red))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal)
                }

                HStack {
                    Button("Save Configuration") {
                        saveConfig()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isChecking)

                    Button("Test Connection") {
                        Task { await checkConnection(afterSave: false) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isChecking)
                }

                Text("Stored in your login keychain. Only this app and its widget can read it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
        }
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section("Refresh") {
                Picker("Refresh usage every", selection: Binding(get: { monitor.refreshSeconds },
                                                                 set: { monitor.setRefreshInterval($0) })) {
                    ForEach(RefreshSchedule.choices, id: \.self) { seconds in
                        Text(RefreshSchedule.label(for: seconds)).tag(seconds)
                    }
                }
                Text("Applies to the menu bar and the widget.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Show the dashboard") {
                    KeyboardShortcuts.Recorder(for: .showDashboard)
                }
            } header: {
                Text("Keyboard shortcut")
            } footer: {
                Text("Press it in any app to bring up the dashboard. Leave it empty for no shortcut.")
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Open at login", isOn: Binding(get: { loginItem.state == .on || loginItem.state == .needsApproval },
                                                      set: { loginItem.setEnabled($0) }))
                    .disabled(!loginItem.isInstalledCopy)
                loginStatus
            }

            Section("Usage history") {
                Toggle("Keep a history of readings for the dashboard", isOn: Binding(get: { monitor.isHistoryEnabled },
                                                                                   set: { monitor.setHistoryEnabled($0) }))
                Text("Percentages and reset times only, saved on this Mac for 90 days. Nothing is sent anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(historySummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear History…") { confirmingClearHistory = true }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Quit Claude Usage Widget") {
                        NSApplication.shared.terminate(nil)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear all saved usage history?", isPresented: $confirmingClearHistory) {
            Button("Clear History", role: .destructive) {
                monitor.clearHistory()
                updateHistorySummary()
            }
        } message: {
            Text("The dashboard's charts start again from the next reading. This can't be undone.")
        }
    }

    private func updateHistorySummary() {
        let samples = monitor.history.load(now: Date())
        if let first = samples.first {
            historySummary = "\(samples.count) readings since \(first.at.formatted(date: .abbreviated, time: .omitted))"
        } else {
            historySummary = "No readings saved yet"
        }
    }

    // MARK: About

    /// Which version is running and which code it was built from.
    private var aboutTab: some View {
        let build = AppVersion.current
        return Form {
            Section {
                LabeledContent("Version", value: "\(build.version) (\(build.build))")
                LabeledContent("Built", value: build.builtText())
                LabeledContent("Commit") {
                    if let commit = build.displayCommit {
                        HStack(spacing: 6) {
                            Text(commit)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            if build.isModified {
                                Text("includes uncommitted changes")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Branch", value: build.branch ?? "—")
            } header: {
                Text("Claude Usage Widget")
            } footer: {
                Text("Your usage history and settings stay on this Mac. Your session key is kept in your login keychain and sent only to claude.ai.")
                    .foregroundStyle(.secondary)
            }
            updatesSection
        }
        .formStyle(.grouped)
    }

    /// Whether a newer version is out, and how to get it.
    @ViewBuilder
    private var updatesSection: some View {
        Section {
            if let repository = updates.repository {
                LabeledContent("Status") {
                    if updates.isChecking {
                        ProgressView().controlSize(.small)
                    } else if let available = updates.available {
                        Label("Version \(available.version) is available", systemImage: "arrow.down.circle.fill")
                            .foregroundStyle(.tint)
                    } else if let problem = updates.problem {
                        Text(problem).foregroundStyle(.secondary)
                    } else if updates.lastChecked == nil {
                        Text("Not checked yet").foregroundStyle(.secondary)
                    } else {
                        Text("Up to date").foregroundStyle(.secondary)
                    }
                }
                if let lastChecked = updates.lastChecked {
                    LabeledContent("Last checked", value: lastChecked.formatted(.relative(presentation: .named)))
                }
                if let available = updates.available {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("To update, open Terminal in the folder you cloned and run:")
                        HStack {
                            Text(Self.updateCommand)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Self.updateCommand, forType: .string)
                            }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                        Text("Or ask Claude Code to update Claude Usage Widget. Your settings, history, and saved key carry over.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let page = available.page ?? Optional(repository.releasesPage) {
                            Link("What's new in \(available.version)", destination: page)
                        }
                    }
                }
                HStack {
                    Toggle("Check for new versions once a day", isOn: Binding(get: { updates.isEnabled },
                                                                              set: { updates.setEnabled($0) }))
                    Spacer()
                    Button("Check Now") { Task { await updates.checkNow() } }
                        .disabled(updates.isChecking)
                }
            } else {
                Text("This copy wasn't built from a GitHub clone, so it can't check for new versions.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Updates")
        } footer: {
            if let repository = updates.repository {
                Text("Checks the latest release of github.com/\(repository.path). It sends no account details or usage.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let updateCommand = "scripts/update-app.sh --pull"

    @ViewBuilder
    private var loginStatus: some View {
        Group {
            if !loginItem.isInstalledCopy {
                Text("This copy runs from a build folder. Install it with scripts/update-app.sh, then turn this on.")
            } else if loginItem.state == .needsApproval {
                HStack {
                    Text("Approve Claude Usage Widget in System Settings → General → Login Items.")
                    Button("Open Login Items") { loginItem.openLoginItemsSettings() }
                        .controlSize(.small)
                }
            } else if loginItem.state == .on {
                Text("Starts automatically when you log in.")
            } else if loginItem.state == .unavailable {
                Text("macOS can't register this copy as a login item.")
            }
            if let lastError = loginItem.lastError {
                Text("Couldn't change the login item: \(lastError)")
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    func saveConfig() {
        do {
            let outcome = try ConfigEditor.save(oauthToken: oauthToken, sessionKey: sessionKey,
                                                organizationId: organizationId, store: monitor.store)
            logger.notice("Save: \(String(describing: outcome), privacy: .public)")
            loadConfig()
            monitor.credentialsChanged()
            WidgetCenter.shared.reloadAllTimelines()
            switch outcome {
            case .saved:
                _ = paste.clearIfUnchanged()
                Task { await checkConnection(afterSave: true) }
            case .cleared:
                statusMessage = "Credentials removed from your keychain."
                isSuccess = true
                Task { await monitor.refresh(trigger: .manual) }
            }
        } catch let error as ConfigValidationError {
            statusMessage = error.message
            isSuccess = false
        } catch let error as UsageError {
            logger.error("Save failed: \(error.message, privacy: .public)")
            statusMessage = error.message
            isSuccess = false
        } catch {
            statusMessage = "Couldn't finish saving: \(error.localizedDescription)"
            isSuccess = false
        }
    }

    /// Fetches usage now with the saved credentials and says what worked or what to fix.
    /// A rate-limit cooldown is honored even here; the check waits rather than retrying early.
    func checkConnection(afterSave: Bool) async {
        isChecking = true
        statusMessage = afterSave ? "Saved. Checking the connection…" : "Checking the connection…"
        let result = await monitor.refresh(trigger: .connectionTest)
        var line = ConnectionSummary.message(for: result)
        if case .failure(.rateLimited) = result, let until = monitor.cooldown?.until {
            let prefix = afterSave ? "Saved. " : ""
            line = ConnectionSummary.Line(
                text: "\(prefix)The usage service asked the app to wait. Next try at \(until.formatted(date: .omitted, time: .shortened)).",
                isSuccess: afterSave)
        }
        logger.notice("Connection check: \(line.isSuccess ? "ok" : "failed", privacy: .public)")
        statusMessage = line.text
        isSuccess = line.isSuccess
        isChecking = false
    }

    func loadConfig() {
        do {
            let config = try monitor.store.load() ?? WidgetConfig()
            oauthToken = config.oauthToken ?? ""
            loadedKey = config.sessionKey ?? ""
            sessionKey = loadedKey
            organizationId = config.organizationId ?? ""
        } catch let error as UsageError {
            statusMessage = error.message
            isSuccess = false
        } catch {
            statusMessage = "Couldn't read the keychain."
            isSuccess = false
        }
    }
}
