import Foundation

/// Development time from Claude Code's transcripts: every 5-minute slot in which you wrote to
/// Claude or Claude answered counts as worked. Reads each transcript only from where it left off.
public struct DevHours: Codable, Equatable, Sendable {
    public static let slotMinutes = 5

    /// Transcript path → bytes already read.
    public var offsets: [String: UInt64] = [:]
    /// "yyyy-MM-dd" (local) → the day's active slots.
    public var slots: [String: Set<Int>] = [:]

    public init() {}

    public func minutes(on day: Date, calendar: Calendar = .current) -> Int {
        (slots[Self.dayKey(day, calendar: calendar)]?.count ?? 0) * Self.slotMinutes
    }

    /// Today and the `days - 1` days before it.
    public func minutes(lastDays days: Int, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let today = calendar.startOfDay(for: now)
        return (0..<max(days, 0)).reduce(0) { sum, back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { return sum }
            return sum + minutes(on: day, calendar: calendar)
        }
    }

    /// Since the start of this week (the calendar's first weekday).
    public func minutesThisWeek(now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return 0 }
        let days = (calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day ?? 0) + 1
        return minutes(lastDays: days, now: now, calendar: calendar)
    }

    /// Marks the slot of a transcript line, if it's a message from you or Claude.
    mutating func ingest(line: Substring, calendar: Calendar) {
        guard line.contains(#""type":"user""#) || line.contains(#""type":"assistant""#),
              let range = line.range(of: #""timestamp":""#) else { return }
        let rest = line[range.upperBound...]
        guard let end = rest.firstIndex(of: "\""), let date = Self.parseTimestamp(String(rest[..<end])) else { return }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let slot = ((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / Self.slotMinutes
        slots[Self.dayKey(date, calendar: calendar), default: []].insert(slot)
    }

    /// Reads what each transcript under `roots` gained since last time, and forgets days
    /// older than `keepDays`.
    public mutating func scan(roots: [URL], keepDays: Int = 120, now: Date = Date(), calendar: Calendar = .current) {
        let fm = FileManager.default
        var present = Set<String>()
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let file as URL in walker where file.pathExtension == "jsonl" {
                let path = file.path
                present.insert(path)
                guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(UInt64.init) else { continue }
                var offset = offsets[path] ?? 0
                if size < offset { offset = 0 }
                guard size > offset else { continue }
                offsets[path] = read(file, from: offset, calendar: calendar)
            }
        }
        // Claude Code deletes old transcripts; their slots stay, their offsets go.
        offsets = offsets.filter { present.contains($0.key) }
        if let oldest = calendar.date(byAdding: .day, value: -keepDays, to: now) {
            let cutoff = Self.dayKey(oldest, calendar: calendar)
            slots = slots.filter { $0.key >= cutoff }
        }
    }

    private mutating func read(_ file: URL, from offset: UInt64, calendar: Calendar) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return offset }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        var position = offset
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            carry.append(chunk)
            var start = carry.startIndex
            while let newline = carry[start...].firstIndex(of: 0x0A) {
                let line = String(decoding: carry[start..<newline], as: UTF8.self)
                ingest(line: line[...], calendar: calendar)
                position += UInt64(newline - start + 1)
                start = carry.index(after: newline)
            }
            carry = Data(carry[start...])
        }
        return position
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func parseTimestamp(_ text: String) -> Date? {
        parseISO8601(text)
    }

    /// "3 h 20 min", "45 min", "0 min".
    public static func format(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// Keeps `DevHours` in `~/Library/Application Support/Loveploy/dev-hours.json`.
public struct DevHoursStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = StateStore.default().fileURL.deletingLastPathComponent().appendingPathComponent("dev-hours.json")) {
        self.fileURL = fileURL
    }

    public func load() -> DevHours {
        guard let data = try? Data(contentsOf: fileURL), let hours = try? JSONDecoder().decode(DevHours.self, from: data) else { return DevHours() }
        return hours
    }

    public func save(_ hours: DevHours) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(hours).write(to: fileURL, options: .atomic)
    }
}
