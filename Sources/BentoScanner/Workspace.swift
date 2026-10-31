import BentoAdapters
import BentoCore
import Foundation

/// Actor owning the live `Snapshot`, incremental `PathCatalog`-driven rescans, and `AsyncStream<SnapshotDelta>`
/// notifications (`PLAN.md` §3.5, §6.1).
public actor Workspace {
    let environment: AgentEnvironment
    let adapters: [any AgentAdapter]
    let adaptersByID: [AgentID: any AgentAdapter]
    private let store: (any SnapshotPersisting)?
    private let watcher: (any FileWatcher)?
    private var repoDiscoveryOptions: RepoDiscoveryOptions

    private var latestSnapshot: Snapshot?
    private var subscribers: [UUID: AsyncStream<SnapshotDelta>.Continuation] = [:]
    private var watchLoopTask: Task<Void, Never>?

    /// Creates a workspace coordinator.
    public init(
        environment: AgentEnvironment,
        adapters: [any AgentAdapter] = AgentAdapters.all,
        store: (any SnapshotPersisting)? = nil,
        watcher: (any FileWatcher)? = nil,
        repoDiscoveryOptions: RepoDiscoveryOptions = RepoDiscoveryOptions()
    ) {
        self.environment = environment
        self.adapters = adapters
        var map: [AgentID: any AgentAdapter] = [:]
        for adapter in adapters {
            map[type(of: adapter).id] = adapter
        }
        self.adaptersByID = map
        self.store = store
        self.watcher = watcher
        self.repoDiscoveryOptions = repoDiscoveryOptions
    }

    /// Returns the most recent in-memory `Snapshot`, or loads the latest persisted snapshot from `store` if none is cached.
    public func currentSnapshot() throws -> Snapshot? {
        if let latestSnapshot {
            return latestSnapshot
        }
        let homePath = environment.home.standardizedFileURL.path
        let homeHash = ContentHasher.sha256Hex(Data(homePath.utf8))
        if let persisted = try store?.loadLatestSnapshot(homeHash: homeHash) {
            latestSnapshot = persisted
            return persisted
        }
        return nil
    }

    /// Subscribes to future `SnapshotDelta` updates emitted by full or incremental scans.
    public func deltas() -> AsyncStream<SnapshotDelta> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: SnapshotDelta.self)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeSubscriber(id)
            }
        }
        return stream
    }

    /// Executes a cold full scan across all registered adapters and discovered repositories.
    @discardableResult
    public func scanFull() async throws -> Snapshot {
        try Task.checkCancellation()

        let effectiveOptions = effectiveRepoDiscoveryOptions()
        let repos = RepoDiscovery.discover(in: environment, options: effectiveOptions)

        var detections: [AgentID: DetectionResult] = [:]
        var scopedArtifacts: [ScanScope: [Artifact]] = [:]
        var resolutions: [Resolution] = []
        var allScopes: [ScanScope] = []

        for adapter in adapters {
            try Task.checkCancellation()
            let agentID = type(of: adapter).id
            detections[agentID] = await adapter.detect(in: environment)

            let globalScope = ScanScope(agent: agentID, repoPath: nil)
            let globalArtifacts = try await adapter.discover(in: environment, folder: nil)
            scopedArtifacts[globalScope] = globalArtifacts
            allScopes.append(globalScope)

            for repo in repos {
                try Task.checkCancellation()
                let repoURL = URL(fileURLWithPath: repo.path).standardizedFileURL
                let repoScope = ScanScope(agent: agentID, repoPath: repo.path)
                let repoArtifacts = try await adapter.discover(in: environment, folder: repoURL)
                scopedArtifacts[repoScope] = repoArtifacts
                allScopes.append(repoScope)

                if adapter.capabilities.contains(.resolution) {
                    let resolution = adapter.resolve(repoArtifacts, folder: repoURL, env: environment)
                    resolutions.append(resolution)
                }
            }
        }

        let snapshot = Snapshot(
            createdAt: environment.now(),
            homePath: environment.home.standardizedFileURL.path,
            scannerVersion: Product.version,
            detections: detections,
            repos: repos,
            scopedArtifacts: scopedArtifacts,
            resolutions: resolutions
        )

        try store?.saveSnapshot(snapshot)
        latestSnapshot = snapshot

        if let watcher, watchLoopTask != nil {
            await watcher.update(targets: computeWatchTargets(repos: snapshot.repos))
        }

        let delta = SnapshotDelta(
            snapshot: snapshot,
            reason: .fullScan,
            rescannedScopes: allScopes
        )
        broadcast(delta)
        return snapshot
    }

    /// Processes a batch of changed paths incrementally using `PathCatalogMatcher` (`PLAN.md` §6.1).
    ///
    /// Re-discovers and re-resolves **only** the `ScanScope` units whose `PathCatalog` patterns (or previously
    /// recorded artifact/import dependencies) match `event.paths`.
    @discardableResult
    public func handleFileChange(_ event: FileChangeEvent) async throws -> SnapshotDelta? {
        try Task.checkCancellation()

        if event.requiresFullRescan || latestSnapshot == nil {
            let full = try await scanFull()
            return SnapshotDelta(
                snapshot: full,
                reason: .fullScan,
                rescannedScopes: Array(full.scopedArtifacts.keys),
                changedPaths: event.paths
            )
        }

        guard let baseSnapshot = latestSnapshot else {
            return nil
        }

        var match = PathCatalogMatcher.match(
            changedPaths: event.paths,
            adapters: adapters,
            repos: baseSnapshot.repos,
            in: environment
        )
        let dependencyScopes = scopesReferencingPaths(event.paths, in: baseSnapshot)
        match.scopes.formUnion(dependencyScopes)

        var updatedRepos = baseSnapshot.repos
        var updatedDetections = baseSnapshot.detections
        var updatedScopedArtifacts = baseSnapshot.scopedArtifacts
        var resolutionsMap = Dictionary(
            uniqueKeysWithValues: baseSnapshot.resolutions.map {
                (ScanScope(agent: $0.agent, repoPath: $0.folder), $0)
            }
        )

        // When log files change, check whether a new repository appeared in session logs without re-discovering existing repos.
        if !match.logAgents.isEmpty {
            let refreshedRepos = RepoDiscovery.discover(
                in: environment,
                options: effectiveRepoDiscoveryOptions()
            )
            let existingPaths = Set(updatedRepos.map(\.path))
            let addedRepos = refreshedRepos.filter { !existingPaths.contains($0.path) }
            updatedRepos = refreshedRepos
            for added in addedRepos {
                for adapter in adapters {
                    match.scopes.insert(ScanScope(agent: type(of: adapter).id, repoPath: added.path))
                }
            }
        }

        if match.scopes.isEmpty && match.logAgents.isEmpty {
            return nil
        }

        let sortedScopes = match.scopes.sorted()
        let affectedAgents = Set(sortedScopes.map(\.agent))
        for agentID in affectedAgents {
            if let adapter = adaptersByID[agentID] {
                updatedDetections[agentID] = await adapter.detect(in: environment)
            }
        }

        for scope in sortedScopes {
            try Task.checkCancellation()
            guard let adapter = adaptersByID[scope.agent] else { continue }
            if let repoPath = scope.repoPath {
                let repoURL = URL(fileURLWithPath: repoPath).standardizedFileURL
                let discovered = try await adapter.discover(in: environment, folder: repoURL)
                updatedScopedArtifacts[scope] = discovered
                if adapter.capabilities.contains(.resolution) {
                    resolutionsMap[scope] = adapter.resolve(discovered, folder: repoURL, env: environment)
                }
            } else {
                let discovered = try await adapter.discover(in: environment, folder: nil)
                updatedScopedArtifacts[scope] = discovered
            }
        }

        let updatedSnapshot = Snapshot(
            createdAt: environment.now(),
            homePath: baseSnapshot.homePath,
            homeHash: baseSnapshot.homeHash,
            scannerVersion: Product.version,
            detections: updatedDetections,
            repos: updatedRepos,
            scopedArtifacts: updatedScopedArtifacts,
            resolutions: Array(resolutionsMap.values)
        )

        try store?.saveSnapshot(updatedSnapshot)
        latestSnapshot = updatedSnapshot

        if let watcher, watchLoopTask != nil {
            await watcher.update(targets: computeWatchTargets(repos: updatedSnapshot.repos))
        }

        let delta = SnapshotDelta(
            snapshot: updatedSnapshot,
            reason: .incrementalRescan,
            rescannedScopes: sortedScopes,
            changedPaths: event.paths,
            changedLogAgents: Array(match.logAgents)
        )
        broadcast(delta)
        return delta
    }

    /// Discovers and resolves a single `(agent, folder)` pair on demand.
    public func resolveOnDemand(
        agent: AgentID,
        folder: URL
    ) async throws -> (artifacts: [Artifact], resolution: Resolution) {
        guard let adapter = adaptersByID[agent] else {
            throw BentoScannerError.unknownAgent(agent)
        }
        guard adapter.capabilities.contains(.resolution) else {
            throw BentoScannerError.resolutionUnsupported(agent)
        }
        let stdFolder = folder.standardizedFileURL
        let discovered = try await adapter.discover(in: environment, folder: stdFolder)
        let resolution = adapter.resolve(discovered, folder: stdFolder, env: environment)
        return (discovered, resolution)
    }

    /// Discovers artifacts for `folder` across `agent` (or all adapters when `agent == nil`) on demand.
    public func discoverOnDemand(agent: AgentID?, folder: URL) async throws -> [Artifact] {
        let stdFolder = folder.standardizedFileURL
        let selectedAdapters: [any AgentAdapter]
        if let agent {
            guard let adapter = adaptersByID[agent] else {
                throw BentoScannerError.unknownAgent(agent)
            }
            selectedAdapters = [adapter]
        } else {
            selectedAdapters = adapters
        }

        var seen: Set<ArtifactID> = []
        var result: [Artifact] = []
        for adapter in selectedAdapters {
            let list = try await adapter.discover(in: environment, folder: stdFolder)
            for item in list where seen.insert(item.id).inserted {
                result.append(item)
            }
        }
        return result
    }

    /// Starts watching agent configuration, pinned repo subpaths, and log directories via `watcher`.
    public func startWatching() async {
        guard let watcher else { return }
        watchLoopTask?.cancel()

        let repos = latestSnapshot?.repos ?? []
        let targets = computeWatchTargets(repos: repos)
        let eventStream = await watcher.start(watching: targets)

        watchLoopTask = Task(priority: .utility) { [weak self] in
            for await event in eventStream {
                guard !Task.isCancelled, let self else { break }
                _ = try? await self.handleFileChange(event)
            }
        }
    }

    /// Stops the active `watcher` subscription task and closes underlying streams.
    public func stopWatching() async {
        watchLoopTask?.cancel()
        watchLoopTask = nil
        await watcher?.stop()
    }

    /// Updates repository discovery options (shallow scan roots, manual paths, hidden paths).
    public func setRepoDiscoveryOptions(_ options: RepoDiscoveryOptions) {
        self.repoDiscoveryOptions = options
    }

    /// Returns the configured repository discovery options.
    public func currentRepoDiscoveryOptions() -> RepoDiscoveryOptions {
        repoDiscoveryOptions
    }

    /// Computes watched configuration and log paths for the current environment and discovered repositories (`PLAN.md` §6.1).
    public func watchTargets() -> FileWatchTargets {
        computeWatchTargets(repos: latestSnapshot?.repos ?? [])
    }

    // MARK: - Private Helpers

    func effectiveRepoDiscoveryOptions() -> RepoDiscoveryOptions {
        var options = repoDiscoveryOptions
        if let storePinned = try? store?.pinnedRepoPaths() {
            options.pinnedPaths.formUnion(storePinned)
        }
        return options
    }

    private func computeWatchTargets(repos: [DiscoveredRepo]) -> FileWatchTargets {
        let env = environment
        var configPaths: Set<String> = [
            ClaudeCodePathCatalog.userConfigDirectory(in: env).path,
            ClaudeCodePathCatalog.userStateFile(in: env).deletingLastPathComponent().path,
            CodexPathCatalog.userCodexDirectory(in: env).path,
            CodexPathCatalog.userAgentsSkillsDirectory(in: env).path,
            GeminiPathCatalog.userGeminiDirectory(in: env).path,
            CopilotPathCatalog.userCopilotDirectory(in: env).path,
            CursorPathCatalog.userCursorDirectory(in: env).path,
            WindsurfPathCatalog.userWindsurfDirectory(in: env).path
        ]

        // For pinned repos, watch only agent-relevant subpaths declared in PathCatalogs (PLAN §6.1).
        for repo in repos where repo.isPinned {
            let repoURL = URL(fileURLWithPath: repo.path).standardizedFileURL
            for adapter in adapters {
                for entry in adapter.paths.entries where entry.pattern.hasPrefix("<repo>/") {
                    let suffix = String(entry.pattern.dropFirst("<repo>/".count))
                    guard let firstComponent = suffix.split(separator: "/").first else { continue }
                    let token = String(firstComponent)
                    if token.contains("*") {
                        configPaths.insert(repoURL.path)
                    } else {
                        configPaths.insert(repoURL.appendingPathComponent(token).path)
                    }
                }
            }
        }

        let logPaths: [String] = [
            ClaudeCodePathCatalog.userLogsDirectory(in: env).path,
            CodexPathCatalog.userLogsDirectory(in: env).path,
            GeminiPathCatalog.userLogsRootDirectory(in: env).path,
            CopilotPathCatalog.userSessionStateDirectory(in: env).path
        ]

        return FileWatchTargets(
            configurationPaths: Array(configPaths),
            logPaths: logPaths
        )
    }

    private func scopesReferencingPaths(
        _ rawPaths: [String],
        in snapshot: Snapshot
    ) -> Set<ScanScope> {
        var candidates: Set<String> = []
        for raw in rawPaths {
            let std = URL(fileURLWithPath: raw).standardizedFileURL
            candidates.insert(std.path)
            if environment.fileSystem.exists(std) {
                candidates.insert(environment.fileSystem.resolveSymlinks(std).standardizedFileURL.path)
            }
        }
        guard !candidates.isEmpty else { return [] }

        var matched: Set<ScanScope> = []
        for (scope, list) in snapshot.scopedArtifacts {
            for artifact in list {
                if candidates.contains(artifact.location.path)
                    || candidates.contains(artifact.location.realPath)
                {
                    matched.insert(scope)
                    break
                }
                if case .rules(let doc) = artifact.payload, !doc.imports.isEmpty {
                    let baseDir = URL(fileURLWithPath: artifact.location.path).deletingLastPathComponent()
                    let hitImport = doc.imports.contains { imported in
                        let resolved = AdapterPathNormalizer.expandHomePrefix(imported, in: environment)
                        let relative = baseDir.appendingPathComponent(imported).standardizedFileURL
                        return candidates.contains(resolved.path) || candidates.contains(relative.path)
                    }
                    if hitImport {
                        matched.insert(scope)
                        break
                    }
                }
            }
        }
        return matched
    }

    private func broadcast(_ delta: SnapshotDelta) {
        for continuation in subscribers.values {
            continuation.yield(delta)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
