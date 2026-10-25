import LoveployCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var label = ""
    @State private var key = ""
    @State private var isAdding = false
    @State private var addError: String?
    @State private var githubToken = ""
    @State private var isConnecting = false
    @State private var githubError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            keysSection
            Divider()
            addKeySection
            Divider()
            githubSection
            Divider()
            preferencesSection
        }
        .padding(12)
    }

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API keys de Lovable").font(.subheadline.bold())
            if model.keys.isEmpty {
                Text("Agrega una API key para ver tus proyectos. Una por workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.keys) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.label)
                        Text(entry.masked).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        model.removeKey(entry)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Quitar")
                }
            }
        }
    }

    private var addKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agregar API key").font(.subheadline.bold())
            TextField("Nombre (opcional)", text: $label)
            SecureField("lov_…", text: $key)
            if let addError {
                Text(addError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Link("Crear una key en Lovable", destination: URL(string: "https://lovable.dev/settings/api-keys")!)
                    .font(.caption)
                Spacer()
                Button("Agregar") { add() }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)
            }
            Text("Permisos necesarios: projects:write y workspaces:read. Requiere plan Business o Enterprise.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .textFieldStyle(.roundedBorder)
    }

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GitHub").font(.subheadline.bold())
            if model.hasGitHub {
                HStack {
                    Label(model.githubLogin.map { "Conectado como @\($0)" } ?? "Conectado", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Desconectar", role: .destructive) { model.disconnectGitHub() }
                        .buttonStyle(.borderless)
                }
                Text("\(model.githubRepos.count) repos visibles. Los proyectos se vinculan solos por commit o por nombre; cámbialos con clic derecho.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Conecta GitHub para detectar cambios en los repos sincronizados con Lovable y ver qué commits faltan por publicar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("Token de GitHub (github_pat_… o ghp_…)", text: $githubToken)
                    .textFieldStyle(.roundedBorder)
                if let githubError {
                    Text(githubError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Link("Crear un token", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                        .font(.caption)
                    Spacer()
                    Button("Conectar") { connectGitHub() }
                        .disabled(githubToken.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
                }
                Text("Solo lectura: permisos «Contents» y «Metadata» en los repos (o el scope «repo» en un token clásico).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Abrir al iniciar sesión", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.launchAtLogin = $0 }
            ))
            Button("Marcar todos los «Sin registro» como al día") {
                model.markAllUnknownUpToDate()
            }
            .help("Úsalo la primera vez si ya sabes que todo lo publicado está al día.")
            .disabled(model.count(.unknown) == 0)
            Button("Volver a incluir proyectos excluidos (\(model.state.excluded.count))") {
                model.resetExclusions()
            }
            .disabled(model.state.excluded.isEmpty)
        }
    }

    private func connectGitHub() {
        isConnecting = true
        githubError = nil
        Task {
            do {
                try await model.connectGitHub(token: githubToken)
                githubToken = ""
            } catch {
                githubError = error.localizedDescription
            }
            isConnecting = false
        }
    }

    private func add() {
        isAdding = true
        addError = nil
        Task {
            do {
                try await model.addKey(label: label, key: key)
                label = ""
                key = ""
            } catch {
                addError = error.localizedDescription
            }
            isAdding = false
        }
    }
}
