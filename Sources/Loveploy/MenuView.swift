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
            } else {
                content
            }
        }
        .frame(width: 400)
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
            .disabled(model.isRefreshing || model.isDeploying || model.keys.isEmpty)
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
                .frame(minHeight: 120, maxHeight: 380)
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
            StateCount(state: .unknown, count: model.count(.unknown))
            StateCount(state: .upToDate, count: model.count(.upToDate))
            StateCount(state: .unpublished, count: model.count(.unpublished))
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
                Text("Todo está publicado y al día.")
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
                Text(row.summary.displayName).lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let github = row.github {
                    GitHubLine(row: row, github: github)
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
        if case .failed(let message) = model.progress[row.id] {
            return message
        }
        var parts = [row.workspaceName]
        if let edited = row.summary.lastEditedAt {
            parts.append("editado \(edited.formatted(.relative(presentation: .named)))")
        }
        if let published = row.record?.publishedAt {
            parts.append("publicado \(published.formatted(.relative(presentation: .named)))")
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
        if let url = row.record?.url.flatMap(URL.init(string:)) {
            Button("Abrir sitio publicado") { NSWorkspace.shared.open(url) }
        }
        if let url = row.previewUrl.flatMap(URL.init(string:)) {
            Button("Abrir preview") { NSWorkspace.shared.open(url) }
        }
        if row.state == .unknown || row.state == .outdated {
            Button("Marcar como al día (sin publicar)") { model.markUpToDate(row) }
        }
        if model.hasGitHub {
            Divider()
            if let url = row.github?.repoURL.flatMap(URL.init(string:)) {
                Button("Abrir repo en GitHub") { NSWorkspace.shared.open(url) }
            }
            Menu(row.github == nil ? "Vincular repo de GitHub" : "Cambiar repo de GitHub") {
                ForEach(model.repoChoices(for: row)) { repo in
                    Button(repo.fullName) { model.link(row, to: repo) }
                }
            }
            if row.github != nil {
                Button("Desvincular repo") { model.unlink(row) }
            }
        }
        Button("Copiar ID del proyecto") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.id, forType: .string)
        }
    }
}

/// "owner/repo · 3 commits nuevos: «Fix header»", or a warning when Lovable is behind GitHub.
struct GitHubLine: View {
    let row: ProjectRow
    let github: GitHubStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(text).lineLimit(2)
        }
        .font(.caption2)
        .foregroundStyle(color)
        .help(tooltip)
    }

    private var repoName: String {
        github.link.fullName + (github.link.branch.map { "@\($0)" } ?? "")
    }

    private var behind: Bool { github.lovableIsBehind(latestCommitSha: row.latestCommitSha) }

    private var icon: String {
        if github.error != nil || behind { return "exclamationmark.triangle.fill" }
        return "arrow.triangle.branch"
    }

    private var color: Color {
        if github.error != nil || behind { return .orange }
        if let commits = github.newCommits, !commits.isEmpty { return .primary }
        return .secondary
    }

    private var text: String {
        if let error = github.error {
            return "\(repoName): \(error)"
        }
        if behind {
            return "\(repoName) tiene cambios que Lovable aún no sincroniza; publicar no los incluiría"
        }
        if let commits = github.newCommits, let latest = commits.first {
            let count = commits.count == 1 ? "1 commit nuevo" : "\(commits.count) commits nuevos"
            return "\(repoName) · \(count): «\(latest.headline)»"
        }
        if github.newCommits == nil, row.record != nil, row.record?.githubSha == nil, !github.sharesCommits {
            return "\(repoName) · se seguirá desde la próxima publicación"
        }
        if let head = github.head {
            return "\(repoName) · «\(head.headline)»"
        }
        return repoName
    }

    private var tooltip: String {
        var lines = ["Repo: \(github.link.fullName)"]
        switch github.link.source {
        case .commit: lines.append("Vinculado por commit (Lovable y GitHub comparten historial)")
        case .name: lines.append("Vinculado por nombre; si no es el repo correcto, cámbialo con clic derecho")
        case .manual: lines.append("Vinculado a mano")
        }
        if let commits = github.newCommits, !commits.isEmpty {
            lines.append("")
            lines.append(contentsOf: commits.prefix(10).map { "• \($0.headline)" })
            if commits.count > 10 { lines.append("… y \(commits.count - 10) más") }
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
