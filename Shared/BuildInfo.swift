import Foundation

/// Which version of the app is running and, when scripts/update-app.sh built it, which code it came from.
struct BuildInfo: Equatable, Sendable {
    /// Like "1.5", or "?" when unknown.
    let version: String
    /// Like "5", or "?" when unknown.
    let build: String
    /// The short git commit, like "0614b21", ending in "-modified" when there were uncommitted changes.
    let commit: String?
    let branch: String?
    let builtAt: Date?

    /// Added to the commit when the build included changes that weren't committed yet.
    static let modifiedSuffix = "-modified"

    /// Reads the values from an Info.plist dictionary, usually Bundle.main.infoDictionary.
    init(infoDictionary: [String: Any]?) {
        func value(_ key: String) -> String? {
            Self.cleaned(infoDictionary?[key])
        }
        version = value("CFBundleShortVersionString") ?? "?"
        build = value("CFBundleVersion") ?? "?"
        let commit = value("CUWBuildCommit")
        // A suffix with no commit before it tells us nothing.
        self.commit = commit == Self.modifiedSuffix ? nil : commit
        branch = value("CUWBuildBranch")
        builtAt = value("CUWBuildDate").flatMap { try? Date($0, strategy: .iso8601) }
    }

    /// Like "Version 1.5 (5)".
    var versionText: String {
        "Version \(version) (\(build))"
    }

    /// Like "Version 1.5 (5) · 0614b21", for the menu bar panel.
    var shortText: String {
        guard let displayCommit else { return versionText }
        return "\(versionText) · \(displayCommit)" + (isModified ? " (modified)" : "")
    }

    /// True when the app was built with uncommitted changes.
    var isModified: Bool {
        commit?.hasSuffix(Self.modifiedSuffix) ?? false
    }

    /// The commit without the "-modified" suffix.
    var displayCommit: String? {
        guard let commit else { return nil }
        return isModified ? String(commit.dropLast(Self.modifiedSuffix.count)) : commit
    }

    /// When the app was built, in this Mac's time zone, or "Built in Xcode" when the build didn't record it.
    func builtText(timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        guard let builtAt else { return "Built in Xcode" }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)
        style.timeZone = timeZone
        return builtAt.formatted(style)
    }

    /// A trimmed string, or nil when it's missing, blank, or a build setting Xcode didn't fill in.
    private static func cleaned(_ raw: Any?) -> String? {
        guard let text = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !text.contains("$(") else { return nil }
        return text
    }
}
