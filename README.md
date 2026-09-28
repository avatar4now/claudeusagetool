# Claude Usage Tool

A macOS menu bar app, desktop widget, and dashboard that show how much of your Claude plan limits you've used: the 5-hour session, the weekly limit, and model-specific weekly limits such as Fable.

![macOS](https://img.shields.io/badge/macOS-15.0+-blue)
![License](https://img.shields.io/badge/License-MIT-green)

Based on [ClaudeUsageWidget](https://github.com/dependentsign/ClaudeUsageWidget) by Huan Ma, under the MIT license.

## What you get

- **Menu bar:** the limit closest to full, such as `F 94%`, with a warning when another limit is nearly used up.
- **Desktop widget:** small, medium, and large sizes, with pace markers and reset times.
- **Dashboard:** current limits, a forecast of when each limit runs out, usage per day, this week's trend, and the last 24 hours of 5-hour sessions.
- **Private by design:** your session key stays in your Mac's login keychain and is sent only to claude.ai. Usage history stays on your Mac.

## Install

You build the app yourself on your Mac. It's free and takes a few minutes.

**You need**

- macOS 15 or later
- Xcode 16 or later, free from the Mac App Store
- A Claude plan with usage limits, such as Pro or Max

**Steps**

1. Open Xcode once. In **Xcode → Settings → Accounts**, add your Apple ID. A free Apple account works.
2. In Terminal, run:

   ```bash
   git clone https://github.com/avatar4now/claudeusagetool.git ~/ClaudeUsageTool
   cd ~/ClaudeUsageTool
   scripts/update-app.sh
   ```

   The script finds your signing team, runs the tests, builds the app, and installs it in `~/Applications`.

   Prefer Claude Code? Ask it: *"Clone https://github.com/avatar4now/claudeusagetool into ~/ClaudeUsageTool and run scripts/update-app.sh."*

3. Open **Claude Usage Widget** and connect your account in the window that opens.
4. To add the widget, right-click the desktop, choose **Edit Widgets**, and search for **Claude Usage**.

> Keep the project out of iCloud-synced folders such as Documents or Desktop. iCloud can restore deleted files and break the build.

## Connect your account

The app reads your usage the same way claude.ai's own Usage page does, using your browser session.

1. Sign in to [claude.ai](https://claude.ai) in your browser.
2. Open your browser's developer tools and find the cookie named `sessionKey`:
   - **Chrome, Arc, Edge, Brave:** View → Developer → Developer Tools → Application → Cookies → https://claude.ai
   - **Safari:** first turn on Settings → Advanced → Show features for web developers, then Develop → Show Web Inspector → Storage → Cookies
   - **Firefox:** Tools → Browser Tools → Web Developer Tools → Storage → Cookies
3. Paste the key into the app, then paste your organization ID from [claude.ai/api/organizations](https://claude.ai/api/organizations) (the `uuid` value).
4. Click **Save Configuration**. The app checks the connection right away.

## Update

```bash
cd ~/ClaudeUsageTool
git pull
scripts/update-app.sh
```

Your settings, history, and saved key carry over.

## Privacy and security

- A session key gives access to your Claude account. Treat it like a password and don't share it.
- The key is stored in your login keychain. Only this app and its widget can read it.
- The app sends the key only to claude.ai, and it refuses redirects to anywhere else.
- Usage history is percentages and reset times only. It's saved on your Mac for 90 days and never uploaded.
- Your Apple signing team is saved in `Config/Signing.local.xcconfig`, which git ignores.
- The app uses claude.ai's usage data, which isn't a documented API. It may change or break without notice.

## Development

- `Shared/` holds the logic used by both the app and the widget.
- `ClaudeUsageWidget/` is the app: menu bar, dashboard, and settings.
- `ClaudeUsageWidgetExtension/` is the widget.
- Run the logic tests with `swift test --scratch-path ~/Library/Caches/ClaudeUsageWidget/spm`. A scratch path outside iCloud keeps macOS from refusing to sign the test bundle.

## License

MIT. See [LICENSE](LICENSE). Original work © 2026 Huan Ma.
