import AppKit
import LoveployCore
import SwiftTerm
import SwiftUI
import UserNotifications
import WebKit

// Queued messages per pane: each time Claude finishes, the next one is sent (with the same
// insert-and-send the dictation uses). In a Claude Code terminal, Claude Code itself says when
// it finished or needs you, through hooks Blender Play passes when it starts the session; on
// claude.ai the page's Stop button says it's working, and limits, errors or a dropped
// connection stop the queue.

enum WorkState: Equatable {
    case free
    case working
    case needsYou
    case blocked(String)
    case starting
    case notLoaded

    var label: String {
        switch self {
        case .free: return "Libre"
        case .working: return "Claude está trabajando"
        case .needsYou: return "Claude espera tu respuesta"
        case let .blocked(why): return why
        case .starting: return "Iniciando…"
        case .notLoaded: return "Abre el grupo para que la cola avance"
        }
    }
}

@MainActor
final class MessageQueues: ObservableObject {
    static let shared = MessageQueues()

    @Published private(set) var queues: [UUID: MessageQueue] = [:]
    @Published private(set) var states: [UUID: WorkState] = [:]
    private let file = JSONFile<[String: MessageQueue]>(named: "queues.json")
    private var timer: Timer?
    private var launched: [UUID: Date] = [:]
    private var sentAt: [UUID: Date] = [:]
    private var sawBusy: Set<UUID> = []
    private var checking: Set<UUID> = []

    static let hookDirectory: URL = StateStore.default().fileURL.deletingLastPathComponent().appendingPathComponent("hooks")

    private init() {
        for (key, queue) in file.load() ?? [:] {
            if let id = UUID(uuidString: key), !queue.items.isEmpty || queue.paused { queues[id] = queue }
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer(timeInterval: 1.5, repeats: true) { _ in MainActor.assumeIsolated { MessageQueues.shared.tick() } }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: Editing

    func queue(_ pane: UUID) -> MessageQueue { queues[pane] ?? MessageQueue() }
    func hasPending(_ pane: UUID) -> Bool { !(queues[pane]?.items.isEmpty ?? true) }

    func edit(_ pane: UUID, _ change: (inout MessageQueue) -> Void) {
        var queue = queues[pane] ?? MessageQueue()
        change(&queue)
        queues[pane] = queue.items.isEmpty && !queue.paused ? nil : queue
        save()
    }

    func add(_ text: String, to pane: UUID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        edit(pane) { $0.items.append(QueuedMessage(text: trimmed)) }
    }

    func addPause(to pane: UUID) { edit(pane) { $0.items.append(.pause()) } }

    /// Sends the first message now, whatever Claude is doing (your call).
    func sendNow(_ pane: UUID) {
        guard let (_, view) = SessionGroups.shared.loaded(pane) else { NSSound.beep(); return }
        var queue = self.queue(pane)
        queue.resume()
        guard let next = queue.takeNext() else { edit(pane) { $0 = queue }; return }
        edit(pane) { $0 = queue }
        send(next.text, to: pane, view: view)
    }

    private func save() {
        try? file.save(Dictionary(uniqueKeysWithValues: queues.map { ($0.key.uuidString, $0.value) }))
    }

    // MARK: Watching

    /// A terminal pane started Claude Code (it needs a few seconds before it takes input).
    func launched(_ pane: UUID) {
        launched[pane] = Date()
        sentAt[pane] = nil
    }

    /// The `--settings` for a terminal pane's Claude Code.
    static func hookSettings(pane: UUID) -> String {
        ClaudeHooks.settings(pane: pane, directory: hookDirectory)
    }

    private func tick() {
        for (pane, queue) in queues where !queue.items.isEmpty {
            guard let (model, view) = SessionGroups.shared.loaded(pane) else {
                states[pane] = .notLoaded
                continue
            }
            if let terminal = view as? TerminalView {
                let state = terminalState(pane)
                states[pane] = state
                act(pane, state: state, view: terminal)
            } else if let web = view as? WKWebView, !checking.contains(pane) {
                checking.insert(pane)
                web.evaluateJavaScript(Self.pageState) { result, _ in
                    MainActor.assumeIsolated {
                        let queues = MessageQueues.shared
                        queues.checking.remove(pane)
                        let state = queues.webState(pane, account: model.account, json: result as? String)
                        queues.states[pane] = state
                        queues.act(pane, state: state, view: web)
                    }
                }
            }
        }
    }

    private func act(_ pane: UUID, state: WorkState, view: NSView) {
        guard var queue = queues[pane], !queue.paused else { return }
        switch state {
        case .free:
            guard let next = queue.takeNext() else {
                edit(pane) { $0 = queue }
                if queue.paused { notify(pane, "La cola se detuvo en una pausa.") }
                return
            }
            edit(pane) { $0 = queue }
            send(next.text, to: pane, view: view)
            if queues[pane] == nil { notify(pane, "Se mandó el último mensaje de la cola.") }
        case .needsYou:
            queue.pause("Claude te pidió permiso o una respuesta")
            edit(pane) { $0 = queue }
            notify(pane, "Claude te necesita; la cola quedó en pausa.")
        case let .blocked(why):
            queue.pause(why)
            edit(pane) { $0 = queue }
            notify(pane, "La cola se detuvo: \(why)")
        case .working, .starting, .notLoaded:
            break
        }
    }

    private func send(_ text: String, to pane: UUID, view: NSView) {
        sentAt[pane] = Date()
        sawBusy.remove(pane)
        states[pane] = .working
        PaneUse.touch(pane)
        if let terminal = view as? TerminalView {
            terminal.send(txt: terminalSubmission(text))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { terminal.send(txt: "\r") }
        } else {
            Dictation.insert(text, into: view) { Dictation.submit(view) }
        }
    }

    // MARK: Terminal state, from Claude Code's hooks

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func terminalState(_ pane: UUID) -> WorkState {
        let dir = Self.hookDirectory
        let start = launched[pane] ?? .distantPast
        guard Date().timeIntervalSince(start) > 6 else { return .starting }
        func after(_ date: Date?) -> Date? { date.flatMap { $0 > start ? $0 : nil } }
        let stop = after(modified(ClaudeHooks.file(.stop, pane: pane, in: dir)))
        let prompt = after(modified(ClaudeHooks.file(.prompt, pane: pane, in: dir)))
        let notifyFile = ClaudeHooks.file(.notification, pane: pane, in: dir)
        let notify = after(modified(notifyFile))
        let busySince = [prompt, sentAt[pane]].compactMap { $0 }.max()
        if let notify, notify > (stop ?? .distantPast), notify >= (busySince ?? .distantPast),
           let payload = try? Data(contentsOf: notifyFile), ClaudeHooks.needsYou(payload) {
            return .needsYou
        }
        guard let busySince else { return .free }   // at the prompt since it started
        if let stop, stop >= busySince { return .free }
        return .working
    }

    // MARK: claude.ai state, from the page

    static let pageState = """
    (function () {
      var busy = Array.prototype.some.call(document.querySelectorAll('button'), function (b) {
        return /stop|detener|interrumpir/i.test(b.getAttribute('aria-label') || '');
      });
      var alerts = Array.prototype.map.call(document.querySelectorAll('[role="alert"]'), function (a) { return a.textContent || ''; }).join(' ');
      var blocked = /limit|límite|error|went wrong|salió mal|reconnect|reconect|offline|sin conexión/i.test(alerts) ? alerts.trim().slice(0, 120) : '';
      return JSON.stringify({ busy: busy, blocked: blocked });
    })()
    """

    private func webState(_ pane: UUID, account: String?, json: String?) -> WorkState {
        if let account, let limits = Usage.shared.limits[account] {
            if (limits.fiveHour?.percent ?? 0) >= 100 || (limits.week?.percent ?? 0) >= 100 { return .blocked("Se acabó el límite de uso de la cuenta") }
        }
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .working }
        if let blocked = object["blocked"] as? String, !blocked.isEmpty { return .blocked("claude.ai: \(blocked)") }
        let busy = object["busy"] as? Bool ?? false
        if busy { sawBusy.insert(pane); return .working }
        // Right after sending, the page may not show Stop yet: wait to see it, or 25 seconds.
        if let sent = sentAt[pane], !sawBusy.contains(pane) {
            let elapsed = Date().timeIntervalSince(sent)
            if elapsed < 25 { return .working }
        } else if let sent = sentAt[pane], Date().timeIntervalSince(sent) < 3 {
            return .working
        }
        return .free
    }

    // MARK: Notices

    private func notify(_ pane: UUID, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = SessionGroups.shared.paneTitle(pane) ?? "Cola de mensajes"
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - The queue in a pane's header

/// "3 en cola" in the pane's header; opens the queue.
struct QueueButton: View {
    let pane: SessionPane
    @ObservedObject private var queues = MessageQueues.shared
    @State private var open = false

    var body: some View {
        let queue = queues.queue(pane.id)
        Button {
            open.toggle()
        } label: {
            if queue.items.isEmpty {
                Image(systemName: "text.badge.plus")
            } else {
                Label(queue.paused ? "\(queue.pendingCount) en pausa" : "\(queue.pendingCount) en cola",
                      systemImage: queue.paused ? "pause.circle" : "list.number")
                    .foregroundStyle(queue.paused ? Color.orange : Color.accentColor)
            }
        }
        .help("Mensajes programados: se mandan uno tras otro cada vez que Claude termina")
        .popover(isPresented: $open, arrowEdge: .bottom) { QueueEditor(pane: pane) }
    }
}

struct QueueEditor: View {
    let pane: SessionPane
    @ObservedObject private var queues = MessageQueues.shared
    @State private var draft = ""

    var body: some View {
        let queue = queues.queue(pane.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cola de mensajes").font(.headline)
                Spacer()
                Text(status(queue)).font(.caption).foregroundStyle(queue.paused ? Color.orange : .secondary)
            }
            if queue.items.isEmpty {
                Text("Escribe abajo lo que quieres que Claude haga después. Cada mensaje sale cuando Claude termina el anterior; una pausa detiene la cola hasta que la continúes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                List {
                    ForEach(Array(queue.items.enumerated()), id: \.element.id) { index, item in
                        QueueRow(pane: pane.id, item: item, number: index + 1)
                    }
                    .onMove { source, destination in queues.edit(pane.id) { $0.move(fromOffsets: source, toOffset: destination) } }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 120, maxHeight: 300)
            }
            TextEditor(text: $draft)
                .font(.system(size: 13))
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button("Agregar") { queues.add(draft, to: pane.id); draft = "" }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Agregar pausa ⏸") { queues.addPause(to: pane.id) }
                Spacer()
                if queue.paused {
                    Button("Continuar") { queues.edit(pane.id) { $0.resume() } }.buttonStyle(.borderedProminent)
                } else if !queue.items.isEmpty {
                    Button("Pausar") { queues.edit(pane.id) { $0.pause("Pausada por ti") } }
                }
                Menu {
                    Button("Mandar el siguiente ya") { queues.sendNow(pane.id) }
                    Button("Vaciar la cola", role: .destructive) { queues.edit(pane.id) { $0 = MessageQueue() } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(queue.items.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 440)
    }

    private func status(_ queue: MessageQueue) -> String {
        if queue.paused { return "En pausa · \(queue.reason ?? "")" }
        if queue.items.isEmpty { return "" }
        return queues.states[pane.id]?.label ?? "Esperando…"
    }
}

struct QueueRow: View {
    let pane: UUID
    let item: QueuedMessage
    let number: Int
    @State private var text = ""

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if item.kind == .pause {
                Label("Pausa: aquí se detiene la cola", systemImage: "pause.circle").foregroundStyle(.orange)
            } else {
                Text("\(number).").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                TextField("Mensaje", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit(save)
                    .onChange(of: text) { save() }
            }
            Spacer()
            Button {
                MessageQueues.shared.edit(pane) { $0.items.removeAll { $0.id == item.id } }
            } label: { Image(systemName: "xmark.circle") }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .onAppear { text = item.text }
    }

    private func save() {
        guard text != item.text else { return }
        let id = item.id, value = text
        MessageQueues.shared.edit(pane) { queue in
            if let index = queue.items.firstIndex(where: { $0.id == id }) { queue.items[index].text = value }
        }
    }
}

// MARK: - Chrome shortcuts

/// Shortcuts that bring a given Chrome window forward.
@MainActor
final class ChromeShortcuts: ObservableObject {
    static let shared = ChromeShortcuts()
    @Published private(set) var list: [ChromeShortcut]
    private let file = JSONFile<[ChromeShortcut]>(named: "chrome-shortcuts.json")

    private init() { list = file.load() ?? [] }

    func add(name: String, url: String) {
        list.append(ChromeShortcut(name: ClaudeLink.cleanTitle(name).isEmpty ? url : ClaudeLink.cleanTitle(name), url: url,
                                   shortcut: GroupShortcut.suggestion(taken: taken)))
        save()
    }

    func update(_ id: UUID, _ change: (inout ChromeShortcut) -> Void) {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[index])
        save()
    }

    func delete(_ id: UUID) {
        list.removeAll { $0.id == id }
        save()
    }

    /// Every shortcut in use (groups and Chrome), so a suggestion doesn't collide.
    var taken: [GroupShortcut?] { list.map(\.shortcut) + SessionGroups.shared.groups.map(\.shortcut) }

    private func save() {
        try? file.save(list)
        Engine.shared.updateHotKeys()
    }

    func hotKeys() -> [HotKey.Binding] {
        list.compactMap { item in
            guard let shortcut = item.shortcut, shortcut.isUsable else { return nil }
            let match = item.match, url = item.url
            return HotKey.Binding(key: shortcut.keyCode, mods: shortcut.modifiers) {
                Task { try? await ChromeBridge.focus(match: match, url: url) }
            }
        }
    }
}

struct ChromeShortcutsView: View {
    @ObservedObject private var shortcuts = ChromeShortcuts.shared
    @State private var tabs: [ChromeTab] = []
    @State private var error: String?
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Atajos de Chrome").font(.title2.bold())
                Spacer()
                Button {
                    picking = true
                    Task { await loadTabs() }
                } label: { Label("Agregar desde Chrome…", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
            }
            Text("Cada atajo trae al frente la ventana de Chrome que muestra esa página (sus apps instaladas incluidas), en el escritorio donde esté. Si no está abierta, la abre.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(shortcuts.list) { item in
                    HStack(spacing: 12) {
                        Image(systemName: "macwindow").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).lineLimit(1)
                            Text(item.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        ShortcutRecorder(current: item.shortcut) { value in shortcuts.update(item.id) { $0.shortcut = value } }
                        Button("Ir") { Task { try? await ChromeBridge.focus(match: item.match, url: item.url) } }
                        Button { shortcuts.delete(item.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .padding(20)
        .sheet(isPresented: $picking) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Páginas abiertas en Chrome").font(.headline)
                if let error {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    List(tabs) { tab in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tab.title.isEmpty ? tab.url : tab.title).lineLimit(1)
                                Text(tab.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Agregar") { shortcuts.add(name: tab.title, url: tab.url) }
                                .disabled(shortcuts.list.contains { $0.url == tab.url })
                        }
                    }
                    .frame(minHeight: 300)
                }
                HStack { Spacer(); Button("Listo") { picking = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(16)
            .frame(width: 560, height: 460)
        }
    }

    private func loadTabs() async {
        error = nil
        do {
            var seen = Set<String>()
            tabs = try await ChromeBridge.tabs().filter { seen.insert($0.url).inserted }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
