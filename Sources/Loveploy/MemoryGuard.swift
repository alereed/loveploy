import AppKit
import LoveployCore
import SwiftUI
import UserNotifications

// Loveploy: keeps the Mac's memory from filling up. Every loaded session is a process tree of
// its own (a WebKit process per page; Claude Code plus every MCP server and tool it starts per
// terminal), so what fills the RAM is how many are loaded at once. The guard measures each
// one, keeps at most N loaded (pausing the one used longest ago), pauses a session that grows
// past a size while you're not on it, and pauses everything in the background the moment
// macOS reports memory pressure.

@MainActor
final class MemoryGuard: ObservableObject {
    static let shared = MemoryGuard()

    /// Memory of each loaded pane's process tree, in bytes.
    @Published private(set) var paneBytes: [UUID: Int] = [:]
    /// How many processes each loaded pane has running.
    @Published private(set) var paneProcesses: [UUID: Int] = [:]
    /// Blender Play itself.
    @Published private(set) var appBytes = 0
    /// What the guard last did, for the Memory view.
    @Published private(set) var lastAction: String?

    private var timer: Timer?
    private var pressure: DispatchSourceMemoryPressure?
    private var sampling = false

    /// Sessions kept loaded at once across all groups (0 = no limit).
    static var limit: Int { UserDefaults.standard.object(forKey: "loveploy.maxLoaded") as? Int ?? 4 }
    /// A session you're not on is paused past this size, in GB (0 = never).
    static var heavyGB: Double { UserDefaults.standard.object(forKey: "loveploy.heavyGB") as? Double ?? 3 }

    func start() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 20, repeats: true) { _ in MainActor.assumeIsolated { MemoryGuard.shared.sample() } }
        RunLoop.main.add(timer!, forMode: .common)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            let critical = source?.data.contains(.critical) ?? false
            MainActor.assumeIsolated { MemoryGuard.shared.relieve(critical: critical) }
        }
        source.resume()
        pressure = source
    }

    /// Every loaded pane in every open group window.
    private func loaded() -> [(pane: SessionPane, controller: GroupWindowController)] {
        SessionGroups.shared.controllers.flatMap { controller -> [(SessionPane, GroupWindowController)] in
            guard let group = SessionGroups.shared.group(controller.groupID) else { return [] }
            return group.panes.filter { controller.hosts.existingView($0.id) != nil }.map { ($0, controller) }
        }
    }

    private func describe(_ items: [(pane: SessionPane, controller: GroupWindowController)]) -> [LoadedPane] {
        items.map { item in
            let hosts = item.controller.hosts
            let window = item.controller.window
            let group = SessionGroups.shared.group(item.controller.groupID)
            let front = window?.isKeyWindow == true
            // In front of you: any pane of the window you're in, or just the open ones in focus mode.
            let visible = group?.focusMode == true ? (hosts.expanded.contains(item.pane.id) || hosts.focused == item.pane.id) : true
            return LoadedPane(id: item.pane.id, lastUsed: hosts.lastUsed(item.pane), bytes: paneBytes[item.pane.id] ?? 0,
                              pausable: hosts.mayPause(item.pane, window: window), inUse: front && visible)
        }
    }

    /// Measures every loaded session, then pauses what's over the limits.
    func sample() {
        guard !sampling else { return }
        let items = loaded()
        var roots: [UUID: Int32] = [:]
        for item in items { roots[item.pane.id] = item.controller.hosts.processID(item.pane.id) }
        let own = ProcessInfo.processInfo.processIdentifier
        sampling = true
        Task.detached(priority: .utility) {
            let table = Self.processTable()
            await MainActor.run {
                let guardian = MemoryGuard.shared
                guardian.sampling = false
                guard let table else { return }
                var bytes: [UUID: Int] = [:], counts: [UUID: Int] = [:]
                for (pane, pid) in roots {
                    bytes[pane] = table.treeBytes(root: pid)
                    counts[pane] = table.treeCount(root: pid)
                }
                guardian.paneBytes = bytes
                guardian.paneProcesses = counts
                guardian.appBytes = (table.memoryKB[own] ?? 0) * 1024
                guardian.enforce()
            }
        }
    }

    nonisolated static func processTable() -> ProcessTable? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,rss="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessTable(psOutput: String(decoding: data, as: UTF8.self))
    }

    /// Too many loaded, or one grown too big while you're elsewhere: pause them.
    func enforce() {
        let items = loaded()
        let panes = describe(items)
        var toPause = MemoryPolicy.overLimit(panes, limit: Self.limit)
        let heavy = MemoryPolicy.heavy(panes, over: Int(Self.heavyGB * 1_073_741_824))
        toPause += heavy.filter { !toPause.contains($0) }
        guard !toPause.isEmpty else { return }
        let freed = pause(toPause, in: items)
        lastAction = "Pausé \(toPause.count) sesión(es) sin uso y liberé unos \(MemoryPolicy.format(freed))."
    }

    /// macOS says memory is running low: pause everything that isn't in front of you.
    func relieve(critical: Bool) {
        let items = loaded()
        let toPause = MemoryPolicy.underPressure(describe(items), critical: critical)
        URLCache.shared.removeAllCachedResponses()
        guard !toPause.isEmpty else { return }
        let freed = pause(toPause, in: items)
        lastAction = "macOS avisó de memoria \(critical ? "crítica" : "baja"): pausé \(toPause.count) sesión(es), unos \(MemoryPolicy.format(freed))."
        let content = UNMutableNotificationContent()
        content.title = "Memoria baja"
        content.body = "Blender Play pausó \(toPause.count) sesión(es) que no estabas usando. Vuelven con un clic."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Pauses panes by hand or by the rules above; returns the bytes they held.
    @discardableResult
    private func pause(_ ids: [UUID], in items: [(pane: SessionPane, controller: GroupWindowController)]) -> Int {
        var freed = 0
        for id in ids {
            guard let item = items.first(where: { $0.pane.id == id }) else { continue }
            let hosts = item.controller.hosts
            freed += paneBytes[id] ?? 0
            if hosts.expanded.count > 1 { hosts.expanded.remove(id) }
            hosts.sleep(id)
            paneBytes[id] = nil
            paneProcesses[id] = nil
        }
        return freed
    }

    func pauseNow(_ id: UUID) {
        pause([id], in: loaded())
    }

    /// Pauses every session that can be paused except the one you're typing in.
    func pauseAll() {
        let items = loaded()
        let ids = describe(items).filter(\.pausable).map(\.id)
        let freed = pause(ids, in: items)
        lastAction = "Pausé \(ids.count) sesión(es) y liberé unos \(MemoryPolicy.format(freed))."
    }

    var loadedCount: Int { loaded().count }
    var totalBytes: Int { paneBytes.values.reduce(appBytes, +) }
}

/// A pane's memory in its header, once it's worth showing.
struct PaneMemoryLabel: View {
    let pane: UUID
    @ObservedObject private var memory = MemoryGuard.shared

    var body: some View {
        if let bytes = memory.paneBytes[pane], bytes > 300 * 1_048_576 {
            Text(MemoryPolicy.format(bytes))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(bytes > 2 * 1_073_741_824 ? Color.orange : Color.secondary)
                .help("Memoria de esta sesión y todo lo que abrió (\(memory.paneProcesses[pane] ?? 1) procesos)")
        }
    }
}

/// The Memory section of the Blender Play window.
struct MemoryView: View {
    @ObservedObject private var memory = MemoryGuard.shared
    @ObservedObject private var groups = SessionGroups.shared
    @AppStorage("loveploy.maxLoaded") private var limit = 4
    @AppStorage("loveploy.heavyGB") private var heavyGB = 3.0

    private struct Row: Identifiable {
        let id: UUID
        let title: String
        let group: String
        let kind: SessionPane.Kind
        let bytes: Int
        let processes: Int
    }

    private var rows: [Row] {
        groups.groups.flatMap { group in
            group.panes.compactMap { pane -> Row? in
                guard let bytes = memory.paneBytes[pane.id] else { return nil }
                return Row(id: pane.id, title: pane.title, group: group.name, kind: pane.kind, bytes: bytes, processes: memory.paneProcesses[pane.id] ?? 1)
            }
        }
        .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Memoria").font(.title2.bold())
                Spacer()
                Button("Medir ahora") { memory.sample() }
                Button("Pausar todo lo que no uso") { memory.pauseAll() }.buttonStyle(.borderedProminent)
            }
            HStack(spacing: 18) {
                stat("Sesiones cargadas", "\(rows.count)")
                stat("Sus procesos", MemoryPolicy.format(rows.reduce(0) { $0 + $1.bytes }))
                stat("Blender Play", MemoryPolicy.format(memory.appBytes))
                stat("Total", MemoryPolicy.format(memory.totalBytes))
            }
            HStack(spacing: 14) {
                Picker("Máximo de sesiones cargadas a la vez", selection: $limit) {
                    ForEach([2, 3, 4, 6, 8], id: \.self) { Text("\($0)").tag($0) }
                    Text("Sin límite").tag(0)
                }
                .fixedSize()
                Picker("Pausar una sesión que no uso si pasa de", selection: $heavyGB) {
                    ForEach([1.5, 2.0, 3.0, 4.0, 6.0], id: \.self) { Text(String(format: "%g GB", $0)).tag($0) }
                    Text("Nunca").tag(0.0)
                }
                .fixedSize()
            }
            .font(.system(size: 12))
            if let action = memory.lastAction {
                Label(action, systemImage: "moon.zzz").font(.caption).foregroundStyle(.secondary)
            }
            List(rows) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.kind == .local ? "terminal" : row.kind == .preview ? "eye" : "globe").foregroundStyle(.secondary).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).lineLimit(1)
                        Text("\(row.group) · \(row.processes) proceso\(row.processes == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(MemoryPolicy.format(row.bytes)).monospacedDigit()
                        .foregroundStyle(row.bytes > 2 * 1_073_741_824 ? Color.orange : Color.primary)
                    Button("Pausar") { memory.pauseNow(row.id) }
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Text("Cada sesión cargada es un grupo de procesos aparte: una página de claude.ai es un proceso de WebKit, y una terminal es Claude Code más todos los servidores MCP y herramientas que arranca (por eso una sola terminal puede tener decenas de procesos). Blender Play mantiene cargadas como máximo las que elijas arriba: al pasar el tope pausa la que llevas más tiempo sin usar, y si macOS avisa que queda poca memoria pausa todas las que no tienes al frente. Nunca pausa la sesión en la que escribes, una donde Claude está trabajando ni una con mensajes en cola; las pausadas vuelven donde iban con un clic.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .onAppear { memory.sample() }
    }

    private func stat(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 18, weight: .semibold)).monospacedDigit()
            Text(name).font(.caption).foregroundStyle(.secondary)
        }
    }
}
