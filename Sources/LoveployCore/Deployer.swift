import Foundation

/// Progress of one project inside a deploy run.
public enum DeployProgress: Hashable, Sendable {
    case queued
    case publishing
    case completed(url: String?)
    case failed(message: String)
    /// Still running when we stopped polling.
    case timedOut
}

/// One project to publish.
public struct DeployJob: Sendable {
    public let projectID: String
    public let client: LovableClient
    /// Given Lovable's commit at publish time, returns the GitHub SHA to record. nil when not linked.
    public let githubSha: (@Sendable (String?) async -> String?)?

    public init(projectID: String, client: LovableClient, githubSha: (@Sendable (String?) async -> String?)? = nil) {
        self.projectID = projectID
        self.client = client
        self.githubSha = githubSha
    }
}

/// Publishes a batch of projects, a few at a time.
public struct Deployer: Sendable {
    public let maxConcurrent: Int
    public let pollTimeout: TimeInterval
    public let now: @Sendable () -> Date

    public init(maxConcurrent: Int = 3, pollTimeout: TimeInterval = 15 * 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.maxConcurrent = maxConcurrent
        self.pollTimeout = pollTimeout
        self.now = now
    }

    /// Publishes one project and, on success, returns the record to store.
    public func deploy(
        _ job: DeployJob,
        onProgress: @Sendable (DeployProgress) async -> Void
    ) async -> (DeployProgress, PublishRecord?) {
        let (projectID, client) = (job.projectID, job.client)
        await onProgress(.publishing)
        do {
            // Read the commit right before publishing, so the record matches what goes live.
            let detail = try? await client.getProject(id: projectID)
            let githubSha = await job.githubSha?(detail?.latestCommitSha)
            let started = try await client.publish(projectID: projectID)
            let finished = try await client.waitForDeployment(projectID: projectID, deployment: started, timeout: pollTimeout)
            switch finished.status {
            case .completed:
                let record = PublishRecord(
                    commitSha: detail?.latestCommitSha,
                    publishedAt: now(),
                    url: finished.url,
                    githubSha: githubSha
                )
                return (.completed(url: finished.url), record)
            case .error:
                let message = [finished.errorMessage, publishFailureHint(errorClass: finished.errorClass)]
                    .compactMap { $0 }
                    .joined(separator: " — ")
                return (.failed(message: message.isEmpty ? "La publicación falló." : message), nil)
            case .running, .unknown:
                return (.timedOut, nil)
            }
        } catch is CancellationError {
            return (.failed(message: "Cancelado."), nil)
        } catch {
            return (.failed(message: error.localizedDescription), nil)
        }
    }

    /// Publishes every job, at most `maxConcurrent` at once. `onUpdate` fires for each
    /// status change; `onRecord` fires once per successful publish.
    public func run(
        jobs: [DeployJob],
        onUpdate: @escaping @Sendable (String, DeployProgress) async -> Void,
        onRecord: @escaping @Sendable (String, PublishRecord) async -> Void
    ) async {
        for job in jobs {
            await onUpdate(job.projectID, .queued)
        }
        await withTaskGroup(of: Void.self) { group in
            var pending = jobs[...]
            func startNext() {
                guard let job = pending.popFirst() else { return }
                group.addTask {
                    let (result, record) = await deploy(job) { progress in
                        await onUpdate(job.projectID, progress)
                    }
                    if let record {
                        await onRecord(job.projectID, record)
                    }
                    await onUpdate(job.projectID, result)
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
