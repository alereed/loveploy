import LoveployCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var githubToken = ""
    @State private var isConnecting = false
    @State private var githubError: String?
    @State private var hubURL = ""
    @State private var hubKey = ""
    @State private var isConnectingHub = false
    @State private var hubError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            lovableSection
            Divider()
            turboSection
            Divider()
            hubSection
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

    private var hubSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Blender Dev Apps (iOS)").font(.subheadline.bold())
            if model.hasHub {
                HStack {
                    Label(model.hubAppCount.map { "Conectado · \($0) apps de iOS" } ?? "Conectado", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Desconectar", role: .destructive) { model.disconnectHub() }
                        .buttonStyle(.borderless)
                }
                Picker("TestFlight", selection: Binding(
                    get: { model.testFlightAutomatic },
                    set: { model.testFlightAutomatic = $0 }
                )) {
                    Text("Preguntar siempre (tope 7/día)").tag(false)
                    Text("Automático con Turbo, sin tope").tag(true)
                }
                Text(model.testFlightAutomatic
                    ? "Con Turbo activo, pide TestFlight solo cuando hay cambios nativos sin compilar que ya llevan el tiempo de Turbo sin moverse, una vez por cambio. Enviar a revisión de App Store siempre pregunta."
                    : "Antes de pedir TestFlight muestra cuántos van hoy del tope de 7 y el estado de los checks. Enviar a revisión de App Store siempre pregunta.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Conecta el hub para ver, por app, si TestFlight tiene los últimos cambios nativos y qué versión está en la App Store, y para pedir builds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("URL del MCP de DevOps (https://…)", text: $hubURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("Llave con alcance devops", text: $hubKey)
                    .textFieldStyle(.roundedBorder)
                if let hubError {
                    Text(hubError).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    Button("Conectar") { connectHub() }
                        .disabled(hubURL.isEmpty || hubKey.trimmingCharacters(in: .whitespaces).isEmpty || isConnectingHub)
                }
            }
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
                Text("Lovable ya dice qué repo usa cada proyecto y si GitHub va adelante. Con un token de GitHub, además ves qué commits faltan por publicar y, al pedir TestFlight, si los checks del Mac mini están en verde.")
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
                Text("Solo lectura: «Contents», «Actions» y «Metadata» (o el scope «repo» en un token clásico).")
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

    private func connectHub() {
        isConnectingHub = true
        hubError = nil
        Task {
            do {
                try await model.connectHub(url: hubURL, key: hubKey)
                hubURL = ""
                hubKey = ""
            } catch {
                hubError = error.localizedDescription
            }
            isConnectingHub = false
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
