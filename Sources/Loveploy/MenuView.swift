import AppKit
import LoveployCore
import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.showingSettings {
                SettingsView()
            } else if !model.isSignedIn {
                signedOut
            } else {
                content
            }
        }
        .frame(width: 420)
        .onAppear { model.refreshIfStale() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Loveploy").font(.headline)
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Spacer()
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
                .frame(minHeight: 120, maxHeight: 400)
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
        .padding(12)
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
