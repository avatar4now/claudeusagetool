import Foundation

/// The GitHub repository a copy of the app was built from. scripts/update-app.sh records it at build time, so each
/// person's copy checks the repository they cloned, and nothing about it is written into the source code.
struct SourceRepository: Equatable, Sendable {
    let owner: String
    let name: String

    var path: String { "\(owner)/\(name)" }

    /// Accepts "owner/name", https://github.com/owner/name(.git), or git@github.com:owner/name(.git).
    /// A user name or token in the address is dropped, and anything that isn't a plain GitHub repository is refused.
    init?(remote: String) {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("git@github.com:") {
            text = String(text.dropFirst("git@github.com:".count))
        } else if text.contains("://") {
            guard let url = URLComponents(string: text), url.scheme == "https", url.host?.lowercased() == "github.com"
            else { return nil }
            text = String(url.path.drop(while: { $0 == "/" }))
        }
        if text.hasSuffix(".git") { text = String(text.dropLast(4)) }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts.allSatisfy({ Self.isValidPart($0) }) else { return nil }
        owner = parts[0]
        name = parts[1]
    }

    /// GitHub names use letters, digits, hyphens, underscores, and dots.
    private static func isValidPart(_ part: String) -> Bool {
        !part.isEmpty && part.count <= 100 && part != "." && part != ".."
            && part.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) }
    }

    var latestReleaseURL: URL { URL(string: "https://api.github.com/repos/\(path)/releases/latest")! }
    var releasesPage: URL { URL(string: "https://github.com/\(path)/releases")! }
}

/// The newest published version, from GitHub's latest release.
struct ReleaseInfo: Equatable, Sendable {
    /// Like "1.7", without a leading "v".
    let version: String
    let title: String?
    /// The release page on github.com, or nil when the reply pointed anywhere else.
    let page: URL?
    let publishedAt: Date?
}

enum UpdateCheck {
    /// Check at most once a day, so GitHub sees one request per person per day.
    static let interval: TimeInterval = 86_400

    static func isDue(lastChecked: Date?, now: Date) -> Bool {
        guard let lastChecked else { return true }
        let elapsed = now.timeIntervalSince(lastChecked)
        return elapsed < 0 || elapsed >= interval
    }

    /// Reads GitHub's reply for the latest release. A tag that isn't a version number is an error.
    static func parseRelease(_ data: Data) throws -> ReleaseInfo {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String, let version = version(fromTag: tag) else {
            throw UsageError.invalidResponse
        }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)).flatMap { url in
            url.scheme == "https" && url.host?.lowercased() == "github.com" ? url : nil
        }
        let title = (json["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return ReleaseInfo(version: version, title: title, page: page, publishedAt: UsageParser.date(json["published_at"]))
    }

    /// "v1.7" or "1.7" becomes "1.7". Anything that isn't dot-separated numbers is nil.
    static func version(fromTag tag: String) -> String? {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) && $0.count <= 6 })
        else { return nil }
        return text
    }

    /// True when `candidate` is a higher version than `current`, comparing each number in turn ("1.10" > "1.9").
    /// An unknown current version never counts as older.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = numbers(candidate), let old = numbers(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int]? {
        guard let clean = self.version(fromTag: version) else { return nil }
        return clean.split(separator: ".").compactMap { Int($0) }
    }
}
