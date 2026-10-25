import LoveployCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var githubToken = ""
    @State private var isConnecting = false
    @State private var githubError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            lovableSection
            Divider()
            turboSection
            Divider()
            githubSection
            Divider()
            preferencesSection
        }
        .padding(12)
    }

    private var lovableSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Cuenta de Lovable").font(.subheadline.bold())
            if model.isSignedIn {
                HStack {
                    Label(model.account ?? "Sesión iniciada", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Cerrar sesión", role: .destructive) { model.signOut() }
                        .buttonStyle(.borderless)
                }
                Text("Loveploy usa tu sesión de lovable.dev, como el navegador. No necesita API keys.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("Sin sesión").foregroundStyle(.secondary)
                    Spacer()
                    Button("Iniciar sesión") { model.signIn() }
                }
            }
        }
    }

    private var turboSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { model.turbo }, set: { model.turbo = $0 })) {
                Label("Turbo: publicar automáticamente", systemImage: "bolt.fill")
                    .font(.subheadline.bold())
            }
            .toggleStyle(.switch)
            Picker("Publicar cuando lleve sin cambios", selection: Binding(
                get: { model.turboDelayMinutes },
                set: { model.turboDelayMinutes = $0 }
            )) {
                Text("Al momento").tag(0)
                Text("2 min").tag(2)
                Text("5 min").tag(5)
                Text("10 min").tag(10)
                Text("30 min").tag(30)
            }
            .disabled(!model.turbo)
            Text("Revisa cada 2 minutos y publica los proyectos desactualizados que no excluiste, cuando ya no están cambiando. Si una publicación falla, no la reintenta hasta que haya un cambio nuevo.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("GitHub (opcional)").font(.subheadline.bold())
            if model.hasGitHub {
                HStack {
                    Label(model.githubLogin.map { "Conectado como @\($0)" } ?? "Conectado", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Desconectar", role: .destructive) { model.disconnectGitHub() }
                        .buttonStyle(.borderless)
                }
            } else {
                Text("Lovable ya dice qué repo usa cada proyecto y si GitHub va adelante. Con un token de GitHub, además ves qué commits faltan por publicar y puedes compilar las apps de iOS en tus Mac mini.")
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
                Text("Para ver commits basta lectura de «Contents». Para TestFlight en Mac mini: «Actions», «Contents» y «Workflows» con escritura (o los scopes «repo» y «workflow» en un token clásico).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Abrir al iniciar sesión en la Mac", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.launchAtLogin = $0 }
            ))
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
}
