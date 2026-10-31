import BentoCore
import CoreServices
import Foundation

/// macOS `FSEventStream` implementation of `FileWatcher` with automatic read-only polling fallback (`PLAN.md` §6.1).
///
/// Opens two `FSEventStream` instances when non-empty:
/// - High-priority configuration stream (`.utility` QoS) with `kFSEventStreamCreateFlagFileEvents`, 300 ms latency,
///   and actor-isolated debouncing.
/// - Separate lower-priority session-logs stream (`.background` QoS).
///
/// Automatically falls back to read-only directory polling over `ReadOnlyFileSystem` if `FSEventStreamCreate` or
/// `FSEventStreamStart` fails (or when `forcePollingFallback` is enabled in tests).
public actor FSEventsFileWatcher: FileWatcher {
    fileprivate struct RawBatch: Sendable {
        var paths: [String]
        var streamKind: FileChangeEvent.StreamKind
        var requiresFullRescan: Bool
    }

    private struct FileSignature: Equatable, Sendable {
        var size: UInt64
        var mtime: Date?
        var inode: UInt64
        var isDirectory: Bool
    }

    private let latency: TimeInterval
    private let debounceInterval: Duration
    private let pollInterval: Duration
    private let forcePollingFallback: Bool
    private let fileSystem: any ReadOnlyFileSystem

    private var currentTargets = FileWatchTargets()
    private var outputContinuation: AsyncStream<FileChangeEvent>.Continuation?
    private var rawContinuation: AsyncStream<RawBatch>.Continuation?
    private var rawPumpTask: Task<Void, Never>?

    private var configStream: FSEventStreamRef?
    private var logStream: FSEventStreamRef?
    private let configQueue = DispatchQueue(label: "bento.fsevents.config", qos: .utility)
    private let logQueue = DispatchQueue(label: "bento.fsevents.logs", qos: .background)

    private var pendingConfigPaths: Set<String> = []
    private var pendingConfigRescan = false
    private var configDebounceTask: Task<Void, Never>?

    private var pendingLogPaths: Set<String> = []
    private var pendingLogRescan = false
    private var logDebounceTask: Task<Void, Never>?

    private var pollingTask: Task<Void, Never>?
    private var usingPollingFallback = false

    /// Creates an FSEvents-backed file watcher (`PLAN.md` §6.1 default latency is `300 ms`).
    public init(
        latency: TimeInterval = 0.3,
        debounceInterval: Duration = .milliseconds(150),
        pollInterval: Duration = .seconds(1),
        forcePollingFallback: Bool = false,
        fileSystem: any ReadOnlyFileSystem = LocalReadOnlyFileSystem()
    ) {
        self.latency = latency
        self.debounceInterval = debounceInterval
        self.pollInterval = pollInterval
        self.forcePollingFallback = forcePollingFallback
        self.fileSystem = fileSystem
    }

    /// Indicates whether the active watch session fell back to read-only directory polling.
    public var isUsingPollingFallback: Bool {
        usingPollingFallback
    }

    public func start(watching targets: FileWatchTargets) async -> AsyncStream<FileChangeEvent> {
        teardownActiveStreams(finishOutput: true)
        currentTargets = targets

        let (outputStream, outputCont) = AsyncStream.makeStream(of: FileChangeEvent.self)
        outputContinuation = outputCont

        configureBackends(for: targets)
        return outputStream
    }

    public func update(targets: FileWatchTargets) async {
        guard targets != currentTargets else { return }
        teardownActiveStreams(finishOutput: false)
        currentTargets = targets
        if outputContinuation != nil {
            configureBackends(for: targets)
        }
    }

    public func stop() async {
        teardownActiveStreams(finishOutput: true)
    }

    // MARK: - Stream Lifecycle

    private func configureBackends(for targets: FileWatchTargets) {
        if forcePollingFallback {
            usingPollingFallback = true
            startPollingTask(for: targets)
            return
        }

        let (rawStream, rawCont) = AsyncStream.makeStream(of: RawBatch.self)
        rawContinuation = rawCont

        var streamFailed = false

        if !targets.configurationPaths.isEmpty {
            if let stream = makeFSEventStream(
                paths: targets.configurationPaths,
                streamKind: .configuration,
                queue: configQueue,
                continuation: rawCont
            ) {
                configStream = stream
            } else {
                streamFailed = true
            }
        }

        if !streamFailed, !targets.logPaths.isEmpty {
            if let stream = makeFSEventStream(
                paths: targets.logPaths,
                streamKind: .logs,
                queue: logQueue,
                continuation: rawCont
            ) {
                logStream = stream
            } else {
                streamFailed = true
            }
        }

        if streamFailed {
            closeFSEventStreamsOnly()
            rawCont.finish()
            rawContinuation = nil
            usingPollingFallback = true
            startPollingTask(for: targets)
            return
        }

        usingPollingFallback = false
        rawPumpTask = Task { [weak self] in
            for await batch in rawStream {
                guard !Task.isCancelled, let self else { break }
                await self.handleRawBatch(batch)
            }
        }
    }

    private func makeFSEventStream(
        paths: [String],
        streamKind: FileChangeEvent.StreamKind,
        queue: DispatchQueue,
        continuation: AsyncStream<RawBatch>.Continuation
    ) -> FSEventStreamRef? {
        let resolvedRoots = resolveWatchableRoots(for: paths)
        guard !resolvedRoots.isEmpty else { return nil }

        let box = StreamCallbackBox(continuation: continuation, streamKind: streamKind)
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        let createdStream: FSEventStreamRef? = withExtendedLifetime(box) {
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(box).toOpaque(),
                retain: { info in
                    guard let info else { return nil }
                    _ = Unmanaged<StreamCallbackBox>.fromOpaque(info).retain()
                    return info
                },
                release: { info in
                    guard let info else { return }
                    Unmanaged<StreamCallbackBox>.fromOpaque(info).release()
                },
                copyDescription: nil
            )
            return FSEventStreamCreate(
                kCFAllocatorDefault,
                fsEventsStreamCallback,
                &context,
                resolvedRoots as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                createFlags
            )
        }

        guard let stream = createdStream else {
            return nil
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        return stream
    }

    private func resolveWatchableRoots(for paths: [String]) -> [String] {
        var roots: Set<String> = []
        for rawPath in paths {
            let std = URL(fileURLWithPath: rawPath).standardizedFileURL
            if fileSystem.exists(std) {
                roots.insert(fileSystem.resolveSymlinks(std).standardizedFileURL.path)
            } else {
                var parent = std.deletingLastPathComponent()
                while parent.path != "/" && !parent.path.isEmpty && !fileSystem.exists(parent) {
                    let next = parent.deletingLastPathComponent()
                    if next.path == parent.path { break }
                    parent = next
                }
                if fileSystem.exists(parent) {
                    roots.insert(fileSystem.resolveSymlinks(parent).standardizedFileURL.path)
                }
            }
        }
        return roots.sorted()
    }

    // MARK: - Debouncing

    private func handleRawBatch(_ batch: RawBatch) {
        let interval = debounceInterval
        switch batch.streamKind {
        case .configuration:
            pendingConfigPaths.formUnion(batch.paths)
            if batch.requiresFullRescan {
                pendingConfigRescan = true
            }
            configDebounceTask?.cancel()
            configDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.flushPending(streamKind: .configuration)
            }

        case .logs:
            pendingLogPaths.formUnion(batch.paths)
            if batch.requiresFullRescan {
                pendingLogRescan = true
            }
            logDebounceTask?.cancel()
            logDebounceTask = Task { [weak self] in
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.flushPending(streamKind: .logs)
            }
        }
    }

    private func flushPending(streamKind: FileChangeEvent.StreamKind) {
        switch streamKind {
        case .configuration:
            guard !pendingConfigPaths.isEmpty || pendingConfigRescan else { return }
            let paths = pendingConfigPaths.sorted()
            let rescan = pendingConfigRescan
            pendingConfigPaths.removeAll()
            pendingConfigRescan = false
            outputContinuation?.yield(
                FileChangeEvent(
                    paths: paths,
                    streamKind: .configuration,
                    requiresFullRescan: rescan,
                    timestamp: Date()
                )
            )

        case .logs:
            guard !pendingLogPaths.isEmpty || pendingLogRescan else { return }
            let paths = pendingLogPaths.sorted()
            let rescan = pendingLogRescan
            pendingLogPaths.removeAll()
            pendingLogRescan = false
            outputContinuation?.yield(
                FileChangeEvent(
                    paths: paths,
                    streamKind: .logs,
                    requiresFullRescan: rescan,
                    timestamp: Date()
                )
            )
        }
    }

    // MARK: - Read-Only Polling Fallback

    private func startPollingTask(for targets: FileWatchTargets) {
        let fs = fileSystem
        let interval = pollInterval

        pollingTask = Task { [weak self] in
            var configSnapshot = Self.captureDirectorySignatures(roots: targets.configurationPaths, fileSystem: fs)
            var logSnapshot = Self.captureDirectorySignatures(roots: targets.logPaths, fileSystem: fs)

            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { break }

                if !targets.configurationPaths.isEmpty {
                    let nextConfig = Self.captureDirectorySignatures(
                        roots: targets.configurationPaths,
                        fileSystem: fs
                    )
                    let changedConfig = Self.diffSignatures(previous: configSnapshot, current: nextConfig)
                    configSnapshot = nextConfig
                    if !changedConfig.isEmpty {
                        await self.handleRawBatch(
                            RawBatch(
                                paths: changedConfig,
                                streamKind: .configuration,
                                requiresFullRescan: false
                            )
                        )
                    }
                }

                if !targets.logPaths.isEmpty {
                    let nextLogs = Self.captureDirectorySignatures(roots: targets.logPaths, fileSystem: fs)
                    let changedLogs = Self.diffSignatures(previous: logSnapshot, current: nextLogs)
                    logSnapshot = nextLogs
                    if !changedLogs.isEmpty {
                        await self.handleRawBatch(
                            RawBatch(
                                paths: changedLogs,
                                streamKind: .logs,
                                requiresFullRescan: false
                            )
                        )
                    }
                }
            }
        }
    }

    private static func captureDirectorySignatures(
        roots: [String],
        fileSystem: any ReadOnlyFileSystem
    ) -> [String: FileSignature] {
        var signatures: [String: FileSignature] = [:]
        var visitedDirs: Set<String> = []

        func walk(_ url: URL) {
            let std = url.standardizedFileURL
            guard fileSystem.exists(std), let attrs = try? fileSystem.attributes(std) else { return }
            signatures[std.path] = FileSignature(
                size: attrs.size,
                mtime: attrs.modificationDate,
                inode: attrs.inode,
                isDirectory: attrs.isDirectory
            )

            let isDir: Bool
            if attrs.isDirectory {
                isDir = true
            } else if attrs.isSymlink {
                let resolved = fileSystem.resolveSymlinks(std)
                isDir = (try? fileSystem.attributes(resolved).isDirectory) == true
            } else {
                isDir = false
            }

            guard isDir else { return }
            let realDirPath = fileSystem.resolveSymlinks(std).standardizedFileURL.path
            guard visitedDirs.insert(realDirPath).inserted else { return }
            guard let children = try? fileSystem.list(std) else { return }
            for child in children {
                if child.lastPathComponent == ".git" { continue }
                walk(child)
            }
        }

        for root in roots {
            walk(URL(fileURLWithPath: root))
        }
        return signatures
    }

    private static func diffSignatures(
        previous: [String: FileSignature],
        current: [String: FileSignature]
    ) -> [String] {
        var changed: Set<String> = []
        for (path, sig) in current {
            guard let old = previous[path] else {
                if !sig.isDirectory {
                    changed.insert(path)
                }
                continue
            }
            if !sig.isDirectory && old != sig {
                changed.insert(path)
            }
        }
        for (path, oldSig) in previous where current[path] == nil && !oldSig.isDirectory {
            changed.insert(path)
        }
        return changed.sorted()
    }

    // MARK: - Teardown

    private func closeFSEventStreamsOnly() {
        if let stream = configStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            configStream = nil
        }
        if let stream = logStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            logStream = nil
        }
    }

    private func teardownActiveStreams(finishOutput: Bool) {
        configDebounceTask?.cancel()
        configDebounceTask = nil
        logDebounceTask?.cancel()
        logDebounceTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        rawPumpTask?.cancel()
        rawPumpTask = nil

        rawContinuation?.finish()
        rawContinuation = nil
        closeFSEventStreamsOnly()

        pendingConfigPaths.removeAll()
        pendingConfigRescan = false
        pendingLogPaths.removeAll()
        pendingLogRescan = false
        usingPollingFallback = false

        if finishOutput {
            outputContinuation?.finish()
            outputContinuation = nil
        }
    }
}

private final class StreamCallbackBox: Sendable {
    let continuation: AsyncStream<FSEventsFileWatcher.RawBatch>.Continuation
    let streamKind: FileChangeEvent.StreamKind

    init(
        continuation: AsyncStream<FSEventsFileWatcher.RawBatch>.Continuation,
        streamKind: FileChangeEvent.StreamKind
    ) {
        self.continuation = continuation
        self.streamKind = streamKind
    }
}

private let fsEventsStreamCallback: FSEventStreamCallback = {
    _, clientCallBackInfo, numEvents, eventPaths, eventFlags, _ in
    guard let clientCallBackInfo, numEvents > 0 else { return }
    let box = Unmanaged<StreamCallbackBox>.fromOpaque(clientCallBackInfo).takeUnretainedValue()
    let cfPaths = unsafeBitCast(eventPaths, to: CFArray.self)
    let count = min(numEvents, CFArrayGetCount(cfPaths))

    var paths: [String] = []
    paths.reserveCapacity(count)
    var requiresFullRescan = false
    let rescanMask = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped
    )

    for index in 0..<count {
        if let rawValue = CFArrayGetValueAtIndex(cfPaths, index) {
            let cfString = unsafeBitCast(rawValue, to: CFString.self)
            paths.append(cfString as String)
        }
        if (eventFlags[index] & rescanMask) != 0 {
            requiresFullRescan = true
        }
    }

    guard !paths.isEmpty || requiresFullRescan else { return }
    box.continuation.yield(
        FSEventsFileWatcher.RawBatch(
            paths: paths,
            streamKind: box.streamKind,
            requiresFullRescan: requiresFullRescan
        )
    )
}
