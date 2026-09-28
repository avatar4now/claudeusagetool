import Foundation

// MARK: - One saved reading

/// A reading kept for the dashboard's history: percentages and reset times only, never credentials or account details.
struct UsageSample: Codable, Equatable, Sendable {
    var at: Date
    var fiveHour: Double?
    var fiveHourReset: Date?
    var weekly: Double?
    var weeklyReset: Date?
    var fable: Double?
    var fableReset: Date?

    init(at: Date, fiveHour: Double?, fiveHourReset: Date?, weekly: Double?, weeklyReset: Date?, fable: Double?, fableReset: Date?) {
        self.at = at
        self.fiveHour = fiveHour
        self.fiveHourReset = fiveHourReset
        self.weekly = weekly
        self.weeklyReset = weeklyReset
        self.fable = fable
        self.fableReset = fableReset
    }

    init(snapshot: UsageSnapshot, at: Date) {
        self.init(at: at, fiveHour: snapshot.fiveHourPercent, fiveHourReset: snapshot.fiveHourResetsAt,
                  weekly: snapshot.weeklyPercent, weeklyReset: snapshot.weeklyResetsAt,
                  fable: snapshot.fableWeeklyPercent, fableReset: snapshot.fableWeeklyResetsAt)
    }

    // Short keys keep the history file small.
    enum CodingKeys: String, CodingKey {
        case at = "t", fiveHour = "h", fiveHourReset = "hr", weekly = "w", weeklyReset = "wr", fable = "f", fableReset = "fr"
    }
}

// MARK: - When to save a reading

enum HistoryPolicy {
    /// Save at most one reading every 5 minutes...
    static let minimumSpacing: TimeInterval = 5 * 60
    /// ...unless a number moves this many points or a window resets.
    static let meaningfulChange = 5.0
    /// Readings older than this are removed.
    static let retention: TimeInterval = 90 * 86_400
    /// Reset times this close together belong to the same window (the service's reset time can wobble slightly).
    static let sameWindowTolerance: TimeInterval = 10 * 60
    /// A gap longer than this between readings means the app wasn't running for a while.
    static let closedAppGap: TimeInterval = 6 * 3600

    static func shouldRecord(_ sample: UsageSample, after last: UsageSample?) -> Bool {
        guard let last else { return true }
        if sample.at.timeIntervalSince(last.at) >= minimumSpacing { return true }
        let resets = [(last.fiveHourReset, sample.fiveHourReset), (last.weeklyReset, sample.weeklyReset), (last.fableReset, sample.fableReset)]
        if resets.contains(where: { windowChanged($0.0, $0.1) }) { return true }
        let values = [(last.fiveHour, sample.fiveHour), (last.weekly, sample.weekly), (last.fable, sample.fable)]
        return values.contains { old, new in
            guard let old, let new else { return (old == nil) != (new == nil) }
            return abs(new - old) >= meaningfulChange
        }
    }

    static func windowChanged(_ old: Date?, _ new: Date?) -> Bool {
        switch (old, new) {
        case let (old?, new?): return abs(new.timeIntervalSince(old)) > sameWindowTolerance
        case (nil, nil): return false
        default: return true
        }
    }
}

// MARK: - Turning readings into charts

/// One calendar day in the "used per day" chart.
struct DailyUsage: Identifiable, Equatable, Sendable {
    var id: Date { day }
    /// Midnight at the start of the day, in the Mac's time zone.
    let day: Date
    /// Percentage points of the weekly (all models) limit used that day.
    var weeklyPoints: Double = 0
    /// Percentage points of the weekly Fable limit used that day.
    var fablePoints: Double = 0
    /// The highest five-hour reading seen that day.
    var peakFiveHour: Double?
    /// Five-hour sessions whose highest reading reached 90% or more, counted on the day they peaked.
    var fiveHourSessionsOverNinety = 0
    var hasReadings = false
    /// True when some of the day's total happened while the app was closed, so it can't be placed more precisely.
    var includesTimeAppWasClosed = false
}

struct SeriesPoint: Identifiable, Equatable, Sendable {
    var id: Date { at }
    let at: Date
    let value: Double
}

struct WeekPoint: Identifiable, Equatable, Sendable {
    var id: Date { at }
    let at: Date
    let weekly: Double?
    let fable: Double?
}

/// The current weekly window: from one week before its reset until the reset.
struct WeekSeries: Equatable, Sendable {
    let start: Date
    let end: Date
    let points: [WeekPoint]
}

enum UsageHistoryAnalysis {
    /// Usage per day for the `days` days ending on `endingOn`, oldest first. Days without readings are included as zero.
    ///
    /// The weekly percentage only ever rises within a window, so the points used on a day are the rises between
    /// consecutive readings, credited to the later reading's day. After a reset, usage counts again from zero.
    static func daily(_ samples: [UsageSample], days: Int, endingOn end: Date, calendar: Calendar) -> [DailyUsage] {
        let lastDay = calendar.startOfDay(for: end)
        let dayStarts = (0..<max(days, 1)).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: lastDay) }
        var byDay = Dictionary(uniqueKeysWithValues: dayStarts.map { ($0, DailyUsage(day: $0)) })
        let sorted = samples.sorted { $0.at < $1.at }

        func update(_ date: Date, _ change: (inout DailyUsage) -> Void) {
            let day = calendar.startOfDay(for: date)
            guard var entry = byDay[day] else { return }
            change(&entry)
            byDay[day] = entry
        }

        var previousWeekly: (value: Double, reset: Date?, at: Date)?
        var previousFable: (value: Double, reset: Date?, at: Date)?
        var sessions: [(reset: Date, peak: Double, peakAt: Date)] = []

        for sample in sorted {
            update(sample.at) { $0.hasReadings = true }

            if let value = sample.weekly {
                if let previous = previousWeekly {
                    let points = rise(from: previous, to: value, reset: sample.weeklyReset)
                    update(sample.at) {
                        $0.weeklyPoints += points
                        if points > 0, sample.at.timeIntervalSince(previous.at) > HistoryPolicy.closedAppGap { $0.includesTimeAppWasClosed = true }
                    }
                }
                previousWeekly = (value, sample.weeklyReset, sample.at)
            }

            if let value = sample.fable {
                if let previous = previousFable {
                    let points = rise(from: previous, to: value, reset: sample.fableReset)
                    update(sample.at) {
                        $0.fablePoints += points
                        if points > 0, sample.at.timeIntervalSince(previous.at) > HistoryPolicy.closedAppGap { $0.includesTimeAppWasClosed = true }
                    }
                }
                previousFable = (value, sample.fableReset, sample.at)
            }

            if let value = sample.fiveHour {
                update(sample.at) { $0.peakFiveHour = max($0.peakFiveHour ?? value, value) }
                if let reset = sample.fiveHourReset {
                    if let index = sessions.firstIndex(where: { !HistoryPolicy.windowChanged($0.reset, reset) }) {
                        if value > sessions[index].peak { sessions[index].peak = value; sessions[index].peakAt = sample.at }
                    } else {
                        sessions.append((reset, value, sample.at))
                    }
                }
            }
        }

        for session in sessions where session.peak >= 90 {
            update(session.peakAt) { $0.fiveHourSessionsOverNinety += 1 }
        }
        return dayStarts.compactMap { byDay[$0] }
    }

    /// Points added since the previous reading. Within the same window a drop counts as zero; in a new window the whole
    /// value is new usage. Without reset times, a drop is taken to mean a new window.
    private static func rise(from previous: (value: Double, reset: Date?, at: Date), to value: Double, reset: Date?) -> Double {
        let sameWindow: Bool
        if previous.reset != nil, reset != nil {
            sameWindow = !HistoryPolicy.windowChanged(previous.reset, reset)
        } else {
            sameWindow = value >= previous.value
        }
        return sameWindow ? max(0, value - previous.value) : value
    }

    /// The weekly and Fable readings in the most recent weekly window, for the "this week" chart.
    static func currentWeek(_ samples: [UsageSample], now: Date) -> WeekSeries? {
        let sorted = samples.filter { $0.at <= now.addingTimeInterval(60) }.sorted { $0.at < $1.at }
        guard let reset = sorted.last(where: { $0.weeklyReset != nil })?.weeklyReset else { return nil }
        let points = sorted.compactMap { sample -> WeekPoint? in
            let weekly = HistoryPolicy.windowChanged(sample.weeklyReset, reset) ? nil : sample.weekly
            let fable = HistoryPolicy.windowChanged(sample.fableReset, reset) ? nil : sample.fable
            guard weekly != nil || fable != nil else { return nil }
            return WeekPoint(at: sample.at, weekly: weekly, fable: fable)
        }
        return WeekSeries(start: reset.addingTimeInterval(-LimitKind.weekly.windowLength), end: reset, points: points)
    }

    /// Five-hour readings from the last 24 hours.
    static func recentFiveHour(_ samples: [UsageSample], now: Date) -> [SeriesPoint] {
        let since = now.addingTimeInterval(-86_400)
        return samples
            .filter { $0.at >= since && $0.at <= now.addingTimeInterval(60) }
            .sorted { $0.at < $1.at }
            .compactMap { sample in sample.fiveHour.map { SeriesPoint(at: sample.at, value: $0) } }
    }

    /// Readings of one limit from its current window (the window that resets at `resetsAt`), for a small trend line.
    static func currentWindow(_ samples: [UsageSample], kind: LimitKind, resetsAt: Date?, now: Date) -> [SeriesPoint] {
        guard let resetsAt else { return [] }
        let start = resetsAt.addingTimeInterval(-kind.windowLength)
        return samples
            .filter { $0.at >= start && $0.at <= now.addingTimeInterval(60) && !HistoryPolicy.windowChanged($0.reset(for: kind), resetsAt) }
            .sorted { $0.at < $1.at }
            .compactMap { sample in sample.value(for: kind).map { SeriesPoint(at: sample.at, value: $0) } }
    }

    /// When the weekly limit reset between `from` and `to`, judged from the reset times the readings reported.
    /// Reset times within a few minutes of each other are the same reset.
    static func weeklyResets(_ samples: [UsageSample], from: Date, to: Date) -> [Date] {
        var resets: [Date] = []
        for reset in samples.sorted(by: { $0.at < $1.at }).compactMap(\.weeklyReset)
        where !resets.contains(where: { !HistoryPolicy.windowChanged($0, reset) }) {
            resets.append(reset)
        }
        return resets.filter { $0 >= from && $0 <= to }.sorted()
    }

    /// Readings further apart than this can't say which hour the usage between them happened in.
    static let rhythmMaximumGap: TimeInterval = 60 * 60

    /// Weekly (all models) points used in each hour of each weekday over the `days` days ending on `endingOn`.
    /// Each rise between two close readings is placed at the time halfway between them; rises across longer gaps,
    /// such as while the app was closed, are left out. Every weekday and hour gets a cell, even when it's empty.
    static func hourlyRhythm(_ samples: [UsageSample], days: Int, endingOn end: Date, calendar: Calendar) -> [RhythmCell] {
        let firstDay = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: calendar.startOfDay(for: end)) ?? end
        var totals: [Int: Double] = [:]
        var previous: (value: Double, reset: Date?, at: Date)?
        for sample in samples.sorted(by: { $0.at < $1.at }) {
            guard let value = sample.weekly else { continue }
            defer { previous = (value, sample.weeklyReset, sample.at) }
            guard let last = previous, sample.at >= firstDay, sample.at <= end.addingTimeInterval(60),
                  sample.at.timeIntervalSince(last.at) <= rhythmMaximumGap else { continue }
            let points = rise(from: last, to: value, reset: sample.weeklyReset)
            guard points > 0 else { continue }
            let middle = last.at.addingTimeInterval(sample.at.timeIntervalSince(last.at) / 2)
            let parts = calendar.dateComponents([.weekday, .hour], from: middle)
            guard let weekday = parts.weekday, let hour = parts.hour else { continue }
            totals[RhythmCell.key(weekday: weekday, hour: hour), default: 0] += points
        }
        return (1...7).flatMap { weekday in
            (0..<24).map { hour in
                RhythmCell(weekday: weekday, hour: hour, points: totals[RhythmCell.key(weekday: weekday, hour: hour)] ?? 0)
            }
        }
    }
}

/// One hour of one weekday in the "when you use Claude" heatmap.
struct RhythmCell: Identifiable, Equatable, Sendable {
    /// 1 is Sunday and 7 is Saturday, as in Calendar.
    let weekday: Int
    /// 0 to 23.
    let hour: Int
    /// Weekly limit points used in this hour, added up across the range.
    let points: Double

    var id: Int { Self.key(weekday: weekday, hour: hour) }

    static func key(weekday: Int, hour: Int) -> Int { weekday * 24 + hour }
}

// MARK: - The history file

/// Keeps readings in one private file (one JSON line per reading) inside the app's own sandbox container.
struct UsageHistoryStore: Sendable {
    let directory: URL

    var fileURL: URL { directory.appendingPathComponent("usage-history.jsonl") }

    /// Application Support inside the app's sandbox container. Only this app can read it; the widget can't.
    static var appDefault: UsageHistoryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return UsageHistoryStore(directory: base.appendingPathComponent("ClaudeUsageWidget", isDirectory: true))
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    func append(_ sample: UsageSample) throws {
        var line = try Self.encoder().encode(sample)
        line.append(0x0A)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: line, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Readings within the retention period, oldest first. Damaged lines are skipped.
    func load(now: Date, retention: TimeInterval = HistoryPolicy.retention) -> [UsageSample] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = Self.decoder()
        let oldest = now.addingTimeInterval(-retention)
        let newest = now.addingTimeInterval(86_400)
        return data.split(separator: 0x0A)
            .compactMap { try? decoder.decode(UsageSample.self, from: Data($0)) }
            .filter { $0.at >= oldest && $0.at <= newest }
            .sorted { $0.at < $1.at }
    }

    /// Rewrites the file with only readings inside the retention period.
    func compact(now: Date, retention: TimeInterval = HistoryPolicy.retention) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let kept = load(now: now, retention: retention)
        let encoder = Self.encoder()
        var data = Data()
        for sample in kept {
            data.append(try encoder.encode(sample))
            data.append(0x0A)
        }
        let temporary = directory.appendingPathComponent(".usage-history-\(UUID().uuidString).jsonl")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporary)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
