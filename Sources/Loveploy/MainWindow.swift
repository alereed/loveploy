import AppKit
import LoveployCore
import SwiftUI

// Loveploy: the short menu bar panel (what you use every day) and the Loveploy window, where
// everything else is managed.

/// The short panel: groups to open, Lovable at a glance, the week that's left.
struct CompactSections: View {
    @ObservedObject private var groups = SessionGroups.shared
    @ObservedObject private var usage = Usage.shared
    @ObservedObject private var clock = DevClock.shared
    @ObservedObject private var engine = Engine.shared

    var body: some View {
        Divider().padding(.horizontal, 14)
        SectionHeader(title: "Grupos de sesiones", trailing: groups.openIDs.isEmpty ? nil : "\(groups.openIDs.count) abiertos", open: .constant(true))
        VStack(spacing: 0) {
            ForEach(groups.groups) { GroupRow(group: $0, groups: groups) }
            if groups.groups.isEmpty {
                PlainRow(title: "Crear un grupo…") { MainWindow.show(.groups) }
            } else if groups.groups.count > 1 {
                PlainRow(title: "Abrir todos") { groups.openAll() }
            }
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 5)

        if let model = LoveployBridge.model {
            Divider().padding(.horizontal, 14)
            LovableLine(model: model)
        }

        Divider().padding(.horizontal, 14)
        weekLine
    }

    /// Every account's week at once, one line each.
    private var weekLine: some View {
        VStack(alignment: .leading, spacing: 5) {
            if engine.isOn(.chatLimits) {
                let accounts = engine.profiles.filter { usage.limits[$0.id.uuidString] != nil }
                if accounts.isEmpty {
                    Text("Consultando claude.ai…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(accounts) { profile in
                    AccountWeekLine(profile: profile, snapshot: usage.limits[profile.id.uuidString]!)
                }
            } else {
                HStack {
                    Text("Semana").font(.system(size: 13))
                    Spacer()
                    Text("Mostrar lo que queda de cada cuenta…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Text("Desarrollo hoy \(DevHours.format(minutes: clock.hours.minutes(on: Date()))) · semana \(DevHours.format(minutes: clock.hours.minutesThisWeek()))")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .modifier(HoverBackground(radius: 8))
        .onTapGesture {
            if !engine.isOn(.chatLimits) { engine.toggle(.chatLimits) } else { MainWindow.show(.usage) }
        }
        .help("Lo que queda de la semana en cada cuenta; clic para el consumo detallado")
    }
}

/// "● BLENDER ▓▓▓▓░░ 35% · 1 d 6 h" — one account's week in a single line.
struct AccountWeekLine: View {
    let profile: Profile
    let snapshot: ChatLimits.Snapshot

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(profile.tint).frame(width: 7, height: 7)
            Text(profile.name).font(.system(size: 12)).lineLimit(1).frame(width: 78, alignment: .leading)
            if let week = snapshot.week {
                let left = WeeklyLimit.left(week)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(left <= 15 ? Color.red : profile.tint)
                            .frame(width: max(2, proxy.size.width * CGFloat(left) / 100))
                    }
                }
                .frame(height: 5)
                Text("\(left)%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(left <= 15 ? Color.red : Color.primary)
                    .frame(width: 34, alignment: .trailing)
                Text(WeeklyLimit.resets(week.resetsAt).map { $0.replacingOccurrences(of: "en ", with: "") } ?? "")
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 54, alignment: .trailing)
            } else {
                Text(WeeklyLimit.explain(snapshot.error)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
        }
        .help(help)
    }

    private var help: String {
        guard let week = snapshot.week else { return WeeklyLimit.explain(snapshot.error) }
        var text = "\(profile.name): queda \(WeeklyLimit.left(week))% de la semana"
        if let resets = WeeklyLimit.resets(week.resetsAt) { text += ", se renueva \(resets)" }
        if let five = snapshot.fiveHour { text += ". Límite de 5 h: \(Int(five.percent.rounded()))% usado" }
        return text
    }
}

/// "Lovable · 3 por publicar  [Publicar]" in one line.
struct LovableLine: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.turbo ? "bolt.fill" : "heart.fill").font(.system(size: 11))
                .foregroundStyle(model.turbo ? Color.orange : Color.pink)
                .help(model.turbo ? "Turbo: publica solo" : "Lovable")
            Text("Lovable").font(.system(size: 13))
            Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            if model.isSignedIn && !model.selectedRows.isEmpty {
                Button(model.isDeploying ? "Publicando…" : "Publicar \(model.selectedRows.count)") {
                    if !model.isDeploying { model.deploySelected() }
                }
                .controlSize(.small)
                .disabled(model.isDeploying)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .modifier(HoverBackground(radius: 8))
        .onTapGesture {
            if model.isSignedIn { MainWindow.show(.lovable) } else { PanelController.shared.close(); model.signIn() }
        }
    }

    private var status: String {
        guard model.isSignedIn else { return "sin sesión" }
        if model.isRefreshing && model.rows.isEmpty { return "cargando…" }
        return model.pendingCount == 0 ? "al día" : "\(model.pendingCount) por publicar"
    }
}

// MARK: - The Loveploy window

enum MainSection: String, CaseIterable, Identifiable {
    case home, groups, lovable, projects, usage
    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: return "Panel completo"
        case .groups: return "Grupos de sesiones"
        case .lovable: return "Lovable"
        case .projects: return "Proyectos y cobro"
        case .usage: return "Consumo detallado"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "menubar.rectangle"
        case .groups: return "rectangle.split.2x2"
        case .lovable: return "heart"
        case .projects: return "briefcase"
        case .usage: return "chart.bar"
        }
    }
}

@MainActor
final class MainWindowState: ObservableObject {
    static let shared = MainWindowState()
    @Published var section: MainSection = MainSection(rawValue: UserDefaults.standard.string(forKey: "loveploy.mainSection") ?? "") ?? .groups {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: "loveploy.mainSection") }
    }
}

@MainActor
enum MainWindow {
    private static var window: NSWindow?

    static func show(_ section: MainSection? = nil) {
        PanelController.shared.close()
        if let section { MainWindowState.shared.section = section }
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Blender Play"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: MainWindowView())
            w.setFrameAutosaveName("LoveployMainWindow")
            if !w.setFrameUsingName("LoveployMainWindow") { w.center() }
            window = w
        }
        DevClock.shared.refresh()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct MainWindowView: View {
    @ObservedObject private var state = MainWindowState.shared

    var body: some View {
        NavigationSplitView {
            List(MainSection.allCases, selection: Binding(get: { state.section }, set: { if let s = $0 { state.section = s } })) { section in
                Label(section.label, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) {
                Text("Hecho por Blender.mx · Alejandro Reed").font(.caption2).foregroundStyle(.tertiary).padding(8)
            }
        } detail: {
            switch state.section {
            case .home:
                MenuView(inWindow: true)
            case .groups:
                GroupsManagerView()
            case .lovable:
                if let model = LoveployBridge.model {
                    LovableView().environmentObject(model)
                }
            case .projects:
                ProjectsView()
            case .usage:
                UsageWindowView()
            }
        }
        .frame(minWidth: 820, minHeight: 520)
    }
}

/// Every group in one place: open, rename, shortcut, project, open at launch.
struct GroupsManagerView: View {
    @ObservedObject private var groups = SessionGroups.shared
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Grupos de sesiones").font(.title2.bold())
                Spacer()
                if groups.groups.count > 1 {
                    Button("Abrir todos") { groups.openAll() }
                }
            }
            HStack {
                TextField("Nombre del nuevo grupo", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .onSubmit(create)
                Button("Crear grupo", action: create).buttonStyle(.borderedProminent)
            }
            MemorySaverSettings()
            List {
                ForEach(groups.groups) { group in
                    GroupManagerRow(group: group)
                }
                .onMove { groups.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Text("Arrastra los grupos (o usa las flechas) para cambiar su orden; el panel de la barra los muestra en ese orden. Cada grupo abre hasta 8 sesiones de Claude Code en una ventana dividida. La tecla rápida trae su ventana al frente desde cualquier app, y el proyecto suma sus horas y tokens para cobrar.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func create() {
        groups.create(name: newName)
        newName = ""
    }
}

struct GroupManagerRow: View {
    let group: SessionGroup
    @ObservedObject private var groups = SessionGroups.shared
    @State private var name = ""

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Arrastra para reacomodar")
            VStack(spacing: 0) {
                Button { groups.move(group.id, by: -1) } label: { Image(systemName: "chevron.up") }
                    .disabled(groups.groups.first?.id == group.id)
                Button { groups.move(group.id, by: 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(groups.groups.last?.id == group.id)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 9, weight: .semibold))
            Image(systemName: group.layout.symbol).foregroundStyle(groups.isOpen(group.id) ? Color.accentColor : .secondary)
            TextField("Nombre", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .frame(minWidth: 160)
                .onSubmit { groups.change(group.id) { $0.name = name } }
            Text("\(group.panes.count)/\(SessionGroup.maxPanes)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Spacer()
            ShortcutRecorder(current: group.shortcut) { groups.setShortcut($0, for: group.id) }
            ProjectMenu(selected: group.project, suggestedName: group.name) { project in
                groups.change(group.id) { $0.project = project }
            }
            Toggle("Al iniciar", isOn: Binding(get: { group.openAtLaunch }, set: { on in groups.change(group.id) { $0.openAtLaunch = on } }))
                .toggleStyle(.checkbox)
            Button(groups.isOpen(group.id) ? "Ir" : "Abrir") { groups.open(group.id) }
            Button {
                let alert = NSAlert()
                alert.messageText = "¿Eliminar el grupo «\(group.name)»?"
                alert.informativeText = "Las sesiones no se borran; solo deja de existir este acomodo."
                alert.addButton(withTitle: "Eliminar")
                alert.addButton(withTitle: "Cancelar")
                if alert.runModal() == .alertFirstButtonReturn { groups.delete(group.id) }
            } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .onAppear { name = group.name }
        .onChange(of: group.name) { name = group.name }
    }
}

/// How long unused panes stay loaded before they pause.
struct MemorySaverSettings: View {
    @AppStorage("loveploy.sleepWebMinutes") private var webMinutes = 10
    @AppStorage("loveploy.sleepTerminalMinutes") private var terminalMinutes = 30

    var body: some View {
        HStack(spacing: 14) {
            Label("Ahorro de memoria", systemImage: "moon.zzz").font(.system(size: 13, weight: .semibold))
            Picker("Paneles web", selection: $webMinutes) {
                Text("Siempre cargados").tag(0)
                ForEach([5, 10, 15, 30], id: \.self) { Text("pausar tras \($0) min sin usar").tag($0) }
            }
            .fixedSize()
            Picker("Terminales", selection: $terminalMinutes) {
                Text("Siempre abiertas").tag(0)
                ForEach([15, 30, 60, 120], id: \.self) { Text("pausar tras \($0) min sin actividad").tag($0) }
            }
            .fixedSize()
            Spacer()
        }
        .font(.system(size: 12))
        .help("Los paneles web se pausan cuando llevas ese tiempo fuera de su ventana y sin usarlos; vuelven al regresar a la ventana. Las terminales se pausan cuando Claude Code lleva ese tiempo sin escribir ni recibir nada, y se reanudan con un clic. El panel en el que estás escribiendo nunca se pausa.")
    }
}
