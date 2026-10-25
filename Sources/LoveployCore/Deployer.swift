import Foundation

/// Progress of one project inside a deploy run.
public enum DeployProgress: Hashable, Sendable {
    case queued
    /// The step lovable.dev shows ("Building", "Deploying"…), when known.
    case publishing(step: String?)
    case completed(url: String?)
    case failed(message: String)
    /// Still running when we stopped polling.
    case timedOut
}

/// Publishes a batch of projects, a few at a time.
public struct Deployer: Sendable {
    public let maxConcurrent: Int
    public let pollTimeout: TimeInterval

    public init(maxConcurrent: Int = 3, pollTimeout: TimeInterval = 15 * 60) {
        self.maxConcurrent = maxConcurrent
        self.pollTimeout = pollTimeout
    }

    /// Publishes one project and follows it to the end.
    public func deploy(
        projectID: String,
        client: LovableWebClient,
        onProgress: @Sendable (DeployProgress) async -> Void
    ) async -> DeployProgress {
        await onProgress(.publishing(step: nil))
        do {
            let deploymentID = try await client.startDeployment(projectID: projectID)
            var waited: TimeInterval = 0
            var lastStep: String?
            while true {
                let progress = try await client.deploymentProgress(projectID: projectID, deploymentID: deploymentID)
                if progress.isCompleted {
                    return .completed(url: progress.url)
                }
                if progress.isError {
                    let message = [progress.errorMessage, publishFailureHint(errorClass: progress.errorClass)]
                        .compactMap { $0 }
                        .joined(separator: " — ")
                    return .failed(message: message.isEmpty ? "La publicación falló." : message)
                }
                if waited >= pollTimeout {
                    return .timedOut
                }
                if progress.step != lastStep {
                    lastStep = progress.step
                    await onProgress(.publishing(step: progress.step))
                }
                // Same cadence as lovable.dev: every 2s for the first 20s, then every 5s.
                let delay: TimeInterval = waited < 20 ? 2 : 5
                try await client.sleep(delay)
                waited += delay
            }
        } catch is CancellationError {
            return .failed(message: "Cancelado.")
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }

    /// Publishes every project, at most `maxConcurrent` at once.
    public func run(
        projectIDs: [String],
        client: LovableWebClient,
        onUpdate: @escaping @Sendable (String, DeployProgress) async -> Void
    ) async {
        for id in projectIDs {
            await onUpdate(id, .queued)
        }
        await withTaskGroup(of: Void.self) { group in
            var pending = projectIDs[...]
            func startNext() {
                guard let id = pending.popFirst() else { return }
                group.addTask {
                    let result = await deploy(projectID: id, client: client) { progress in
                        await onUpdate(id, progress)
                    }
                    await onUpdate(id, result)
                }
            }
            for _ in 0..<max(1, maxConcurrent) {
                startNext()
            }
            while await group.next() != nil {
                startNext()
            }
        }
    }
}
