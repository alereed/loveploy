import AppKit
import Combine
import LoveployCore
import SwiftUI

/// Joins Loveploy's own features (Lovable deploys, session groups) to the account manager in
/// main.swift, which calls into here at the few places marked "Loveploy:".
@MainActor
enum LoveployBridge {
    private(set) static var model: AppModel?
    private static var observers = Set<AnyCancellable>()
    /// Where MultiClaude kept its settings, for a first launch on a Mac that already used it.
    static let multiClaudeDomain = "me.somalabs.multiclaude"

    /// Brings over MultiClaude's profiles and settings the first time, if it was installed.
    static func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "profiles") == nil,
              let ours = Bundle.main.bundleIdentifier, ours != multiClaudeDomain,
              var old = defaults.persistentDomain(forName: multiClaudeDomain), !old.isEmpty else { return }
        // Not the update bookkeeping of the other app.
        for key in ["updatedTo", "lastUpdateCheck"] { old[key] = nil }
        var mine = defaults.persistentDomain(forName: ours) ?? [:]
        mine.merge(old) { current, _ in current }
        defaults.setPersistentDomain(mine, forName: ours)
    }

    static func start() {
        installMainMenu()
        let model = AppModel()
        self.model = model
        // The menu bar shows how many projects wait to publish.
        model.objectWillChange
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { Engine.shared.onChange?() } }
            .store(in: &observers)
        // The menu bar shows how much of the week is left.
        Usage.shared.$limits
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { Engine.shared.onChange?() } }
            .store(in: &observers)
        DevClock.shared.start()
        SessionGroups.shared.openAtLaunch()
    }

    /// A menu-bar-only app has no main menu, and without one ⌘C/⌘V/⌘X/⌘A/⌘Z do nothing
    /// in text fields and terminals (only right-click → Paste worked). Key equivalents still
    /// go through the main menu while it isn't shown, so give the app the standard one.
    static func installMainMenu() {
        let main = NSMenu()

        let app = NSMenu(title: "Loveploy")
        app.addItem(withTitle: "Ocultar Loveploy", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Salir de Loveploy", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Loveploy")

        let edit = NSMenu(title: "Edición")
        edit.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let plain = edit.addItem(withTitle: "Pegar sin formato", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "v")
        plain.keyEquivalentModifierMask = [.command, .option, .shift]
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Buscar…", action: #selector(NSResponder.performTextFinderAction(_:)), keyEquivalent: "f")
            .tag = NSTextFinder.Action.showFindInterface.rawValue
        main.addItem(submenu: edit, title: "Edición")

        let window = NSMenu(title: "Ventana")
        window.addItem(withTitle: "Cerrar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Pantalla completa", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu: window, title: "Ventana")
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    /// " ♥3" after the menu bar icon while Lovable projects are out of date.
    static var menuBarSuffix: String {
        guard let model, model.pendingCount > 0 else { return "" }
        return " ♥\(model.pendingCount)"
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

/// The panel sections Loveploy adds: Lovable and session groups.
struct LoveploySections: View {
    @AppStorage("loveploy.consumptionOpen") private var consumptionOpen = true
    @AppStorage("loveploy.lovableOpen") private var lovableOpen = true
    @AppStorage("loveploy.groupsOpen") private var groupsOpen = true

    var body: some View {
        ConsumptionSection(open: $consumptionOpen)
        if let model = LoveployBridge.model {
            LovableSection(model: model, open: $lovableOpen)
        }
        GroupsSection(groups: SessionGroups.shared, open: $groupsOpen)
    }
}

struct LovableSection: View {
    @ObservedObject var model: AppModel
    @Binding var open: Bool

    var body: some View {
        Divider().padding(.horizontal, 14)
        SectionHeader(title: "Lovable", trailing: trailing, open: $open)
        if open {
            VStack(spacing: 0) {
                if model.isSignedIn {
                    ToggleRow(symbol: "bolt.fill", title: "Turbo", hint: model.turbo ? "publica solo" : nil, on: model.turbo) {
                        model.turbo.toggle()
                    }
                    if !model.selectedRows.isEmpty {
                        PlainRow(title: model.isDeploying ? "Publicando…" : publishTitle) {
                            if !model.isDeploying { model.deploySelected() }
                        }
                    }
                    if model.iosNeedingUpload > 0 {
                        PlainRow(title: "\(model.iosNeedingUpload) app(s) de iOS sin TestFlight…") { LovableWindow.show(filter: .ios) }
                    }
                    PlainRow(title: "Abrir proyectos…") { LovableWindow.show() }
                } else {
                    PlainRow(title: "Iniciar sesión en Lovable…") {
                        PanelController.shared.close()
                        model.signIn()
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 5)
        }
    }

    private var trailing: String {
        guard model.isSignedIn else { return "Sin sesión" }
        if model.isRefreshing && model.rows.isEmpty { return "Cargando…" }
        return model.pendingCount == 0 ? "Al día" : "\(model.pendingCount) por publicar"
    }

    private var publishTitle: String {
        let count = model.selectedRows.count
        return count == 1 ? "Publicar 1 proyecto" : "Publicar \(count) proyectos"
    }
}

/// The full Lovable list (what used to be Loveploy's whole menu), in a window.
@MainActor
enum LovableWindow {
    private static var window: NSWindow?

    static func show(filter: AppModel.Filter? = nil) {
        guard let model = LoveployBridge.model else { return }
        if let filter { model.filter = filter }
        PanelController.shared.close()
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 620),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Lovable · Loveploy"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: LovableView().environmentObject(model))
            w.setFrameAutosaveName("LoveployLovableWindow")
            if !w.setFrameUsingName("LoveployLovableWindow") { w.center() }
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
