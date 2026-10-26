import AppKit
import Carbon.HIToolbox
import LoveployCore
import SwiftUI
import UniformTypeIdentifiers

// Loveploy: billing projects. A window or a single session can be assigned to a project; the
// project then adds up the development time of every window that worked on it and the value of
// its tokens at API prices, to know what a project took and to bill it.

@MainActor
final class Projects: ObservableObject {
    static let shared = Projects()

    @Published private(set) var list: [BillingProject]
    private let file = JSONFile<[BillingProject]>(named: "projects.json")

    private init() {
        list = file.load() ?? []
    }

    func project(_ id: UUID?) -> BillingProject? {
        guard let id else { return nil }
        return list.first { $0.id == id }
    }

    func name(_ id: UUID?) -> String? { project(id)?.name }

    @discardableResult
    func create(name: String, folder: String? = nil) -> BillingProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = BillingProject(name: trimmed.isEmpty ? "Proyecto \(list.count + 1)" : trimmed, folders: folder.map { [$0] } ?? [])
        list.append(project)
        save()
        return project
    }

    func update(_ id: UUID, _ edit: (inout BillingProject) -> Void) {
        guard let index = list.firstIndex(where: { $0.id == id }) else { return }
        edit(&list[index])
        save()
    }

    func delete(_ id: UUID) {
        list.removeAll { $0.id == id }
        save()
    }

    private func save() {
        do { try file.save(list) } catch { NSSound.beep() }
    }

    /// Asks for a name and creates the project; nil when cancelled.
    func askForNew(suggesting name: String = "", folder: String? = nil) -> BillingProject? {
        let alert = NSAlert()
        alert.messageText = "Nuevo proyecto"
        alert.informativeText = "Las horas y los tokens de las sesiones asignadas se sumarán a este proyecto."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = name
        field.placeholderString = "Nombre del proyecto o cliente"
        alert.accessoryView = field
        alert.addButton(withTitle: "Crear")
        alert.addButton(withTitle: "Cancelar")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return create(name: field.stringValue, folder: folder)
    }
}

/// "Proyecto: X ▾" — picks the project of a window or a pane.
struct ProjectMenu: View {
    /// The chosen project (nil: none, or the group's for a pane).
    let selected: UUID?
    /// For a pane: the project it gets from its window when it has none of its own.
    var inherited: UUID? = nil
    var isPane = false
    var cloud = false
    var suggestedName = ""
    var folder: String? = nil
    let pick: (UUID?) -> Void
    @ObservedObject private var projects = Projects.shared

    var body: some View {
        Menu {
            Button(isPane ? "Igual que la ventana" + (projects.name(inherited).map { " (\($0))" } ?? "") : "Sin proyecto") { pick(nil) }
            if !projects.list.isEmpty { Divider() }
            ForEach(projects.list) { project in
                Button {
                    pick(project.id)
                } label: {
                    if project.id == selected { Label(project.name, systemImage: "checkmark") } else { Text(project.name) }
                }
            }
            Divider()
            Button("Nuevo proyecto…") {
                if let project = projects.askForNew(suggesting: suggestedName, folder: folder) { pick(project.id) }
            }
            Button("Proyectos y cobro…") { ProjectsWindow.show() }
            if cloud {
                Divider()
                Text("Las sesiones de la nube no dejan registro en esta Mac: su tiempo y tokens no se pueden medir.")
            }
        } label: {
            Label(label, systemImage: "briefcase")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Proyecto al que se cobran las horas y los tokens")
    }

    private var label: String {
        if let name = projects.name(selected) { return name }
        if isPane { return projects.name(inherited) ?? "Sin proyecto" }
        return "Sin proyecto"
    }
}

/// Records a global shortcut for a group: click, then press the keys.
struct ShortcutRecorder: View {
    let current: GroupShortcut?
    let set: (GroupShortcut?) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 4) {
            Button {
                recording ? stop() : start()
            } label: {
                Label(recording ? "Presiona las teclas…" : (current?.display ?? "Tecla rápida"), systemImage: "keyboard")
                    .monospacedDigit()
            }
            .help("Una combinación con ⌘, ⌃ o ⌥ que trae esta ventana al frente desde cualquier app o pantalla. Esc cancela.")
            if current != nil && !recording {
                Button { set(nil) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Quitar la tecla rápida")
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKey.register([])   // so pressing a combination already in use records it instead of firing it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                if Int(event.keyCode) == kVK_Escape {
                    stop()
                } else if let shortcut = Self.shortcut(from: event), shortcut.isUsable {
                    set(shortcut)
                    stop()
                } else {
                    NSSound.beep()
                }
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { Engine.shared.updateHotKeys() }
        recording = false
    }

    static func shortcut(from event: NSEvent) -> GroupShortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods = 0
        if flags.contains(.command) { mods |= GroupShortcut.command }
        if flags.contains(.option) { mods |= GroupShortcut.option }
        if flags.contains(.control) { mods |= GroupShortcut.control }
        if flags.contains(.shift) { mods |= GroupShortcut.shift }
        let code = Int(event.keyCode)
        let named: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_Space: "Espacio", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        let key = named[code] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !key.isEmpty else { return nil }
        return GroupShortcut(keyCode: code, modifiers: mods, key: key)
    }
}

// MARK: - Projects window

@MainActor
enum ProjectsWindow {
    private static var window: NSWindow?

    static func show() {
        PanelController.shared.close()
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Proyectos y cobro · Loveploy"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ProjectsView())
            w.setFrameAutosaveName("LoveployProjectsWindow")
            if !w.setFrameUsingName("LoveployProjectsWindow") { w.center() }
            window = w
        }
        DevClock.shared.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ProjectsView: View {
    enum Period: String, CaseIterable, Identifiable {
        case thisMonth, lastMonth, week, all
        var id: String { rawValue }

        var label: String {
            switch self {
            case .thisMonth: return "Este mes"
            case .lastMonth: return "Mes pasado"
            case .week: return "Últimos 7 días"
            case .all: return "Todo"
            }
        }

        /// First and last day, "yyyy-MM-dd".
        func range(now: Date = Date(), calendar: Calendar = .current) -> (String?, String?, String) {
            let format = DateFormatter()
            format.locale = Locale(identifier: "es_MX")
            format.dateFormat = "LLLL yyyy"
            func key(_ date: Date) -> String {
                let p = calendar.dateComponents([.year, .month, .day], from: date)
                return String(format: "%04d-%02d-%02d", p.year ?? 0, p.month ?? 0, p.day ?? 0)
            }
            switch self {
            case .thisMonth:
                let start = calendar.dateInterval(of: .month, for: now)?.start ?? now
                return (key(start), key(now), format.string(from: now))
            case .lastMonth:
                let previous = calendar.date(byAdding: .month, value: -1, to: now) ?? now
                let interval = calendar.dateInterval(of: .month, for: previous)
                let end = interval.map { $0.end.addingTimeInterval(-1) } ?? previous
                return (key(interval?.start ?? previous), key(end), format.string(from: previous))
            case .week:
                let start = calendar.date(byAdding: .day, value: -6, to: now) ?? now
                return (key(start), key(now), "\(key(start)) a \(key(now))")
            case .all:
                return (nil, nil, "todo")
            }
        }
    }

    struct Row: Identifiable {
        let totals: ProjectTotals
        let project: BillingProject?
        var id: String { totals.projectID?.uuidString ?? "sin-proyecto" }
    }

    @ObservedObject private var projects = Projects.shared
    @ObservedObject private var clock = DevClock.shared
    @ObservedObject private var groups = SessionGroups.shared
    @AppStorage("loveploy.projectsPeriod") private var period: Period = .thisMonth
    @State private var selection: String?

    private var rows: [Row] {
        let (from, to, _) = period.range()
        return ProjectReport.build(ledger: clock.ledger, projects: projects.list, assignments: groups.billingAssignments, from: from, to: to)
            .map { totals in Row(totals: totals, project: projects.project(totals.projectID)) }
    }

    var body: some View {
        let rows = rows
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Periodo", selection: $period) {
                    ForEach(Period.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                if clock.scanning { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    if let project = projects.askForNew() { selection = project.id.uuidString }
                } label: { Label("Nuevo proyecto", systemImage: "plus") }
                Button { export(rows) } label: { Label("Exportar CSV…", systemImage: "square.and.arrow.up") }
            }
            Table(rows, selection: $selection) {
                TableColumn("Proyecto") { row in
                    Text(row.project?.name ?? "Sin proyecto").foregroundStyle(row.project == nil ? .secondary : .primary)
                }
                TableColumn("Horas") { row in
                    Text(DevHours.format(minutes: row.totals.minutes)).monospacedDigit()
                        .help("Tiempo real: un bloque de 5 minutos cuenta una vez aunque varias ventanas trabajaran a la vez")
                }
                .width(min: 70, ideal: 90)
                TableColumn("Horas de sesiones") { row in
                    Text(DevHours.format(minutes: row.totals.sessionMinutes)).monospacedDigit().foregroundStyle(.secondary)
                        .help("El tiempo de cada sesión sumado: dos ventanas una hora = dos horas")
                }
                .width(min: 90, ideal: 110)
                TableColumn("Sesiones") { row in Text("\(row.totals.sessions)").monospacedDigit() }
                    .width(min: 50, ideal: 60)
                TableColumn("Tokens") { row in Text(Self.short(row.totals.tokenTotal)).monospacedDigit() }
                    .width(min: 60, ideal: 70)
                TableColumn("Valor tokens") { row in Text(Self.usd(row.totals.dollars)).monospacedDigit() }
                    .width(min: 80, ideal: 90)
                TableColumn("Honorarios") { row in
                    if let fee = row.totals.fee(rate: row.project?.hourlyRate), let project = row.project {
                        Text(Self.money(fee, project.currency)).monospacedDigit()
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 90, ideal: 110)
            }
            if let id = selection.flatMap(UUID.init(uuidString:)), let project = projects.project(id) {
                ProjectEditor(project: project, totals: rows.first { $0.totals.projectID == id }?.totals)
            } else {
                Text("Asigna una ventana o una sesión a un proyecto con el botón \(Image(systemName: "briefcase")) de la ventana del grupo o de cada panel. También cuentan las sesiones que corren dentro de las carpetas del proyecto. El valor de los tokens es lo que costarían con los precios de la API de Anthropic (dólares); las sesiones de la nube no se pueden medir desde esta Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(minWidth: 760, minHeight: 460)
    }

    private func export(_ rows: [Row]) {
        let (_, _, name) = period.range()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Loveploy proyectos \(name).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = ProjectReport.csv(rows.map(\.totals), projects: projects.list, period: name)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    static func short(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: return String(format: "%.1f B", Double(n) / 1e9)
        case 1_000_000...: return String(format: "%.1f M", Double(n) / 1e6)
        case 1_000...: return String(format: "%.0f K", Double(n) / 1e3)
        default: return "\(n)"
        }
    }

    static func usd(_ value: Double) -> String { String(format: "US$ %.2f", value) }

    static func money(_ value: Double, _ currency: String) -> String { String(format: "$%.2f ", value) + currency }
}

/// Name, rate, folders and the per-model breakdown of the selected project.
struct ProjectEditor: View {
    let project: BillingProject
    let totals: ProjectTotals?
    @State private var name = ""
    @State private var rate = ""
    @State private var currency = ""

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Nombre").frame(width: 70, alignment: .leading)
                    TextField("Nombre", text: $name).onSubmit(saveFields)
                }
                HStack {
                    Text("Tarifa").frame(width: 70, alignment: .leading)
                    TextField("Por hora (opcional)", text: $rate).frame(width: 130).onSubmit(saveFields)
                    TextField("Moneda", text: $currency).frame(width: 60).onSubmit(saveFields)
                    Text("por hora").foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    Text("Carpetas").frame(width: 70, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(project.folders, id: \.self) { folder in
                            HStack {
                                Text(folder).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Button { Projects.shared.update(project.id) { $0.folders.removeAll { $0 == folder } } } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        Button("Agregar carpeta…") { addFolder() }
                        Text("Toda sesión de Claude Code que corra dentro de estas carpetas cuenta para el proyecto.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Guardar", action: saveFields).keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("Eliminar proyecto", role: .destructive) {
                        Projects.shared.delete(project.id)
                    }
                }
            }
            .frame(maxWidth: 420)
            if let totals, !totals.tokens.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Por modelo").font(.headline)
                    ForEach(totals.tokens.sorted { $0.value.dollars(model: $0.key) > $1.value.dollars(model: $1.key) }, id: \.key) { model, count in
                        HStack {
                            Text(model).font(.caption.monospaced())
                            Spacer()
                            Text("\(ProjectsView.short(count.total)) · \(ProjectsView.usd(count.dollars(model: model)))")
                                .font(.caption).monospacedDigit()
                        }
                    }
                    if let last = totals.lastActive {
                        Text("Última actividad: \(last)").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
        .onAppear(perform: loadFields)
        .onChange(of: project.id) { loadFields() }
    }

    private func loadFields() {
        name = project.name
        rate = project.hourlyRate.map { String(format: "%g", $0) } ?? ""
        currency = project.currency
    }

    private func saveFields() {
        let value = Double(rate.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        Projects.shared.update(project.id) {
            $0.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? $0.name : name
            $0.hourlyRate = value
            $0.currency = currency.trimmingCharacters(in: .whitespaces).isEmpty ? "MXN" : currency.uppercased()
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Agregar"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Projects.shared.update(project.id) { project in
            for path in paths where !project.folders.contains(path) { project.folders.append(path) }
        }
    }
}
