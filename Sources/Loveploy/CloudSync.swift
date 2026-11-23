import AppKit
import CryptoKit
import Foundation
import LoveployCore
import SwiftUI

// Blender Play: keeps your groups and their layout, projects, Chrome shortcuts, preferences,
// and the time and tokens of every Mac in the cloud, so every Mac you use shows the same.
//
// Everything is encrypted on the Mac (AES-GCM) with a key derived from a code only your Macs
// know; the server stores ciphertext under the hash of a second key derived from the same
// code. The code lives in the Keychain. Message queues are not synced, on purpose: two Macs
// would send the same message twice.

/// The cloud end: three functions in the database, nothing else.
enum CloudAPI {
    static let base = URL(string: "https://uuifrmxxmspvhllkfkzy.supabase.co/rest/v1/rpc/")!
    /// The project's publishable key: meant to be public, it only reaches the three
    /// blenderplay_sync functions; the data behind them is encrypted.
    static let publishableKey = "sb_publishable_AiROFpvDBxmOC99KLa5Zwg_Xne118xL"

    struct Row: Decodable {
        let kind: String
        let payload: String
        let device: String
        let updated_at: String
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func call(_ function: String, _ body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent(function))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw Failure(message: "La nube respondió \(status)" + (detail.map { ": \($0)" } ?? ""))
        }
        return data
    }

    static func put(key: String, kind: String, payload: String, device: String) async throws -> String {
        let data = try await call("blenderplay_sync_put", ["p_key": key, "p_kind": kind, "p_payload": payload, "p_device": device])
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String) ?? ""
    }

    static func get(key: String, since: String? = nil) async throws -> [Row] {
        var body: [String: Any] = ["p_key": key]
        if let since { body["p_since"] = since }
        return try JSONDecoder().decode([Row].self, from: try await call("blenderplay_sync_get", body))
    }

    @discardableResult
    static func delete(key: String) async throws -> Int {
        let data = try await call("blenderplay_sync_delete", ["p_key": key])
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? Int) ?? 0
    }

    /// "2026-11-23T02:34:39.126123+00:00" → seconds, for ordering versions (Postgres returns
    /// UTC with up to six decimals, trimmed).
    static func seconds(_ stamp: String) -> Double {
        let parts = stamp.split(separator: "+", maxSplits: 1)[0].split(separator: ".", maxSplits: 1)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        guard let whole = formatter.date(from: String(parts[0]).replacingOccurrences(of: " ", with: "T")) else { return 0 }
        let fraction = parts.count > 1 ? Double("0." + parts[1].prefix { $0.isNumber }) ?? 0 : 0
        return whole.timeIntervalSince1970 + fraction
    }
}

/// The two keys that come out of a sync code.
struct CloudKeys {
    /// Sent to the server, which keeps only its hash.
    let access: String
    /// Never leaves the Mac.
    let encryption: SymmetricKey

    init(_ code: SyncCode) {
        let master = SymmetricKey(data: Data(code.bytes))
        let salt = Data("blenderplay-sync".utf8)
        let access = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: Data("access".utf8), outputByteCount: 32)
        self.access = access.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        encryption = HKDF<SHA256>.deriveKey(inputKeyMaterial: master, salt: salt, info: Data("encrypt".utf8), outputByteCount: 32)
    }

    /// Compressed, encrypted and tied to its kind (a payload can't be passed off as another).
    func seal(_ data: Data, kind: String) throws -> String {
        let packed = (try? (data as NSData).compressed(using: .lzfse) as Data) ?? data
        guard let box = try AES.GCM.seal(packed, using: encryption, authenticating: Data(kind.utf8)).combined else {
            throw CloudAPI.Failure(message: "No se pudo cifrar")
        }
        return box.base64EncodedString()
    }

    func open(_ payload: String, kind: String) throws -> Data {
        guard let box = Data(base64Encoded: payload) else { throw CloudAPI.Failure(message: "Contenido dañado") }
        let packed = try AES.GCM.open(try AES.GCM.SealedBox(combined: box), using: encryption, authenticating: Data(kind.utf8))
        return (try? (packed as NSData).decompressed(using: .lzfse) as Data) ?? packed
    }
}

@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    @Published private(set) var enabled = false
    @Published private(set) var busy = false
    @Published private(set) var lastSync: Date?
    @Published private(set) var lastError: String?
    /// Other Macs that share this code (by the time and tokens they upload).
    @Published private(set) var otherMacs = 0

    private var keys: CloudKeys?
    private var timer: Timer?
    private var watchingActivation = false
    private var lastBulkPush = Date.distantPast
    private let defaults = UserDefaults.standard
    private var remoteLedgers: [String: UsageLedger] = [:]
    private var remoteActivity: [String: ActivityLog] = [:]

    /// This Mac, for the cloud.
    let device: String = {
        let key = "blenderplay.device"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    /// The code to type on another Mac (from the Keychain).
    var code: String? { Keychain.loadSyncCode() }

    private init() {}

    func start() {
        guard let text = Keychain.loadSyncCode(), let code = SyncCode(text: text) else { return }
        keys = CloudKeys(code)
        enabled = true
        schedule()
        syncNow()
    }

    // MARK: Turning it on and off

    /// First Mac: a new code, and everything goes up.
    func enable() {
        let code = SyncCode.random()
        Keychain.saveSyncCode(code.text)
        resetMarks()
        start()
    }

    /// Another Mac: uses the code of the first. What's on both sides is kept (lists are
    /// joined), then this Mac follows the cloud.
    func join(_ text: String) -> Bool {
        guard let code = SyncCode(text: text) else { return false }
        Keychain.saveSyncCode(code.text)
        keys = CloudKeys(code)
        resetMarks()
        enabled = true
        Task { await self.run(joining: true) }
        schedule()
        return true
    }

    /// Stops syncing on this Mac; the cloud copy stays for your other Macs.
    func disable() {
        timer?.invalidate()
        timer = nil
        keys = nil
        enabled = false
        Keychain.saveSyncCode(nil)
        remoteLedgers = [:]
        remoteActivity = [:]
        DevClock.shared.setRemote(UsageLedger())
        otherMacs = 0
    }

    /// Deletes everything this code keeps in the cloud (every Mac stops seeing it).
    func deleteCloudData() async {
        guard let keys else { return }
        do {
            try await CloudAPI.delete(key: keys.access)
            disable()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func syncNow() {
        guard enabled, !busy else { return }
        Task { await self.run(joining: false) }
    }

    private func schedule() {
        if !watchingActivation {
            watchingActivation = true
            // Coming back to the app brings what changed on your other Macs.
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { CloudSync.shared.syncNow() }
            }
        }
        guard timer == nil else { return }
        timer = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { CloudSync.shared.syncNow() } }
        RunLoop.main.add(timer!, forMode: .common)
    }

    // MARK: What is synced

    private static let sharedKinds = [SyncKind.groups, SyncKind.projects, SyncKind.chrome, SyncKind.prefs]

    private var deviceTag: String { SyncKind.safeDevice(device) }

    private func fileURL(_ kind: String) -> URL? {
        switch kind {
        case SyncKind.groups: return SessionGroupStore.default().fileURL
        case SyncKind.projects: return JSONFile<[BillingProject]>(named: "projects.json").fileURL
        case SyncKind.chrome: return JSONFile<[ChromeShortcut]>(named: "chrome-shortcuts.json").fileURL
        default: return nil
        }
    }

    /// Preferences that mean the same on any Mac (not which Chrome profiles this Mac has,
    /// nor starting at login).
    private func isSyncedPreference(_ key: String) -> Bool {
        if ["loveploy.chromeProfiles", "loveploy.mainSection"].contains(key) { return false }
        if key.hasPrefix("loveploy.") || key.hasPrefix("usage.") { return true }
        if let setting = Setting(rawValue: key) { return setting != .launchAtLogin }
        return false
    }

    private func preferences() -> Data {
        var values: [String: Any] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where isSyncedPreference(key) {
            if value is String || value is NSNumber || value is [String] { values[key] = value }
        }
        return (try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])) ?? Data()
    }

    private func applyPreferences(_ data: Data) {
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (key, value) in values where isSyncedPreference(key) { defaults.set(value, forKey: key) }
        Engine.shared.onChange?()
    }

    /// What this Mac has now, by kind.
    private func localData() -> [String: Data] {
        var result: [String: Data] = [:]
        for kind in [SyncKind.groups, SyncKind.projects, SyncKind.chrome] {
            if let url = fileURL(kind), let data = try? Data(contentsOf: url) { result[kind] = data }
        }
        result[SyncKind.prefs] = preferences()
        // Time and tokens change all the time: at most every five minutes.
        if Date().timeIntervalSince(lastBulkPush) > 300 {
            let shareable = DevClock.shared.shareable
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if let ledger = try? encoder.encode(shareable.ledger) { result[SyncKind.ledgerPrefix + deviceTag] = ledger }
            if let activity = try? encoder.encode(shareable.activity) { result[SyncKind.activityPrefix + deviceTag] = activity }
        }
        return result
    }

    private func apply(_ data: Data, kind: String) {
        switch kind {
        case SyncKind.prefs:
            applyPreferences(data)
            markSent(SyncKind.prefs, preferences())
            return
        default:
            guard let url = fileURL(kind) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }
            markSent(kind, data)
        }
        switch kind {
        case SyncKind.groups: SessionGroups.shared.reloadFromDisk()
        case SyncKind.projects: Projects.shared.reloadFromDisk()
        case SyncKind.chrome: ChromeShortcuts.shared.reloadFromDisk()
        default: break
        }
    }

    // MARK: Bookkeeping (what was last sent, and the newest version known per kind)

    private var sentHashes: [String: String] {
        get { defaults.dictionary(forKey: "blenderplay.sync.sent") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "blenderplay.sync.sent") }
    }

    private var known: [String: Double] {
        get { defaults.dictionary(forKey: "blenderplay.sync.known") as? [String: Double] ?? [:] }
        set { defaults.set(newValue, forKey: "blenderplay.sync.known") }
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func markSent(_ kind: String, _ data: Data) {
        sentHashes[kind] = hash(data)
    }

    private func resetMarks() {
        defaults.removeObject(forKey: "blenderplay.sync.sent")
        defaults.removeObject(forKey: "blenderplay.sync.known")
        lastBulkPush = .distantPast
    }

    // MARK: A round: bring what changed elsewhere, then send what changed here

    private func run(joining: Bool) async {
        guard let keys, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let rows = try await CloudAPI.get(key: keys.access)
            var ledgers: [String: UsageLedger] = [:]
            var activities: [String: ActivityLog] = [:]
            for row in rows {
                if let owner = SyncKind.device(of: row.kind) {
                    guard owner != deviceTag, let data = try? keys.open(row.payload, kind: row.kind) else { continue }
                    if row.kind.hasPrefix(SyncKind.ledgerPrefix) {
                        ledgers[owner] = try? JSONDecoder().decode(UsageLedger.self, from: data)
                    } else {
                        activities[owner] = try? JSONDecoder().decode(ActivityLog.self, from: data)
                    }
                    continue
                }
                guard Self.sharedKinds.contains(row.kind), row.device != device else { continue }
                let stamp = CloudAPI.seconds(row.updated_at)
                guard stamp > (known[row.kind] ?? 0), let data = try? keys.open(row.payload, kind: row.kind) else { continue }
                known[row.kind] = stamp
                if joining, row.kind != SyncKind.prefs, let url = fileURL(row.kind), let mine = try? Data(contentsOf: url),
                   let merged = SyncMerge.unionByID(local: mine, remote: data) {
                    apply(merged, kind: row.kind)
                    sentHashes[row.kind] = nil   // the joined list goes back up
                } else {
                    apply(data, kind: row.kind)
                }
            }
            remoteLedgers = ledgers
            remoteActivity = activities
            otherMacs = Set(remoteLedgers.keys).union(remoteActivity.keys).count
            var others = UsageLedger()
            for ledger in remoteLedgers.values { others = others.merging(ledger) }
            for activity in remoteActivity.values { others = activity.merged(into: others) }
            DevClock.shared.setRemote(others)

            var bulkSent = false
            for (kind, data) in localData().sorted(by: { $0.key < $1.key }) where sentHashes[kind] != hash(data) {
                let stamp = try await CloudAPI.put(key: keys.access, kind: kind, payload: try keys.seal(data, kind: kind), device: device)
                markSent(kind, data)
                if SyncKind.device(of: kind) != nil { bulkSent = true } else { known[kind] = CloudAPI.seconds(stamp) }
            }
            if bulkSent || Date().timeIntervalSince(lastBulkPush) > 300 { lastBulkPush = Date() }
            lastSync = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

// MARK: - Self-test (CI): a real round trip against the cloud with a throwaway code

@MainActor
enum CloudSelfTest {
    static func run() {
        Task { @MainActor in
            let keys = CloudKeys(SyncCode.random())
            let original = Data(#"[{"id":"A","name":"Grupo de prueba"}]"#.utf8)
            var ok = false
            do {
                let sealed = try keys.seal(original, kind: SyncKind.groups)
                precondition(!sealed.contains("Grupo"), "the payload must be encrypted")
                _ = try await CloudAPI.put(key: keys.access, kind: SyncKind.groups, payload: sealed, device: "selftest")
                let rows = try await CloudAPI.get(key: keys.access)
                guard let row = rows.first(where: { $0.kind == SyncKind.groups }) else { throw CloudAPI.Failure(message: "no row came back") }
                let back = try keys.open(row.payload, kind: SyncKind.groups)
                // Another code can't read it.
                let stranger = CloudKeys(SyncCode.random())
                let foreign = try await CloudAPI.get(key: stranger.access)
                let deleted = try await CloudAPI.delete(key: keys.access)
                ok = back == original && foreign.isEmpty && deleted == 1
                print("cloud self-test: roundtrip=\(back == original) isolated=\(foreign.isEmpty) deleted=\(deleted)")
            } catch {
                print("cloud self-test: FAIL \(error.localizedDescription)")
            }
            print(ok ? "cloud self-test: OK" : "cloud self-test: FAIL")
            exit(ok ? 0 : 1)
        }
    }
}

// MARK: - The "Nube" section

struct CloudView: View {
    @ObservedObject private var cloud = CloudSync.shared
    @State private var joinCode = ""
    @State private var badCode = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Nube").font(.title2.bold())
                Text("Guarda tus grupos y su acomodo, proyectos, tiempo y tokens, atajos de Chrome y preferencias, y los comparte entre tus Mac. Se cifra en tu Mac antes de subir: sin tu código nadie puede leerlo.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if cloud.enabled {
                    enabledView
                } else {
                    disabledView
                }

                Divider()
                Text("Las colas de mensajes no se sincronizan: si dos Mac las tuvieran, mandarían el mismo mensaje dos veces. Las carpetas de las sesiones locales tienen que existir con la misma ruta en cada Mac para abrirse ahí.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private var enabledView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: cloud.lastError == nil ? "checkmark.icloud" : "exclamationmark.icloud")
                    .foregroundStyle(cloud.lastError == nil ? .green : .orange)
                if cloud.busy {
                    Text("Sincronizando…")
                } else if let error = cloud.lastError {
                    Text(error).foregroundStyle(.orange)
                } else if let date = cloud.lastSync {
                    Text("Sincronizado \(date.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text("Activa")
                }
                Spacer()
                Button("Sincronizar ahora") { cloud.syncNow() }.disabled(cloud.busy)
            }
            Text(cloud.otherMacs == 0 ? "Solo esta Mac por ahora." : "Esta Mac y \(cloud.otherMacs) más: sus horas y tokens se suman a los de aquí.")
                .foregroundStyle(.secondary)

            GroupBox("Tu código (para tus otras Mac)") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(cloud.code ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    HStack {
                        Button("Copiar código") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cloud.code ?? "", forType: .string)
                        }
                        Text("En la otra Mac: Nube → Usar el código de otra Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Guárdalo como una contraseña: quien lo tenga ve tus datos.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            HStack {
                Button("Dejar de sincronizar esta Mac") { cloud.disable() }
                Spacer()
                Button("Borrar mis datos de la nube…", role: .destructive) { confirmDelete = true }
            }
            .confirmationDialog("¿Borrar todo lo de la nube?", isPresented: $confirmDelete) {
                Button("Borrar", role: .destructive) { Task { await cloud.deleteCloudData() } }
            } message: {
                Text("Tus otras Mac dejarán de ver estos datos. Lo de esta Mac se queda.")
            }
        }
    }

    private var disabledView: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("Primera Mac") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sube lo de esta Mac y te da un código para las demás.").foregroundStyle(.secondary)
                    Button("Activar la nube") { cloud.enable() }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            GroupBox("Usar el código de otra Mac") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Junta lo de esta Mac con lo de la nube (no se pierde nada) y desde ahí quedan iguales.").foregroundStyle(.secondary)
                    HStack {
                        TextField("BP1-…", text: $joinCode).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                        Button("Conectar") {
                            badCode = !cloud.join(joinCode)
                            if !badCode { joinCode = "" }
                        }
                        .disabled(joinCode.isEmpty)
                    }
                    if badCode { Text("Ese código no es válido. Cópialo completo desde la otra Mac.").foregroundStyle(.red).font(.caption) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }
}
