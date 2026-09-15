import AppKit
import SwiftUI
import WidgetKit
import os

/// Logs outcomes only, never credential values.
private let logger = Logger(subsystem: "dev.huan.ClaudeUsageWidget", category: "app")

struct SettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @ObservedObject var loginItem: LoginItemController

    @State private var sessionKey = ""
    @State private var organizationId = ""
    @State private var oauthToken = ""
    @State private var statusMessage = ""
    @State private var isSuccess = false
    @State private var isChecking = false
    @State private var confirmingClearHistory = false
    @State private var historySummary = ""

    private static let organizationsURL = URL(string: "https://claude.ai/api/organizations")!

    var body: some View {
        ScrollView {
        VStack(spacing: 18) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.fill")
                    .font(.title)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading) {
                    Text("Claude Usage Widget")
                        .font(.title2.bold())
                    Text("Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

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

            GroupBox("Display and startup") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Menu bar shows")
                            .frame(width: 140, alignment: .leading)
                        Picker("Menu bar shows", selection: Binding(get: { monitor.menuBarMetric },
                                                                    set: { monitor.setMenuBarMetric($0) })) {
                            ForEach(MenuBarMetric.allCases, id: \.self) { metric in
                                Text(metric.title).tag(metric)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Text("Refresh usage every")
                            .frame(width: 140, alignment: .leading)
                        Picker("Refresh every", selection: Binding(get: { monitor.refreshSeconds },
                                                                   set: { monitor.setRefreshInterval($0) })) {
                            ForEach(RefreshSchedule.choices, id: \.self) { seconds in
                                Text(RefreshSchedule.label(for: seconds)).tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        Text("Applies to the menu bar and the widget.")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Toggle("Open at login", isOn: Binding(get: { loginItem.state == .on || loginItem.state == .needsApproval },
                                                          set: { loginItem.setEnabled($0) }))
                        .disabled(!loginItem.isInstalledCopy)
                    loginStatus
                }
                .font(.callout)
                .padding(8)
            }

            GroupBox("Usage history") {
                VStack(alignment: .leading, spacing: 8) {
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
                            .controlSize(.small)
                    }
                }
                .font(.callout)
                .padding(8)
            }
            .confirmationDialog("Clear all saved usage history?", isPresented: $confirmingClearHistory) {
                Button("Clear History", role: .destructive) {
                    monitor.clearHistory()
                    updateHistorySummary()
                }
            } message: {
                Text("The dashboard's charts start again from the next reading. This can't be undone.")
            }

            // Status
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

            Spacer()

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stored in your login keychain. Only this app and its widget can read it.")
                    Text(AppVersion.display)
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit Claude Usage Widget") {
                    NSApplication.shared.terminate(nil)
                }
                .controlSize(.small)
            }
        }
        .padding(24)
        }
        .frame(minWidth: 580, minHeight: 640, idealHeight: 860)
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
    }

    private func updateHistorySummary() {
        let samples = monitor.history.load(now: Date())
        if let first = samples.first {
            historySummary = "\(samples.count) readings since \(first.at.formatted(date: .abbreviated, time: .omitted))"
        } else {
            historySummary = "No readings saved yet"
        }
    }

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
            sessionKey = config.sessionKey ?? ""
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
