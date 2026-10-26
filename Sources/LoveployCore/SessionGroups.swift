import Foundation

// Saved groups of Claude Code sessions that open together in one split window: local sessions
// (resumed with `claude --resume` in a terminal pane) and cloud sessions (claude.ai/code in a web
// pane), from any account, up to eight per window.

/// How a group window splits its panes.
public enum PaneLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    /// A balanced grid: 1, 2, 3 side by side, then two rows.
    case grid
    /// Everything side by side.
    case columns
    /// Everything stacked.
    case rows
    /// The first pane large on the left, the rest stacked on the right.
    case focus

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .grid: return "Cuadrícula"
        case .columns: return "Columnas"
        case .rows: return "Filas"
        case .focus: return "Uno grande"
        }
    }

    public var symbol: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .columns: return "rectangle.split.3x1"
        case .rows: return "rectangle.split.1x2"
        case .focus: return "rectangle.lefthalf.inset.filled"
        }
    }

    /// How many panes go in each row, top to bottom. `focus` is drawn by the view: the first
    /// pane on the left, `rows(for:)` describes the stack on the right.
    public func rows(for count: Int) -> [Int] {
        guard count > 0 else { return [] }
        switch self {
        case .columns: return [count]
        case .rows: return Array(repeating: 1, count: count)
        case .focus: return Array(repeating: 1, count: max(0, count - 1))
        case .grid:
            if count <= 3 { return [count] }
            let top = (count + 1) / 2
            return [top, count - top]
        }
    }
}

/// One pane of a group window.
public struct SessionPane: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A Claude Code session on this Mac, in a terminal.
        case local
        /// A session on claude.ai/code, in a web view.
        case cloud
        /// A claude.ai page in one of your own Chrome windows (or an installed Chrome app),
        /// with your Chrome sign-in, placed over the pane's spot when the group opens.
        case chrome
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    /// The account: a profile id from the Claude accounts list. Picks the color, and for cloud
    /// panes the claude.ai sign-in.
    public var account: String?
    /// Local: the session to resume. nil starts a new session in `directory`.
    public var sessionID: String?
    /// Local: the folder Claude Code runs in.
    public var directory: String?
    /// Local: `CLAUDE_CONFIG_DIR` for the account; nil uses `~/.claude`.
    public var configDir: String?
    /// Cloud: the session's address.
    public var url: String?
    /// Local: `sessionID` hasn't been used yet, so the pane starts it with `--session-id`
    /// (and resumes it from then on). Knowing the id up front lets a new session be billed.
    public var startsNew: Bool
    /// The billing project this pane's time and tokens go to (nil: the group's).
    public var project: UUID?

    public init(
        id: UUID = UUID(), kind: Kind, title: String, account: String? = nil, sessionID: String? = nil,
        directory: String? = nil, configDir: String? = nil, url: String? = nil, startsNew: Bool = false, project: UUID? = nil
    ) {
        self.startsNew = startsNew
        self.project = project
        self.id = id
        self.kind = kind
        self.title = title
        self.account = account
        self.sessionID = sessionID
        self.directory = directory
        self.configDir = configDir
        self.url = url
    }

    public static func local(_ session: LocalSession, account: String?) -> SessionPane {
        SessionPane(kind: .local, title: session.title, account: account, sessionID: session.id,
                    directory: session.cwd, configDir: session.configDir)
    }

    /// A cloud pane from a pasted address. Only claude.ai pages.
    public static func cloud(_ address: String, title: String?, account: String?, kind: Kind = .cloud) -> SessionPane? {
        guard let url = ClaudeLink.url(address) else { return nil }
        let name = title.map(ClaudeLink.cleanTitle).flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultTitle(for: url)
        return SessionPane(kind: kind == .local ? .cloud : kind, title: name, account: account, url: url.absoluteString)
    }

    static func defaultTitle(for url: URL) -> String {
        let last = url.lastPathComponent
        if last.hasPrefix("session_") { return "Sesión " + last.dropFirst("session_".count).prefix(6) }
        return last.isEmpty || last == "code" ? "Claude Code" : last
    }

    /// What the terminal pane runs (through the user's login shell, so `claude` is on the PATH).
    public var shellCommand: String {
        var parts: [String] = []
        if let directory, !directory.isEmpty {
            parts.append("cd \(Self.quote(directory))")
        }
        if let sessionID, !sessionID.isEmpty {
            parts.append("exec claude \(startsNew ? "--session-id" : "--resume") \(Self.quote(sessionID))")
        } else {
            parts.append("exec claude")
        }
        return parts.joined(separator: " && ")
    }

    /// Extra environment for the terminal pane: the account's Claude Code sign-in.
    public var environment: [String: String] {
        guard let configDir, !configDir.isEmpty else { return [:] }
        return ["CLAUDE_CONFIG_DIR": configDir]
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    enum CodingKeys: String, CodingKey { case id, kind, title, account, sessionID, directory, configDir, url, startsNew, project }

    // Lenient: a pane saved by another version still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .local
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Sesión"
        account = try? c.decodeIfPresent(String.self, forKey: .account)
        sessionID = try? c.decodeIfPresent(String.self, forKey: .sessionID)
        directory = try? c.decodeIfPresent(String.self, forKey: .directory)
        configDir = try? c.decodeIfPresent(String.self, forKey: .configDir)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        startsNew = (try? c.decodeIfPresent(Bool.self, forKey: .startsNew)) ?? false
        project = try? c.decodeIfPresent(UUID.self, forKey: .project)
    }
}

/// claude.ai addresses: which ones panes accept, and how to tell two of them are the same page.
public enum ClaudeLink {
    /// An https claude.ai address, or nil.
    public static func url(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme == "https",
              let host = url.host, host == "claude.ai" || host.hasSuffix(".claude.ai") else { return nil }
        return url
    }

    /// A Claude Code session (claude.ai/code/session_…).
    public static func isCodeSession(_ address: String) -> Bool {
        url(address)?.path.contains("/code/session_") ?? false
    }

    /// Same page: same host and path, whatever the query or fragment.
    public static func samePage(_ a: String, _ b: String) -> Bool {
        guard let x = url(a), let y = url(b) else { return false }
        let trim: (String) -> String = { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        return x.host == y.host && trim(x.path) == trim(y.path)
    }

    /// Browser titles end in " - Claude" or " | Claude".
    public static func cleanTitle(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [" - Claude", " | Claude", " – Claude", " — Claude"] where text.hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
        }
        return text == "Claude" ? "" : text
    }
}

/// A tab of Google Chrome, as Loveploy's AppleScript lists them: one line per tab,
/// "windowID<TAB>tabIndex<TAB>url<TAB>title".
public struct ChromeTab: Hashable, Sendable, Identifiable {
    public let windowID: Int
    public let tabIndex: Int
    public let url: String
    public let title: String
    public var id: String { "\(windowID)-\(tabIndex)" }

    public init(windowID: Int, tabIndex: Int, url: String, title: String) {
        self.windowID = windowID
        self.tabIndex = tabIndex
        self.url = url
        self.title = title
    }

    public static func parse(_ output: String) -> [ChromeTab] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let window = Int(parts[0]), let tab = Int(parts[1]) else { return nil }
            return ChromeTab(windowID: window, tabIndex: tab, url: parts[2], title: parts.count > 3 ? parts[3] : "")
        }
    }

    /// Tabs on claude.ai, Claude Code sessions first, one per page.
    public static func claudeTabs(_ tabs: [ChromeTab]) -> [ChromeTab] {
        var seen: [String] = []
        let found = tabs.filter { tab in
            guard ClaudeLink.url(tab.url) != nil, !seen.contains(where: { ClaudeLink.samePage($0, tab.url) }) else { return false }
            seen.append(tab.url)
            return true
        }
        return found.filter { ClaudeLink.isCodeSession($0.url) } + found.filter { !ClaudeLink.isCodeSession($0.url) }
    }
}

/// A saved set of up to eight sessions and how its window splits them.
public struct SessionGroup: Codable, Identifiable, Hashable, Sendable {
    public static let maxPanes = 8

    public var id: UUID
    public var name: String
    public private(set) var panes: [SessionPane]
    public var layout: PaneLayout
    /// Opened by "Abrir al iniciar" with the app.
    public var openAtLaunch: Bool
    /// A global key that brings the group's window forward, wherever it is.
    public var shortcut: GroupShortcut?
    /// The billing project for panes that don't name their own.
    public var project: UUID?

    public init(id: UUID = UUID(), name: String, panes: [SessionPane] = [], layout: PaneLayout = .grid, openAtLaunch: Bool = false, shortcut: GroupShortcut? = nil, project: UUID? = nil) {
        self.project = project
        self.id = id
        self.name = name
        self.panes = Array(panes.prefix(Self.maxPanes))
        self.layout = layout
        self.openAtLaunch = openAtLaunch
        self.shortcut = shortcut
    }

    public var isFull: Bool { panes.count >= Self.maxPanes }

    /// The project a pane bills to: its own, else the group's.
    public func project(of pane: SessionPane) -> UUID? { pane.project ?? project }

    /// Adds a pane at the end. False when the group already has eight.
    @discardableResult
    public mutating func add(_ pane: SessionPane) -> Bool {
        guard !isFull else { return false }
        panes.append(pane)
        return true
    }

    public mutating func remove(_ id: UUID) {
        panes.removeAll { $0.id == id }
    }

    public mutating func replace(_ pane: SessionPane) {
        if let index = panes.firstIndex(where: { $0.id == pane.id }) { panes[index] = pane }
    }

    /// Moves a pane one place earlier (-1) or later (+1).
    public mutating func move(_ id: UUID, by offset: Int) {
        guard let index = panes.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard panes.indices.contains(target) else { return }
        panes.swapAt(index, target)
    }

    enum CodingKeys: String, CodingKey { case id, name, panes, layout, openAtLaunch, shortcut, project }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Grupo"
        panes = Array(((try? c.decodeIfPresent([SessionPane].self, forKey: .panes)) ?? []).prefix(Self.maxPanes))
        layout = (try? c.decodeIfPresent(PaneLayout.self, forKey: .layout)) ?? .grid
        openAtLaunch = (try? c.decodeIfPresent(Bool.self, forKey: .openAtLaunch)) ?? false
        shortcut = try? c.decodeIfPresent(GroupShortcut.self, forKey: .shortcut)
        project = try? c.decodeIfPresent(UUID.self, forKey: .project)
    }
}

/// A key and its modifiers, as Carbon's RegisterEventHotKey takes them.
public struct GroupShortcut: Codable, Hashable, Sendable {
    // Carbon modifier bits (Events.h), so the UI and the hot key agree without importing Carbon here.
    public static let command = 0x100, shift = 0x200, option = 0x800, control = 0x1000

    /// Virtual key code (kVK_…).
    public var keyCode: Int
    /// Carbon modifier mask.
    public var modifiers: Int
    /// What the key shows, e.g. "1" or "G".
    public var key: String

    public init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// A global shortcut needs ⌘, ⌃ or ⌥; ⇧ alone would eat ordinary typing.
    public var isUsable: Bool {
        modifiers & (Self.command | Self.control | Self.option) != 0 && !key.isEmpty
    }

    /// "⌃⌥⌘1", in the order macOS menus use.
    public var display: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + key.uppercased()
    }

    /// ⌃⌥⌘ and the first digit 1–9 no other group uses (the profiles already use ⌃⌥ + digit).
    public static func suggestion(taken: [GroupShortcut?]) -> GroupShortcut? {
        let digitCodes = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]   // kVK_ANSI_1 … kVK_ANSI_9
        let mods = command | option | control
        for (index, code) in digitCodes.enumerated() {
            let candidate = GroupShortcut(keyCode: code, modifiers: mods, key: String(index + 1))
            if !taken.contains(where: { $0?.keyCode == code && $0?.modifiers == mods }) { return candidate }
        }
        return nil
    }

    /// Same key and modifiers (the label doesn't matter).
    public func sameKeys(as other: GroupShortcut?) -> Bool {
        guard let other else { return false }
        return keyCode == other.keyCode && modifiers == other.modifiers
    }
}

/// Reads and writes the saved groups (`~/Library/Application Support/Loveploy/groups.json`).
public struct SessionGroupStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func `default`() -> SessionGroupStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return SessionGroupStore(fileURL: base.appendingPathComponent("Loveploy/groups.json"))
    }

    public func load() -> [SessionGroup] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([SessionGroup].self, from: data)) ?? []
    }

    public func save(_ groups: [SessionGroup]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(groups).write(to: fileURL, options: .atomic)
    }
}

/// A Claude Code session found on this Mac.
public struct LocalSession: Identifiable, Hashable, Sendable {
    /// The session id (`claude --resume <id>`).
    public let id: String
    public let transcript: String
    public let cwd: String
    public let title: String
    public let modified: Date
    /// `CLAUDE_CONFIG_DIR` of the account it belongs to; nil for `~/.claude`.
    public let configDir: String?

    public init(id: String, transcript: String, cwd: String, title: String, modified: Date, configDir: String?) {
        self.id = id
        self.transcript = transcript
        self.cwd = cwd
        self.title = title
        self.modified = modified
        self.configDir = configDir
    }

    public var project: String { URL(fileURLWithPath: cwd).lastPathComponent }
}

/// Lists Claude Code sessions from a config folder's `projects/` transcripts.
public enum LocalSessionScanner {
    /// - Parameters:
    ///   - projectsRoot: `<config>/projects`.
    ///   - configDir: the account's `CLAUDE_CONFIG_DIR` (nil for `~/.claude`).
    ///   - titles: names Claude gave sessions elsewhere (the desktop app's list), by session id.
    public static func scan(projectsRoot: URL, configDir: String?, titles: [String: String] = [:], limit: Int = 300) -> [LocalSession] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: projectsRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var files: [(URL, Date)] = []
        for case let file as URL in enumerator where file.pathExtension == "jsonl" {
            // Subagent transcripts belong to their parent session.
            if file.path.contains("/subagents/") || file.lastPathComponent.hasPrefix("agent-") { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            files.append((file, modified))
        }
        files.sort { $0.1 > $1.1 }

        var sessions: [LocalSession] = []
        for (file, modified) in files {
            if sessions.count >= limit { break }
            let id = file.deletingPathExtension().lastPathComponent
            let summary = summary(of: file)
            guard let title = titles[id] ?? summary.title, let cwd = summary.cwd else { continue }
            sessions.append(LocalSession(id: id, transcript: file.path, cwd: cwd, title: title, modified: modified, configDir: configDir))
        }
        return sessions
    }

    /// The session's folder and a title: its custom title, or the first thing the user typed.
    static func summary(of file: URL) -> (title: String?, cwd: String?) {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return (nil, nil) }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 << 10)) ?? Data()
        var first: String?, custom: String?, cwd: String?
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let title = object["customTitle"] as? String, !title.isEmpty { custom = title }
            if object["type"] as? String == "summary", let summary = object["summary"] as? String, custom == nil { custom = summary }
            if cwd == nil, let value = object["cwd"] as? String, !value.isEmpty { cwd = value }
            if first == nil, object["type"] as? String == "user", (object["isMeta"] as? Bool) != true,
               let text = userText(object["message"]), !text.hasPrefix("<") {
                first = String(text.prefix(90)).replacingOccurrences(of: "\n", with: " ")
            }
            if custom != nil && first != nil && cwd != nil { break }
        }
        return (custom ?? first, cwd)
    }

    static func userText(_ message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        if let text = message["content"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let blocks = message["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
