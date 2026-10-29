import AppKit
import CryptoKit
import LoveployCore
import SwiftUI
import WebKit

// Loveploy: the "Vista web" pane, a site or a local preview next to the Claude sessions. With
// "Recargar con cambios" on, it checks the page every few seconds and reloads when the site
// changes (a new publish on Lovable, a new deploy, a rebuilt local server).

@MainActor
final class PreviewWatcher {
    static let shared = PreviewWatcher()

    private final class Watch {
        weak var web: WKWebView?
        var fingerprint: String?
        init(web: WKWebView) { self.web = web }
    }

    private var watches: [UUID: Watch] = [:]
    private var timer: Timer?
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 8
        return URLSession(configuration: configuration)
    }()

    func watch(_ pane: UUID, web: WKWebView) {
        watches[pane] = Watch(web: web)
        if timer == nil {
            timer = Timer(timeInterval: 6, repeats: true) { _ in MainActor.assumeIsolated { PreviewWatcher.shared.tick() } }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    private func tick() {
        watches = watches.filter { $0.value.web != nil }
        for (pane, watch) in watches {
            guard let model = SessionGroups.shared.pane(pane), model.autoReload,
                  let web = watch.web, web.window != nil,
                  let url = model.url.flatMap(URL.init(string:)) else { continue }
            Task {
                guard let result = try? await session.data(from: url) else { return }
                let data = result.0
                let print = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                await MainActor.run {
                    if let old = watch.fingerprint, old != print { watch.web?.reload() }
                    watch.fingerprint = print
                }
            }
        }
    }
}

/// The preview's own buttons in the pane header: reload on changes, phone width.
struct PreviewControls: View {
    let pane: SessionPane
    let groupID: UUID

    var body: some View {
        Button {
            change { $0.autoReload.toggle() }
        } label: {
            Image(systemName: pane.autoReload ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                .foregroundStyle(pane.autoReload ? Color.accentColor : Color.secondary)
        }
        .help(pane.autoReload ? "Se recarga sola cuando el sitio cambia (clic para apagar)" : "Recargar sola cuando el sitio cambie")
        Button {
            change { $0.mobile.toggle() }
        } label: {
            Image(systemName: pane.mobile ? "iphone.gen3" : "desktopcomputer")
        }
        .help(pane.mobile ? "Vista de celular (clic para escritorio)" : "Vista de escritorio (clic para celular)")
    }

    private func change(_ edit: (inout SessionPane) -> Void) {
        var copy = pane
        edit(&copy)
        SessionGroups.shared.change(groupID) { $0.replace(copy) }
    }
}

/// "Vista web" in Add session: an address, or one of your Lovable sites.
struct PreviewPicker: View {
    let groupID: UUID
    let done: () -> Void
    @ObservedObject private var groups = SessionGroups.shared
    @State private var address = ""
    @State private var title = ""
    @State private var error: String?

    private var sites: [(name: String, url: String)] {
        guard let model = LoveployBridge.model else { return [] }
        return model.rows.compactMap { row in
            guard let url = row.details?.url, !url.isEmpty else { return nil }
            return (row.summary.label, url.hasPrefix("http") ? url : "https://" + url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Una página junto a tus sesiones: el sitio en el que trabajas, su versión publicada o un servidor local (localhost). Ponla al lado de la sesión de Claude Code con el acomodo «Columnas».")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Dirección").frame(width: 70, alignment: .leading)
                TextField("https://… o localhost:5173", text: $address).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Nombre").frame(width: 70, alignment: .leading)
                TextField("Opcional", text: $title).textFieldStyle(.roundedBorder)
                Button("Agregar") { add(address, title) }
                    .buttonStyle(.borderedProminent)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if !sites.isEmpty {
                Text("Tus sitios de Lovable").font(.headline).padding(.top, 4)
                List(sites, id: \.url) { site in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(site.name).lineLimit(1)
                            Text(site.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Agregar") { add(site.url, site.name) }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            } else {
                Spacer()
            }
            HStack { Spacer(); Button("Cerrar") { done() }.keyboardShortcut(.cancelAction) }
        }
    }

    private func add(_ address: String, _ name: String) {
        guard let pane = SessionPane.preview(address, title: name) else {
            error = "Pon una dirección web (https://… o localhost:puerto)."
            return
        }
        error = nil
        if groups.add(pane, to: groupID) {
            self.address = ""
            title = ""
        }
    }
}
