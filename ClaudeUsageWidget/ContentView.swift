import SwiftUI
import Darwin

private enum ConfigLocation {
    static var url: URL {
        if let passwd = getpwuid(getuid()) {
            return URL(fileURLWithPath: String(cString: passwd.pointee.pw_dir), isDirectory: true)
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("claude-usage-widget.json", isDirectory: false)
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("claude-usage-widget.json", isDirectory: false)
    }
}

struct ContentView: View {
    @State private var sessionKey = ""
    @State private var organizationId = ""
    @State private var oauthToken = ""
    @State private var statusMessage = ""
    @State private var isSuccess = false

    private let configURL = ConfigLocation.url

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

            Text("Config saved to: ~/.claude/claude-usage-widget.json")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(minWidth: 500, minHeight: 400)
        .onAppear {
            loadConfig()
        }
    }

    func saveConfig() {
        let config: [String: String?] = [
            "sessionKey": sessionKey.isEmpty ? nil : sessionKey,
            "organizationId": organizationId.isEmpty ? nil : organizationId,
            "oauthToken": oauthToken.isEmpty ? nil : oauthToken
        ]

        do {
            let data = try JSONSerialization.data(
                withJSONObject: config.compactMapValues { $0 },
                options: [.prettyPrinted, .sortedKeys]
            )
            let dir = configURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: configURL)
            statusMessage = "Configuration saved!"
            isSuccess = true
        } catch {
            statusMessage = "Failed to save: \(error.localizedDescription)"
            isSuccess = false
        }
    }

    func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        sessionKey = json["sessionKey"] ?? ""
        organizationId = json["organizationId"] ?? ""
        oauthToken = json["oauthToken"] ?? ""
    }
}

#Preview {
    ContentView()
}
