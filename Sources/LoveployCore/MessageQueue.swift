import Foundation

// Queued messages: what to send to a session, one after another, each time Claude finishes.

/// One step of a pane's queue.
public struct QueuedMessage: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Sent as soon as Claude finishes the previous task.
        case message
        /// Stops the queue here; what's below waits until you continue it.
        case pause
    }

    public var id: UUID
    public var kind: Kind
    public var text: String

    public init(id: UUID = UUID(), kind: Kind = .message, text: String = "") {
        self.id = id
        self.kind = kind
        self.text = text
    }

    public static func pause() -> QueuedMessage { QueuedMessage(kind: .pause) }

    enum CodingKeys: String, CodingKey { case id, kind, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .message
        text = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
    }
}

/// A pane's queue and whether it's running.
public struct MessageQueue: Codable, Hashable, Sendable {
    public var items: [QueuedMessage] = []
    /// Stopped by a pause step, by you, or because Claude needs you; `reason` says which.
    public var paused = false
    public var reason: String?

    public init(items: [QueuedMessage] = [], paused: Bool = false, reason: String? = nil) {
        self.items = items
        self.paused = paused
        self.reason = reason
    }

    /// Messages still to send (pauses not counted).
    public var pendingCount: Int { items.filter { $0.kind == .message }.count }

    /// Called when Claude is free: the message to send now, if any. A pause step at the top
    /// stops the queue (and is used up), so the next free moment sends nothing until you
    /// continue it.
    public mutating func takeNext() -> QueuedMessage? {
        guard !paused else { return nil }
        while let first = items.first {
            if first.kind == .pause {
                items.removeFirst()
                pause("Pausa en la cola")
                return nil
            }
            items.removeFirst()
            if !first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return first }
        }
        return nil
    }

    public mutating func pause(_ why: String) {
        paused = true
        reason = why
    }

    public mutating func resume() {
        paused = false
        reason = nil
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.sorted().map { items[$0] }
        var rest = items.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let before = source.filter { $0 < destination }.count
        rest.insert(contentsOf: moving, at: max(0, min(rest.count, destination - before)))
        items = rest
    }

    enum CodingKeys: String, CodingKey { case items, paused, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([QueuedMessage].self, forKey: .items)) ?? []
        paused = (try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? false
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
    }
}

/// Claude Code tells Blender Play when it's done, needs you, or got a new prompt, through
/// hooks passed with `--settings`: each event writes its JSON to a file named after the pane.
public enum ClaudeHooks {
    public enum Event: String, CaseIterable, Sendable {
        case stop = "Stop"
        case notification = "Notification"
        case prompt = "UserPromptSubmit"

        public var fileSuffix: String {
            switch self {
            case .stop: return "stop"
            case .notification: return "notify"
            case .prompt: return "prompt"
            }
        }
    }

    public static func file(_ event: Event, pane: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(pane.uuidString).\(event.fileSuffix).json")
    }

    /// The `--settings` JSON for a pane: every event copies Claude Code's payload to its file.
    public static func settings(pane: UUID, directory: URL) -> String {
        var hooks: [String: Any] = [:]
        for event in Event.allCases {
            let path = file(event, pane: pane, in: directory).path
            let command = "mkdir -p \"\(directory.path)\" && cat > \"\(path)\""
            hooks[event.rawValue] = [["hooks": [["type": "command", "command": command]]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether a Notification payload is Claude asking for permission or a choice (as opposed
    /// to "waiting for your input" after it finished).
    public static func needsYou(_ payload: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return false }
        if let type = object["notification_type"] as? String { return type != "idle_prompt" }
        let message = (object["message"] as? String ?? "").lowercased()
        return !message.contains("waiting for your input")
    }

    /// The transcript a Stop payload points to.
    public static func transcript(_ payload: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["transcript_path"] as? String
    }
}

/// Text for a terminal: bracketed paste keeps line breaks from sending early, then Return.
public func terminalSubmission(_ text: String) -> String {
    "\u{1B}[200~" + text + "\u{1B}[201~"
}

/// A shortcut that brings a Chrome window forward (the one showing `url`, opening it if it's
/// not open).
public struct ChromeShortcut: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var url: String
    public var shortcut: GroupShortcut?

    public init(id: UUID = UUID(), name: String, url: String, shortcut: GroupShortcut? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.shortcut = shortcut
    }

    /// The part of the address that identifies the page: scheme, host and path, without the
    /// query or fragment, so the tab is found even after it navigated a bit.
    public var match: String {
        guard var parts = URLComponents(string: url) else { return url }
        parts.query = nil
        parts.fragment = nil
        return parts.string ?? url
    }
}
