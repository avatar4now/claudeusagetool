import SwiftUI
import WidgetKit
import os

/// Logs outcomes only, never credential values.
private let logger = Logger(subsystem: "dev.huan.ClaudeUsageWidget", category: "app")

struct ContentView: View {
    @ObservedObject var monitor: UsageMonitor

    @State private var sessionKey = ""
    @State private var organizationId = ""
    @State private var oauthToken = ""
    @State private var statusMessage = ""
    @State private var isSuccess = false
    @State private var isChecking = false

    private static let organizationsURL = URL(string: "https://claude.ai/api/organizations")!

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "chart.bar.fill")
                    .font(.title)
                    .foregroundStyle(.purple)
                VStack(alignment: .leading) {
                    Text("Claude Usage Widget")
                        .font(.title2.bold())
                    Text("Configure your credentials")
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

            HStack(spacing: 8) {
                Text("Refresh usage every")
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
            .font(.callout)

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
                    Task { await checkConnection() }
                }
                .buttonStyle(.bordered)
                .disabled(isChecking)
            }

            Spacer()

            VStack(spacing: 4) {
                Text("Stored in your login keychain. Only this app and its widget can read it.")
                Text(AppVersion.display)
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 560)
        .onAppear {
            migrateLegacyFile()
            loadConfig()
        }
    }

    /// Moves credentials out of the old plaintext file, if it still exists.
    func migrateLegacyFile() {
        let outcome = ConfigMigration.run(store: monitor.store)
        logger.notice("Legacy config migration: \(String(describing: outcome), privacy: .public)")
        if let message = outcome.message {
            statusMessage = message
            isSuccess = outcome == .imported
        }
    }

    func saveConfig() {
        do {
            let outcome = try ConfigEditor.save(oauthToken: oauthToken, sessionKey: sessionKey,
                                                organizationId: organizationId, store: monitor.store)
            logger.notice("Save: \(String(describing: outcome), privacy: .public)")
            loadConfig()
            WidgetCenter.shared.reloadAllTimelines()
            switch outcome {
            case .saved:
                Task { await checkConnection() }
            case .cleared:
                statusMessage = "Credentials removed from your keychain."
                isSuccess = true
                Task { await monitor.refresh() }
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

    /// Fetches usage right now with the saved credentials and says what worked or what to fix.
    func checkConnection() async {
        isChecking = true
        statusMessage = "Checking the connection…"
        let line = ConnectionSummary.message(for: await monitor.refresh())
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
