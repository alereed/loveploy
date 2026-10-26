import Foundation

// Time and tokens per Claude Code session, read from the transcripts on this Mac, so they can
// be added up per billing project: how long a project took (across every window working on it)
// and what its tokens are worth at API prices.

/// Tokens of one model.
public struct TokenCount: Codable, Equatable, Sendable {
    public var input = 0, output = 0, cacheWrite = 0, cacheRead = 0, messages = 0

    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, messages: Int = 0) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.messages = messages
    }

    public var total: Int { input + output + cacheWrite + cacheRead }

    public static func + (a: Self, b: Self) -> Self {
        Self(input: a.input + b.input, output: a.output + b.output, cacheWrite: a.cacheWrite + b.cacheWrite,
             cacheRead: a.cacheRead + b.cacheRead, messages: a.messages + b.messages)
    }

    /// US dollars at the model's API price.
    public func dollars(model: String) -> Double {
        let price = ModelPrice.for(model: model)
        return (Double(input) * price.input + Double(output) * price.output
            + Double(cacheWrite) * price.cacheWrite + Double(cacheRead) * price.cacheRead) / 1_000_000
    }
}

/// Anthropic API list prices, US dollars per million tokens. A subscription doesn't charge per
/// token; this is what the same work would cost through the API, a fair basis for billing.
public struct ModelPrice: Equatable, Sendable {
    public let input: Double, output: Double, cacheWrite: Double, cacheRead: Double

    init(input: Double, output: Double, cacheRead: Double? = nil) {
        self.input = input
        self.output = output
        cacheWrite = input * 1.25          // 5-minute cache writes
        self.cacheRead = cacheRead ?? input * 0.1
    }

    /// Most specific prefix first.
    static let table: [(prefix: String, price: ModelPrice)] = [
        ("claude-fable-5", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-mythos-5", ModelPrice(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-opus-5-5", ModelPrice(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-8", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-7", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-6", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4-5", ModelPrice(input: 5, output: 25)),
        ("claude-opus-4", ModelPrice(input: 15, output: 75)),
        ("claude-sonnet-5-5", ModelPrice(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-5", ModelPrice(input: 2, output: 10)),
        ("claude-sonnet-4", ModelPrice(input: 3, output: 15)),
        ("claude-haiku-5-5", ModelPrice(input: 0.10, output: 0.50)),
        ("claude-haiku-4", ModelPrice(input: 1, output: 5)),
        ("claude-3-5-haiku", ModelPrice(input: 0.80, output: 4)),
    ]

    /// Unknown models are priced like the current Opus.
    public static func `for`(model: String) -> ModelPrice {
        let name = model.lowercased()
        return table.first { name.hasPrefix($0.prefix) || name.contains($0.prefix) }?.price ?? ModelPrice(input: 4, output: 20, cacheRead: 0.20)
    }
}

/// One session's activity on one day.
public struct DayActivity: Codable, Equatable, Sendable {
    /// 5-minute slots (local time) with a message from you or Claude.
    public var slots: Set<Int> = []
    /// Model → tokens.
    public var tokens: [String: TokenCount] = [:]

    public init(slots: Set<Int> = [], tokens: [String: TokenCount] = [:]) {
        self.slots = slots
        self.tokens = tokens
    }
}

public struct SessionActivity: Codable, Equatable, Sendable {
    /// The folder the session ran in.
    public var cwd: String?
    /// "yyyy-MM-dd" → activity.
    public var days: [String: DayActivity] = [:]

    public init(cwd: String? = nil, days: [String: DayActivity] = [:]) {
        self.cwd = cwd
        self.days = days
    }
}

/// Everything read from the transcripts, kept in `ledger.json` so each scan only reads what's new.
public struct UsageLedger: Codable, Equatable, Sendable {
    public var offsets: [String: UInt64] = [:]
    /// Session id → activity.
    public var sessions: [String: SessionActivity] = [:]
    /// Replies already counted (a reply copied into two transcripts counts once).
    var seen: Set<String> = []

    public init() {}

    // MARK: Reading

    public mutating func scan(roots: [URL], calendar: Calendar = .current) {
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
                offsets[path] = read(file, from: offset, session: Self.sessionID(of: file), calendar: calendar)
            }
        }
        // Claude Code deletes old transcripts; what they held stays, their offsets go.
        offsets = offsets.filter { present.contains($0.key) }
    }

    /// `<id>.jsonl`, or `<id>/subagents/agent-*.jsonl` (subagents bill to their session).
    public static func sessionID(of file: URL) -> String {
        let parent = file.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" { return parent.deletingLastPathComponent().lastPathComponent }
        return file.deletingPathExtension().lastPathComponent
    }

    private mutating func read(_ file: URL, from offset: UInt64, session: String, calendar: Calendar) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return offset }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        var position = offset
        var carry = Data()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            carry.append(chunk)
            var start = carry.startIndex
            while let newline = carry[start...].firstIndex(of: 0x0A) {
                ingest(carry[start..<newline], session: session, calendar: calendar)
                position += UInt64(newline - start + 1)
                start = carry.index(after: newline)
            }
            carry = Data(carry[start...])
        }
        return position
    }

    mutating func ingest(_ line: Data, session: String, calendar: Calendar) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String, type == "user" || type == "assistant",
              let stamp = (object["timestamp"] as? String).flatMap(parseISO8601) else { return }
        var activity = sessions[session] ?? SessionActivity()
        if activity.cwd == nil, let cwd = object["cwd"] as? String, !cwd.isEmpty { activity.cwd = cwd }
        let day = DevHours.dayKey(stamp, calendar: calendar)
        let parts = calendar.dateComponents([.hour, .minute], from: stamp)
        var today = activity.days[day] ?? DayActivity()
        today.slots.insert(((parts.hour ?? 0) * 60 + (parts.minute ?? 0)) / DevHours.slotMinutes)

        if let message = object["message"] as? [String: Any], let usage = message["usage"] as? [String: Any],
           let model = message["model"] as? String, model != "<synthetic>" {
            let key = (message["id"] as? String ?? "") + "|" + (object["requestId"] as? String ?? "")
            if key == "|" || seen.insert(key).inserted {
                let count = TokenCount(
                    input: usage["input_tokens"] as? Int ?? 0,
                    output: usage["output_tokens"] as? Int ?? 0,
                    cacheWrite: usage["cache_creation_input_tokens"] as? Int ?? 0,
                    cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                    messages: 1
                )
                today.tokens[model] = (today.tokens[model] ?? TokenCount()) + count
            }
        }
        activity.days[day] = today
        sessions[session] = activity
    }

    // MARK: Totals

    /// Development time of every session, for the panel.
    public var devHours: DevHours {
        var hours = DevHours()
        for activity in sessions.values {
            for (day, today) in activity.days { hours.slots[day, default: []].formUnion(today.slots) }
        }
        return hours
    }
}

/// A client project to bill: the sessions assigned to it from the group windows, plus any
/// session that ran inside one of its folders.
public struct BillingProject: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var folders: [String]
    /// Per hour, in `currency`; nil when you don't bill by the hour.
    public var hourlyRate: Double?
    public var currency: String

    public init(id: UUID = UUID(), name: String, folders: [String] = [], hourlyRate: Double? = nil, currency: String = "MXN") {
        self.id = id
        self.name = name
        self.folders = folders
        self.hourlyRate = hourlyRate
        self.currency = currency
    }

    enum CodingKeys: String, CodingKey { case id, name, folders, hourlyRate, currency }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Proyecto"
        folders = (try? c.decodeIfPresent([String].self, forKey: .folders)) ?? []
        hourlyRate = try? c.decodeIfPresent(Double.self, forKey: .hourlyRate)
        currency = (try? c.decodeIfPresent(String.self, forKey: .currency)) ?? "MXN"
    }

    func owns(folder: String) -> Int? {
        folders.compactMap { root -> Int? in
            let root = root.hasSuffix("/") ? String(root.dropLast()) : root
            return folder == root || folder.hasPrefix(root + "/") ? root.count : nil
        }.max()
    }
}

/// One project's totals over a period.
public struct ProjectTotals: Equatable, Sendable {
    public var projectID: UUID?
    /// Wall-clock development time: a slot counts once however many windows were busy.
    public var minutes = 0
    /// Every session's time added up (two windows for an hour = two hours).
    public var sessionMinutes = 0
    public var tokens: [String: TokenCount] = [:]
    public var sessions = 0
    public var lastActive: String?

    public var dollars: Double { tokens.reduce(0) { $0 + $1.value.dollars(model: $1.key) } }
    public var tokenTotal: Int { tokens.values.reduce(0) { $0 + $1.total } }

    /// Hours × rate, when the project has one.
    public func fee(rate: Double?) -> Double? { rate.map { Double(minutes) / 60 * $0 } }
}

public enum ProjectReport {
    /// Which project each session belongs to: an explicit assignment wins, then the project
    /// owning the deepest folder the session ran in.
    public static func owner(session: String, cwd: String?, assignments: [String: UUID], projects: [BillingProject]) -> UUID? {
        if let id = assignments[session], projects.contains(where: { $0.id == id }) { return id }
        guard let cwd else { return nil }
        return projects.compactMap { project in project.owns(folder: cwd).map { (project.id, $0) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// Totals per project for days `from...to` ("yyyy-MM-dd", either open). Sessions of no
    /// project go under a nil `projectID`.
    public static func build(ledger: UsageLedger, projects: [BillingProject], assignments: [String: UUID],
                             from: String? = nil, to: String? = nil) -> [ProjectTotals] {
        var totals: [UUID?: ProjectTotals] = [:]
        var slots: [UUID?: [String: Set<Int>]] = [:]
        for (session, activity) in ledger.sessions {
            let project = owner(session: session, cwd: activity.cwd, assignments: assignments, projects: projects)
            var entry = totals[project] ?? ProjectTotals(projectID: project)
            var counted = false
            for (day, today) in activity.days {
                if let from, day < from { continue }
                if let to, day > to { continue }
                counted = true
                entry.sessionMinutes += today.slots.count * DevHours.slotMinutes
                slots[project, default: [:]][day, default: []].formUnion(today.slots)
                for (model, count) in today.tokens { entry.tokens[model] = (entry.tokens[model] ?? TokenCount()) + count }
                if entry.lastActive.map({ day > $0 }) ?? true { entry.lastActive = day }
            }
            if counted {
                entry.sessions += 1
                totals[project] = entry
            }
        }
        for (project, days) in slots {
            totals[project]?.minutes = days.values.reduce(0) { $0 + $1.count } * DevHours.slotMinutes
        }
        // Every project shows, even with nothing yet; then the unassigned bucket.
        var result = projects.map { totals[$0.id] ?? ProjectTotals(projectID: $0.id) }
        if let loose = totals[nil] { result.append(loose) }
        return result
    }

    /// One row per project and model, for a spreadsheet or an invoice.
    public static func csv(_ totals: [ProjectTotals], projects: [BillingProject], period: String) -> String {
        var lines = ["periodo,proyecto,horas,horas_sesiones,sesiones,modelo,tokens_entrada,tokens_salida,tokens_cache_escritura,tokens_cache_lectura,valor_tokens_usd,tarifa_hora,moneda,honorarios"]
        func field(_ text: String) -> String {
            text.contains(",") || text.contains("\"") ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        for entry in totals {
            let project = projects.first { $0.id == entry.projectID }
            let name = project?.name ?? "Sin proyecto"
            let hours = String(format: "%.2f", Double(entry.minutes) / 60)
            let sessionHours = String(format: "%.2f", Double(entry.sessionMinutes) / 60)
            let rate = project?.hourlyRate.map { String(format: "%.2f", $0) } ?? ""
            let fee = entry.fee(rate: project?.hourlyRate).map { String(format: "%.2f", $0) } ?? ""
            let models = entry.tokens.isEmpty ? [("", TokenCount())] : entry.tokens.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
            for (index, (model, count)) in models.enumerated() {
                let first = index == 0
                lines.append([
                    field(period), field(name), first ? hours : "", first ? sessionHours : "", first ? String(entry.sessions) : "",
                    model, String(count.input), String(count.output), String(count.cacheWrite), String(count.cacheRead),
                    String(format: "%.2f", model.isEmpty ? 0 : count.dollars(model: model)),
                    first ? rate : "", first ? (project?.currency ?? "") : "", first ? fee : "",
                ].joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// JSON files next to state.json: the ledger and the projects.
public struct JSONFile<Value: Codable>: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public init(named name: String) {
        self.fileURL = StateStore.default().fileURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    public func load() -> Value? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
