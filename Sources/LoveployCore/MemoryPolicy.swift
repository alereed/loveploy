import Foundation

// Keeping the Mac's memory from filling up: how much each session really uses (its process
// and everything it started), and which loaded sessions to pause when there are too many
// or the system runs low.

/// The system's processes, from `ps -axo pid=,ppid=,rss=`.
public struct ProcessTable: Sendable {
    /// pid → resident memory in KB.
    public let memoryKB: [Int32: Int]
    /// pid → its children.
    public let children: [Int32: [Int32]]
    /// pid → its parent.
    public let parents: [Int32: Int32]

    public init(psOutput: String) {
        var memory: [Int32: Int] = [:]
        var kids: [Int32: [Int32]] = [:]
        var up: [Int32: Int32] = [:]
        for line in psOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]), let rss = Int(fields[2]) else { continue }
            memory[pid] = rss
            kids[parent, default: []].append(pid)
            up[pid] = parent
        }
        memoryKB = memory
        children = kids
        parents = up
    }

    /// Memory of a process and all its descendants, in bytes (a Claude Code session with
    /// its MCP servers and tools; a page's WebKit process).
    public func treeBytes(root: Int32) -> Int {
        var total = 0
        var pending = [root]
        var seen = Set<Int32>()
        while let pid = pending.popLast() {
            guard seen.insert(pid).inserted else { continue }
            total += memoryKB[pid] ?? 0
            pending.append(contentsOf: children[pid] ?? [])
        }
        return total * 1024
    }

    /// Every process started, directly or not, by `root` (not `root` itself).
    public func descendants(of root: Int32) -> [Int32] {
        var found: [Int32] = []
        var pending = children[root] ?? []
        var seen: Set<Int32> = [root]
        while let pid = pending.popLast() {
            guard seen.insert(pid).inserted else { continue }
            found.append(pid)
            pending.append(contentsOf: children[pid] ?? [])
        }
        return found
    }

    /// How many processes hang from `root` (itself included).
    public func treeCount(root: Int32) -> Int {
        var count = 0
        var pending = [root]
        var seen = Set<Int32>()
        while let pid = pending.popLast() {
            guard seen.insert(pid).inserted, memoryKB[pid] != nil else { continue }
            count += 1
            pending.append(contentsOf: children[pid] ?? [])
        }
        return count
    }
}

/// A loaded session, as the memory guard sees it.
public struct LoadedPane: Hashable, Sendable {
    public let id: UUID
    public let lastUsed: Date
    public let bytes: Int
    /// Safe to pause now (not being typed in, not working, no queue, resumable).
    public let pausable: Bool
    /// Open and visible in the window you're in: paused only as a last resort.
    public let inUse: Bool

    public init(id: UUID, lastUsed: Date, bytes: Int = 0, pausable: Bool = true, inUse: Bool = false) {
        self.id = id
        self.lastUsed = lastUsed
        self.bytes = bytes
        self.pausable = pausable
        self.inUse = inUse
    }
}

public enum MemoryPolicy {
    /// Which sessions to pause so that at most `limit` stay loaded: the ones you used
    /// longest ago first, never the ones in use or that can't be paused.
    public static func overLimit(_ panes: [LoadedPane], limit: Int) -> [UUID] {
        guard limit > 0, panes.count > limit else { return [] }
        let candidates = panes.filter { $0.pausable && !$0.inUse }.sorted { $0.lastUsed < $1.lastUsed }
        return Array(candidates.prefix(panes.count - limit).map(\.id))
    }

    /// Sessions over `bytes` that you aren't using: one runaway page or session shouldn't
    /// take the Mac down.
    public static func heavy(_ panes: [LoadedPane], over bytes: Int, idleFor seconds: TimeInterval = 120, now: Date = Date()) -> [UUID] {
        guard bytes > 0 else { return [] }
        return panes.filter { $0.pausable && !$0.inUse && $0.bytes > bytes && now.timeIntervalSince($0.lastUsed) > seconds }.map(\.id)
    }

    /// When the system says memory is low: everything that can be paused except what you
    /// have open in front of you; under critical pressure, that too (the heaviest first).
    public static func underPressure(_ panes: [LoadedPane], critical: Bool) -> [UUID] {
        let background = panes.filter { $0.pausable && !$0.inUse }.map(\.id)
        guard critical else { return background }
        let front = panes.filter { $0.pausable && $0.inUse }.sorted { $0.bytes > $1.bytes }.map(\.id)
        return background + front
    }

    /// "1.4 GB", "820 MB".
    public static func format(_ bytes: Int) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}
