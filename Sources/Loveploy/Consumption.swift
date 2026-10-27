import AppKit
import Combine
import LoveployCore
import SwiftUI
import WebKit

// Loveploy: how much of each account's weekly limit is left, in the panel and the menu bar,
// and how many hours went into development (from Claude Code's transcripts).

/// Keeps the usage ledger (time and tokens per session) up to date, reading only what the
/// transcripts gained, plus the time spent in web and Chrome panes, which leave no transcript
/// on this Mac. Development hours and project billing both come from it.
@MainActor
final class DevClock: ObservableObject {
    static let shared = DevClock()
    @Published private(set) var ledger = UsageLedger()
    @Published private(set) var activity = ActivityLog()
    @Published private(set) var hours = DevHours()
    @Published private(set) var scanning = false
    private var timer: Timer?
    private var chromeTimer: Timer?
    private let file = JSONFile<UsageLedger>(named: "ledger.json")
    private let activityFile = JSONFile<ActivityLog>(named: "activity.json")

    /// Transcripts and pane activity together.
    var combined: UsageLedger { activity.merged(into: ledger) }

    func start() {
        guard timer == nil else { return }
        activity = activityFile.load() ?? ActivityLog()
        timer = Timer(timeInterval: 120, repeats: true) { _ in MainActor.assumeIsolated { DevClock.shared.refresh() } }
        RunLoop.main.add(timer!, forMode: .common)
        // While you're in a Chrome window that belongs to a group, that pane is being worked on.
        chromeTimer = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { DevClock.shared.checkChrome() } }
        RunLoop.main.add(chromeTimer!, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { DevClock.shared.refresh() }
    }

    /// A web pane wrote or was used (at most once a minute per pane).
    func record(pane: UUID) {
        guard activity.record(ActivityLog.key(pane: pane)) else { return }
        try? activityFile.save(activity)
        updateHours()
    }

    private func updateHours() {
        let hours = combined.devHours
        if self.hours.slots != hours.slots { self.hours = hours }
    }

    private func checkChrome() {
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              front.hasPrefix(ChromeBridge.bundleID) else { return }
        let panes = SessionGroups.shared.groups.flatMap(\.panes).filter { $0.kind == .chrome }
        guard !panes.isEmpty else { return }
        Task {
            guard let url = try? await ChromeBridge.frontURL() else { return }
            for pane in panes where pane.url.map({ ClaudeLink.samePage($0, url) }) == true {
                DevClock.shared.record(pane: pane.id)
            }
        }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        var roots = Accounts.localRoots().map(\.root)
        roots += Engine.shared.profiles.map { $0.folderURL.appendingPathComponent("local-agent-mode-sessions") }
        let first = timer != nil && ledger.offsets.isEmpty
        let current = ledger
        let file = file
        Task.detached(priority: .utility) {
            var updated = first ? (file.load() ?? current) : current
            let before = updated
            updated.scan(roots: roots)
            if updated != before { try? file.save(updated) }
            let result = updated
            await MainActor.run {
                let clock = DevClock.shared
                if clock.ledger != result { clock.ledger = result }
                clock.updateHours()
                clock.scanning = false
            }
        }
    }
}

/// Injected in web panes: tells Loveploy, at most once a minute, that something happened in
/// the pane (you typed or clicked, or Claude wrote a new piece of text).
final class PaneActivity: NSObject, WKScriptMessageHandler {
    static let name = "loveployActivity"
    static let script = """
    (function () {
      var last = 0;
      function ping() {
        var now = Date.now();
        if (now - last < 60000) return;
        last = now;
        try { window.webkit.messageHandlers.\(PaneActivity.name).postMessage(1); } catch (e) {}
      }
      ['keydown', 'mousedown', 'wheel'].forEach(function (t) { addEventListener(t, ping, true); });
      new MutationObserver(function (records) {
        for (var i = 0; i < records.length; i++) {
          var nodes = records[i].addedNodes;
          for (var j = 0; j < nodes.length; j++) {
            if ((nodes[j].textContent || '').length >= 30) { ping(); return; }
          }
          if (records[i].type === 'characterData' && (records[i].target.data || '').length >= 30) { ping(); return; }
        }
      }).observe(document.documentElement, { childList: true, subtree: true, characterData: true });
    })();
    """
    let pane: UUID

    init(pane: UUID) { self.pane = pane }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let pane = pane
        MainActor.assumeIsolated {
            PaneUse.touch(pane)
            DevClock.shared.record(pane: pane)
        }
    }

    /// Adds the script to a web pane's configuration. The handler only knows the pane's id,
    /// so it holds nothing alive when the pane goes away.
    static func install(in configuration: WKWebViewConfiguration, pane: UUID) {
        let controller = configuration.userContentController
        controller.add(PaneActivity(pane: pane), name: name)
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }
}

/// The weekly limit closest to running out, for the menu bar.
@MainActor
enum WeeklyLimit {
    static var showInMenuBar: Bool {
        UserDefaults.standard.object(forKey: "loveploy.weekInMenuBar") as? Bool ?? true
    }

    static func tightest() -> (profile: Profile, limit: ChatLimits.Limit)? {
        Engine.shared.profiles
            .compactMap { profile in Usage.shared.limits[profile.id.uuidString]?.week.map { (profile, $0) } }
            .max { $0.1.percent < $1.1.percent }
    }

    static func left(_ limit: ChatLimits.Limit) -> Int {
        max(0, 100 - Int(limit.percent.rounded()))
    }

    /// Why an account shows no limits, in plain words.
    static func explain(_ error: String?) -> String {
        switch error {
        case nil: return "Sin datos todavía"
        case "Not signed in": return "Abre Claude con esta cuenta e inicia sesión"
        case "Keychain access refused": return "Permite el acceso a «Claude Safe Storage» en el Llavero"
        case "No organization", "No limits": return "claude.ai no reporta límites para esta cuenta"
        case let text? where text.hasPrefix("claude.ai refused"): return "La sesión venció: abre Claude con esta cuenta"
        case "Couldn't reach claude.ai": return "Sin conexión con claude.ai"
        case let text?: return text
        }
    }

    /// "en 2 d 4 h", "en 3 h 10 min".
    static func resets(_ date: Date?) -> String? {
        guard let date else { return nil }
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return "en \(days) d \(hours) h" }
        if hours > 0 { return "en \(hours) h \(minutes) min" }
        return "en \(minutes) min"
    }

    /// The menu bar icon followed by one thin bar per account (what's left of each week) and
    /// the lowest percentage.
    static func decorate(_ icon: NSImage?) -> NSImage? {
        guard showInMenuBar, let icon else { return icon }
        let accounts = Engine.shared.profiles.compactMap { profile -> (Profile, Int)? in
            Usage.shared.limits[profile.id.uuidString]?.week.map { (profile, left($0)) }
        }
        guard let lowest = accounts.map(\.1).min() else { return icon }
        let shown = Array(accounts.prefix(4))
        let low = lowest <= 15
        let template = icon.isTemplate && !low
        let ink: NSColor = template ? .black : .labelColor
        let text = NSAttributedString(string: "\(lowest)%", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: template ? NSColor.black : (low ? NSColor.systemRed : NSColor.labelColor),
        ])
        let barWidth: CGFloat = 20, barHeight: CGFloat = shown.count > 2 ? 2.5 : 3.5, spacing: CGFloat = 1.5
        let stack = CGFloat(shown.count) * barHeight + CGFloat(shown.count - 1) * spacing
        let gap: CGFloat = 4
        let size = NSSize(width: icon.size.width + gap + barWidth + 3 + text.size().width, height: max(icon.size.height, 14))
        let image = NSImage(size: size, flipped: false) { _ in
            icon.draw(in: NSRect(x: 0, y: (size.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
            var y = (size.height + stack) / 2 - barHeight
            for (profile, left) in shown {
                let track = NSRect(x: icon.size.width + gap, y: y, width: barWidth, height: barHeight)
                ink.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
                (template ? ink : (left <= 15 ? .systemRed : profile.nsTint)).setFill()
                let fill = NSRect(x: track.minX, y: y, width: max(1, barWidth * CGFloat(left) / 100), height: barHeight)
                NSBezierPath(roundedRect: fill, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
                y -= barHeight + spacing
            }
            text.draw(at: NSPoint(x: icon.size.width + gap + barWidth + 3, y: (size.height - text.size().height) / 2))
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "Blender Play. " + accounts.map { "\($0.0.name): queda \($0.1)%" }.joined(separator: ", ")
        return image
    }
}

/// The panel's "Consumo" section.
struct ConsumptionSection: View {
    @ObservedObject private var usage = Usage.shared
    @ObservedObject private var engine = Engine.shared
    @ObservedObject private var clock = DevClock.shared
    @AppStorage("loveploy.weekInMenuBar") private var weekInMenuBar = true
    @Binding var open: Bool

    var body: some View {
        Divider().padding(.horizontal, 14)
        SectionHeader(title: "Consumo", trailing: trailing, open: $open)
        if open {
            VStack(alignment: .leading, spacing: 4) {
                if engine.isOn(.chatLimits) {
                    let accounts = engine.profiles.filter { usage.limits[$0.id.uuidString] != nil }
                    if accounts.isEmpty {
                        Text("Consultando claude.ai…").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    ForEach(accounts) { profile in
                        WeekRow(profile: profile, snapshot: usage.limits[profile.id.uuidString]!)
                    }
                } else {
                    PlainRow(title: "Mostrar cuánto queda de la semana…") { engine.toggle(.chatLimits) }
                }
                devRow
                if engine.isOn(.chatLimits) {
                    ToggleRow(symbol: "menubar.rectangle", title: "Semana en la barra de menú", hint: nil, on: weekInMenuBar) {
                        weekInMenuBar.toggle()
                        engine.onChange?()
                    }
                }
                PlainRow(title: "Proyectos y cobro…") { ProjectsWindow.show() }
                PlainRow(title: "Ver consumo detallado…") {
                    PanelController.shared.close()
                    UsageWindow.show()
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 5)
        }
    }

    private var trailing: String? {
        guard engine.isOn(.chatLimits), let limit = WeeklyLimit.tightest()?.limit else {
            return "Hoy " + DevHours.format(minutes: clock.hours.minutes(on: Date()))
        }
        return "Queda \(WeeklyLimit.left(limit))% de la semana"
    }

    private var devRow: some View {
        let hours = clock.hours
        return HStack(spacing: 8) {
            Image(systemName: "hammer.fill").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Horas de desarrollo").font(.system(size: 13))
                Text("Hoy \(DevHours.format(minutes: hours.minutes(on: Date()))) · semana \(DevHours.format(minutes: hours.minutesThisWeek())) · 30 días \(DevHours.format(minutes: hours.minutes(lastDays: 30)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .help("Cada bloque de 5 minutos en que tú o Claude Code escribieron en una sesión de esta Mac.")
    }
}

/// One account: a wide bar of the week that's left, and the 5-hour window.
struct WeekRow: View {
    let profile: Profile
    let snapshot: ChatLimits.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(profile.tint).frame(width: 8, height: 8)
                Text(profile.name).font(.system(size: 13)).lineLimit(1)
                Spacer()
                if let week = snapshot.week {
                    Text("Queda \(WeeklyLimit.left(week))%").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(WeeklyLimit.left(week) <= 15 ? Color.red : Color.primary)
                }
            }
            if snapshot.error != nil {
                Text(WeeklyLimit.explain(snapshot.error)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let week = snapshot.week {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(WeeklyLimit.left(week) <= 15 ? Color.red : profile.tint)
                            .frame(width: max(3, proxy.size.width * CGFloat(WeeklyLimit.left(week)) / 100))
                    }
                }
                .frame(height: 6)
                HStack(spacing: 4) {
                    Text("Semana: \(Int(week.percent.rounded()))% usado" + (WeeklyLimit.resets(week.resetsAt).map { " · se renueva \($0)" } ?? ""))
                    Spacer()
                    if let five = snapshot.fiveHour {
                        Text("5 h: \(Int(five.percent.rounded()))%" + (WeeklyLimit.resets(five.resetsAt).map { " · \($0)" } ?? ""))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
