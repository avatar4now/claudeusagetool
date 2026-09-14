import SwiftUI
import WidgetKit
import os

/// Logs outcomes only, never credential values.
private let logger = Logger(subsystem: "dev.huan.ClaudeUsageWidget", category: "app")

struct ContentView: View {
    @State private var sessionKey = ""
    @State private var organizationId = ""
    @State private var oauthToken = ""
    @State private var statusMessage = ""
    @State private var isSuccess = false

    /// The keychain item is shared with exactly one other program: the widget embedded inside this app.
    private let store = KeychainCredentialStore(trustedBundleURLs: [
        Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/ClaudeUsageWidgetExtension.appex")
    ])

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
                    Text("Configure your API credentials")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // OAuth section
            GroupBox("OAuth Token (recommended)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("If you use Claude Code with OAuth, paste your token here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("OAuth Bearer Token", text: $oauthToken)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                .padding(8)
            }

            GroupBox("Session Key (alternative)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Get your sessionKey from claude.ai browser cookies and your org ID from the API.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("Session Key (sk-ant-sid01-...)", text: $sessionKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    TextField("Organization ID (uuid)", text: $organizationId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                .padding(8)
            }

            // Status
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(isSuccess ? .green : .red)
                    .padding(.horizontal)
            }

            HStack {
                Button("Save Configuration") {
                    saveConfig()
                }
                .buttonStyle(.borderedProminent)

                Button("Load Existing") {
                    loadConfig()
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Text("Stored in your login keychain. Only this app and its widget can read it.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            migrateLegacyFile()
            loadConfig()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Moves credentials out of the old plaintext file, if it still exists.
    func migrateLegacyFile() {
        let outcome = ConfigMigration.run(store: store)
        logger.notice("Legacy config migration: \(String(describing: outcome), privacy: .public)")
        if let message = outcome.message {
            statusMessage = message
            isSuccess = outcome == .imported
        }
    }

    func saveConfig() {
        do {
            let outcome = try ConfigEditor.save(oauthToken: oauthToken, sessionKey: sessionKey,
                                                organizationId: organizationId, store: store)
            logger.notice("Save: \(String(describing: outcome), privacy: .public)")
            statusMessage = outcome == .saved
                ? "Saved to your keychain. The widget is refreshing."
                : "Credentials removed from your keychain."
            isSuccess = true
            loadConfig()
            WidgetCenter.shared.reloadAllTimelines()
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

    func loadConfig() {
        do {
            let config = try store.load() ?? WidgetConfig()
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

#Preview {
    ContentView()
}
