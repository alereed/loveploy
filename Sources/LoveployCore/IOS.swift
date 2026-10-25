import Foundation

/// Where a project's iOS app stands: the latest TestFlight upload vs. the code, and
/// what's live on the App Store.
public struct IOSStatus: Hashable, Sendable {
    public enum TestFlight: Hashable, Sendable {
        /// The latest upload was built from the project's latest commit.
        case upToDate
        /// The latest upload is from an older commit.
        case outdated
        /// An upload is being built right now.
        case uploading
        /// The last upload attempt failed (or was cancelled) after the last good one.
        case failed
        /// Has an iOS setup but nothing uploaded yet.
        case none
    }

    public let testFlight: TestFlight
    /// Version, build number and Apple's state of the newest successful upload.
    public let latestUpload: StoreBuild.Release?
    /// What's live on the App Store.
    public let live: StoreBuild.Release?

    public init(testFlight: TestFlight, latestUpload: StoreBuild.Release?, live: StoreBuild.Release?) {
        self.testFlight = testFlight
        self.latestUpload = latestUpload
        self.live = live
    }

    /// TestFlight doesn't have the latest code.
    public var testFlightNeedsUpload: Bool { testFlight == .outdated || testFlight == .failed }

    /// The newest upload isn't the one live on the App Store (or nothing is live yet).
    public var appStoreBehind: Bool {
        guard let latestUpload else { return false }
        guard let live else { return true }
        return latestUpload.buildNumber != live.buildNumber || latestUpload.appVersion != live.appVersion
    }

    /// Builds the status from Lovable's iOS build runs and store uploads. nil when the
    /// project has never built for iOS on Lovable.
    public static func evaluate(runs: [BuildRun], builds: [StoreBuild], latestCommitSha: String?) -> IOSStatus? {
        let runs = runs.filter(\.includesIOS).sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        let iosBuilds = builds.filter { $0.target == "ios" }.sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
        guard !runs.isEmpty || !iosBuilds.isEmpty else { return nil }

        let lastSucceeded = runs.first { $0.status == "succeeded" }
        let lastFinished = runs.first { $0.isFinished }
        let testFlight: TestFlight
        if runs.contains(where: { !$0.isFinished }) {
            testFlight = .uploading
        } else if let lastFinished, lastFinished.status != "succeeded" {
            testFlight = .failed
        } else if let lastSucceeded {
            // Same check lovable.dev makes before offering a new upload.
            let current = lastSucceeded.commitSha.map { $0 == latestCommitSha } ?? (latestCommitSha == nil)
            testFlight = current ? .upToDate : .outdated
        } else {
            testFlight = iosBuilds.isEmpty ? .none : .outdated
        }

        let latestUpload = iosBuilds.first { $0.targetStatus == "succeeded" && $0.storeRelease != nil }?.storeRelease
        let live = iosBuilds.first { $0.storeRelease?.storeState == "live" }?.storeRelease
        return IOSStatus(testFlight: testFlight, latestUpload: latestUpload, live: live)
    }
}

extension StoreBuild.Release {
    /// Apple's state in Spanish, as the menu shows it.
    public var stateLabel: String {
        switch storeState {
        case "uploaded": return "enviada a Apple"
        case "processing": return "Apple la está procesando"
        case "ready": return "procesada, sin enviar a revisión"
        case "in_review": return "en revisión"
        case "live": return "en vivo"
        case "rejected": return "rechazada"
        default: return "estado desconocido"
        }
    }
}
