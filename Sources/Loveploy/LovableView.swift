import AppKit
import LoveployCore
import SwiftUI

/// Lovable projects: what to publish, Turbo, GitHub and iOS. Shown in its own window from the panel.
struct LovableView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.showingSettings {
                LovableSettingsView()
            } else if !model.isSignedIn {
                signedOut
            } else {
                content
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { model.refreshIfStale() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Lovable").font(.headline)
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if model.isSignedIn {
                Button {
                    model.turbo.toggle()
                } label: {
                    Label("Turbo", systemImage: model.turbo ? "bolt.fill" : "bolt.slash")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(model.turbo ? Color.yellow.opacity(0.3) : Color.primary.opacity(0.06)))
                        .foregroundStyle(model.turbo ? Color.orange : Color.secondary)
                }
                .help(model.turbo
                    ? "Turbo activo: publica solo lo desactualizado cuando lleva \(model.turboDelayMinutes) min sin cambios"
                    : "Activar Turbo: publicar automáticamente lo desactualizado")
            }
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Actualizar lista")
            .disabled(model.isRefreshing || model.isDeploying || !model.isSignedIn)
            Button {
                model.showingSettings.toggle()
            } label: {
                Image(systemName: model.showingSettings ? "xmark" : "gearshape")
            }
            .help(model.showingSettings ? "Cerrar ajustes" : "Ajustes")
        }
        .buttonStyle(.borderless)
        .padding(12)
    }

    private var signedOut: some View {
        VStack(spacing: 12) {
            Image(systemName: "heart.circle").font(.system(size: 36)).foregroundStyle(.pink)
            Text("Inicia sesión en Lovable").font(.headline)
            Text("Se abre lovable.dev para que entres como siempre (Google, GitHub o correo). Loveploy usa esa misma sesión para ver y publicar tus proyectos.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ForEach(model.errors, id: \.self) { error in
                Text(error).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            Button("Iniciar sesión en Lovable") { model.signIn() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Button("Salir de Loveploy") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            summary
            Picker("", selection: $model.filter) {
                ForEach(AppModel.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.visibleRows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.visibleRows) { row in
                            ProjectRowView(row: row)
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: .infinity)
            }

            ForEach(model.errors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)

        Divider()
        footer
    }

    private var summary: some View {
        HStack(spacing: 12) {
            StateCount(state: .outdated, count: model.count(.outdated))
            StateCount(state: .upToDate, count: model.count(.upToDate))
            StateCount(state: .unpublished, count: model.count(.unpublished))
            if model.count(.unknown) > 0 {
                StateCount(state: .unknown, count: model.count(.unknown))
            }
            if model.rows.contains(where: { $0.ios != nil }) {
                HStack(spacing: 4) {
                    Image(systemName: "iphone")
                    Text("\(model.iosNeedingUpload) iOS sin subir")
                }
                .foregroundStyle(model.iosNeedingUpload > 0 ? Color.orange : Color.secondary)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 6) {
            if model.rows.isEmpty && model.isRefreshing {
                Text("Cargando proyectos…")
            } else if model.filter == .pending {
                Image(systemName: "checkmark.seal.fill").font(.title).foregroundStyle(.green)
                Text("Todo lo publicado está al día.")
            } else if model.filter == .ios {
                Image(systemName: "iphone.slash").font(.title)
                Text(model.hasHub ? "Ningún proyecto tiene app de iOS." : "Ningún proyecto tiene app de iOS en Lovable. Conecta Blender Dev Apps en Ajustes para ver las de Xcode Cloud.")
                    .multilineTextAlignment(.center)
            } else {
                Text("No hay proyectos.")
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    private var footer: some View {
        HStack {
            Menu {
                Button("Seleccionar todos los visibles") { model.selectAllVisible(true) }
                Button("Quitar todos los visibles") { model.selectAllVisible(false) }
                Divider()
                Button("Salir de Loveploy") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if let last = model.lastRefresh {
                Text("Actualizado \(last.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.filter == .ios {
                Button {
                    model.requestTestFlight(model.testFlightCandidates)
                } label: {
                    Label(testFlightTitle, systemImage: "airplane")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.hasHub || model.testFlightCandidates.isEmpty)
                .help(model.hasHub
                    ? "Pide a Blender Dev Apps TestFlight de las apps con cambios nativos sin compilar."
                    : "Conecta Blender Dev Apps en Ajustes para pedir TestFlight")
            } else {
            Button {
                model.deploySelected()
            } label: {
                if model.isDeploying {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Publicando…")
                    }
                } else {
                    Text(publishTitle)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isDeploying || model.selectedRows.isEmpty)
            }
        }
        .padding(12)
    }

    private var testFlightTitle: String {
        let count = model.testFlightCandidates.count
        let dots = model.testFlightAutomatic ? "" : "…"
        return count == 1 ? "Pedir 1 TestFlight\(dots)" : "Pedir \(count) TestFlight\(dots)"
    }

    private var publishTitle: String {
        let count = model.selectedRows.count
        return count == 1 ? "Publicar 1 proyecto" : "Publicar \(count) proyectos"
    }
}

struct StateCount: View {
    let state: DeployState
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(state.color).frame(width: 7, height: 7)
            Text("\(count) \(state.label.lowercased())")
        }
        .foregroundStyle(count == 0 ? .secondary : .primary)
    }
}

struct ProjectRowView: View {
    @EnvironmentObject var model: AppModel
    let row: ProjectRow

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { model.isSelected(row) },
                set: { model.setSelected($0, for: row) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(model.isDeploying)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.summary.label).lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let git = row.git {
                    GitLine(row: row, git: git)
                }
                if let ios = row.ios {
                    IOSLine(ios: ios)
                }
                ForEach(row.hub) { app in
                    HubLine(
                        app: app,
                        request: model.testFlightRequests[app.slug],
                        notice: model.hubNotices[app.slug],
                        automatic: model.turbo && model.testFlightAutomatic && model.testFlightAutopilot.wasRequested(app),
                        showName: row.hub.count > 1 || app.label != row.summary.label
                    )
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        .contextMenu { contextMenu }
    }

    private var subtitle: String {
        switch model.progress[row.id] {
        case .failed(let message): return message
        case .publishing(let step?): return step
        default: break
        }
        if let error = row.error {
            return error
        }
        var parts = [row.workspace.displayName]
        if let edited = row.summary.editedAt {
            parts.append("editado \(edited.formatted(.relative(presentation: .named)))")
        }
        if row.details?.publishedDeployment?.secretsChanged == true {
            parts.append("cambiaron los secretos")
        }
        if model.turboGaveUp(on: row) {
            parts.append("⚡ falló; Turbo espera un cambio nuevo")
        } else if let date = model.turboPublishDate(for: row) {
            parts.append(date <= Date() ? "⚡ se publica ya" : "⚡ se publica \(date.formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.progress[row.id] {
        case .queued:
            Image(systemName: "clock").foregroundStyle(.secondary).help("En cola")
        case .publishing:
            ProgressView().controlSize(.small)
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Publicado")
        case .failed(let message):
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(message)
        case .timedOut:
            Image(systemName: "hourglass").foregroundStyle(.orange).help("Sigue en proceso en Lovable")
        case nil:
            Text(row.state.label)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(row.state.color.opacity(0.18)))
                .foregroundStyle(row.state.color)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Abrir en Lovable") {
            NSWorkspace.shared.open(URL(string: "https://lovable.dev/projects/\(row.id)")!)
        }
        if let url = row.liveURL.flatMap(URL.init(string:)) {
            Button("Abrir sitio publicado") { NSWorkspace.shared.open(url) }
        }
        if let url = row.git?.url.flatMap(URL.init(string:)) {
            Button("Abrir repo en GitHub") { NSWorkspace.shared.open(url) }
        }
        if row.ios != nil {
            Button("Abrir App Store Connect") {
                NSWorkspace.shared.open(URL(string: "https://appstoreconnect.apple.com/apps")!)
            }
        }
        if model.hasHub, !row.hub.isEmpty {
            Divider()
            ForEach(row.hub) { app in
                Button("Pedir TestFlight de \(app.label)\(model.testFlightAutomatic ? "" : "…")") { model.requestTestFlight([app]) }
                    .disabled(model.testFlightRequests[app.slug] == .sending || app.testFlight == .building)
                if app.canSubmitForReview {
                    Button("Enviar \(app.label) a revisión de App Store…") { model.submitForReview(app) }
                }
                if app.hasAndroid {
                    Button("Compilar Android de \(app.label)") { model.requestAndroid(app) }
                }
            }
        }
        Divider()
        Button("Copiar ID del proyecto") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.id, forType: .string)
        }
    }
}

/// "owner/repo · 3 commits sin publicar: «Fix header»", or a warning when GitHub is ahead of Lovable.
struct GitLine: View {
    let row: ProjectRow
    let git: GitStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: git.remoteAhead ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
            Text(text).lineLimit(2)
        }
        .font(.caption2)
        .foregroundStyle(color)
        .help(tooltip)
    }

    private var color: Color {
        if git.remoteAhead { return .orange }
        if let commits = git.newCommits, !commits.isEmpty { return .primary }
        return .secondary
    }

    private var text: String {
        switch git.syncState {
        case "remote_ahead":
            let count = git.behind.map { $0 == 1 ? "1 commit" : "\($0) commits" } ?? "commits"
            return "\(git.repo) tiene \(count) que Lovable aún no sincroniza; publicar no los incluiría"
        case "diverged":
            return "Lovable y \(git.repo) se separaron; revisa la sincronización en Lovable"
        default:
            break
        }
        if let commits = git.newCommits, let latest = commits.first {
            let count = commits.count == 1 ? "1 commit sin publicar" : "\(commits.count) commits sin publicar"
            return "\(git.repo) · \(count): «\(latest.headline)»"
        }
        switch git.syncState {
        case "in_sync": return "\(git.repo) · en sync con Lovable"
        case "lovable_ahead": return "\(git.repo) · Lovable tiene cambios por subir a GitHub"
        default: return git.repo
        }
    }

    private var tooltip: String {
        var lines = ["Repo: \(git.repo)" + (git.branch.map { " (\($0))" } ?? "")]
        if let commits = git.newCommits, !commits.isEmpty {
            lines.append("")
            lines.append(contentsOf: commits.prefix(10).map { "• \($0.headline)" })
            if commits.count > 10 { lines.append("… y \(commits.count - 10) más") }
        } else if git.newCommits == nil, row.state == .outdated {
            lines.append("Conecta GitHub en Ajustes para ver qué commits faltan.")
        }
        return lines.joined(separator: "\n")
    }
}

/// "TestFlight 1.2 (14) al día · App Store 1.1 (12) en vivo, 1.2 (14) en revisión"
struct IOSLine: View {
    let ios: IOSStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: testFlightIcon)
                Text(testFlightText).lineLimit(2)
            }
            .foregroundStyle(testFlightColor)
            HStack(spacing: 4) {
                Image(systemName: "applelogo")
                Text(appStoreText).lineLimit(2)
            }
            .foregroundStyle(ios.appStoreBehind ? Color.primary : Color.secondary)
        }
        .font(.caption2)
    }

    private var upload: String { ios.latestUpload.map { " \($0.label)" } ?? "" }

    private var testFlightIcon: String {
        switch ios.testFlight {
        case .upToDate: return "airplane"
        case .uploading: return "arrow.up.circle"
        case .failed: return "xmark.octagon.fill"
        case .outdated, .none: return "exclamationmark.triangle.fill"
        }
    }

    private var testFlightColor: Color {
        switch ios.testFlight {
        case .upToDate: return .secondary
        case .uploading: return .blue
        case .failed: return .red
        case .outdated, .none: return .orange
        }
    }

    private var testFlightText: String {
        switch ios.testFlight {
        case .upToDate: return "TestFlight\(upload) al día con el último código"
        case .outdated: return "TestFlight\(upload) desactualizado: falta subir el último código"
        case .uploading: return "Subiendo a TestFlight…"
        case .failed: return "Falló la última subida a TestFlight"
        case .none: return "App de iOS sin subir a TestFlight"
        }
    }

    private var appStoreText: String {
        guard let live = ios.live else {
            if let latest = ios.latestUpload {
                return "App Store: sin versión pública · \(latest.label) \(latest.stateLabel)"
            }
            return "App Store: sin versión pública"
        }
        guard ios.appStoreBehind, let latest = ios.latestUpload else {
            return "App Store \(live.label) en vivo, al día con TestFlight"
        }
        return "App Store \(live.label) en vivo · \(latest.label) \(latest.stateLabel)"
    }
}

/// An app from the Blender Dev Apps catalog: its TestFlight and App Store, as the hub sees them.
struct HubLine: View {
    let app: HubApp
    let request: AppModel.TestFlightRequest?
    let notice: String?
    /// Turbo already asked for this pending commit.
    let automatic: Bool
    let showName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(testFlightText).lineLimit(2)
            }
            .foregroundStyle(color)
            if let store = app.appStore {
                HStack(spacing: 4) {
                    Image(systemName: "applelogo")
                    Text("\(prefix)App Store \(store.label) \(store.estadoLabel)").lineLimit(1)
                }
                .foregroundStyle(store.estado == "rechazado" ? Color.red : Color.secondary)
            }
            if let play = app.playStore {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                    Text("\(prefix)Google Play \(play.label) \(play.estadoLabel)").lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
            if let notice {
                Text(notice).lineLimit(2).foregroundStyle(.blue)
            }
        }
        .font(.caption2)
        .help(tooltip)
    }

    private var prefix: String { showName ? "\(app.label) · " : "" }

    private var icon: String {
        switch (request, app.testFlight) {
        case (.failed?, _), (_, .failed): return "xmark.octagon.fill"
        case (.sending?, _), (.sent?, _), (_, .building): return "arrow.up.circle"
        case (_, .pending), (_, .none): return "exclamationmark.triangle.fill"
        case (_, .upToDate): return "airplane"
        }
    }

    private var color: Color {
        switch (request, app.testFlight) {
        case (.failed?, _), (_, .failed): return .red
        case (.sending?, _), (.sent?, _), (_, .building): return .blue
        case (_, .pending): return .orange
        default: return .secondary
        }
    }

    private var testFlightText: String {
        switch request {
        case .sending?: return "\(prefix)Pidiendo TestFlight a Blender Dev Apps…"
        case .sent?: return "\(prefix)TestFlight pedido a Xcode Cloud"
        case .failed(let message)?: return "\(prefix)No se pudo pedir TestFlight: \(message)"
        case nil: break
        }
        switch app.testFlight {
        case .upToDate:
            return "\(prefix)TestFlight al día con los cambios nativos"
        case .pending where automatic:
            return "\(prefix)⚡ Turbo ya pidió TestFlight de este cambio"
        case .pending:
            let since = app.iosPendienteDesde.flatMap(parseDate).map { " desde \($0.formatted(.relative(presentation: .named)))" } ?? ""
            let message = app.iosPendienteMensaje.map { ": «\($0)»" } ?? ""
            return "\(prefix)TestFlight desactualizado\(since)\(message)"
        case .building:
            return "\(prefix)Xcode Cloud compilando para TestFlight…"
        case .failed:
            return "\(prefix)Falló el último build de TestFlight"
        case .none:
            return "\(prefix)Nunca se ha compilado para TestFlight desde la consola"
        }
    }

    private var tooltip: String {
        var lines = ["Blender Dev Apps: \(app.slug)"]
        if let commit = app.iosCompiladoCommit { lines.append("Último compilado: \(commit.prefix(7))") }
        if let commit = app.iosPendienteCommit { lines.append("Pendiente: \(commit.prefix(7))") }
        for missing in app.faltantes ?? [] where missing.peso != "aviso" {
            lines.append("• \(missing.que)")
        }
        return lines.joined(separator: "\n")
    }

    private func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

extension DeployState {
    var color: Color {
        switch self {
        case .outdated: return .orange
        case .unknown: return .yellow
        case .upToDate: return .green
        case .unpublished: return .gray
        }
    }
}
