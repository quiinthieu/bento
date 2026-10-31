import BentoCore
import Foundation

/// Live progress snapshot emitted as `LogIngestor` completes each discovered log file.
public struct LogIngestProgress: Sendable, Codable, Hashable {
    public var completedFiles: Int
    public var totalFiles: Int
    public var currentPath: String
    public var agent: AgentID
    public var bytesReadSoFar: Int
    public var eventsDecodedSoFar: Int

    public init(
        completedFiles: Int,
        totalFiles: Int,
        currentPath: String,
        agent: AgentID,
        bytesReadSoFar: Int,
        eventsDecodedSoFar: Int
    ) {
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.currentPath = currentPath
        self.agent = agent
        self.bytesReadSoFar = bytesReadSoFar
        self.eventsDecodedSoFar = eventsDecodedSoFar
    }
}

/// Summary report returned by `LogIngestor.ingest(...)` and `bentoctx ingest` (`PLAN.md` §6.2, §6.8).
public struct LogIngestReport: Sendable, Codable, Hashable {
    public var filesDiscovered: Int
    public var filesIngested: Int
    public var filesSkippedUnchanged: Int
    public var bytesRead: Int
    public var eventsDecoded: Int
    public var eventsInserted: Int
    public var sessionsUpdated: Int
    public var decoderErrors: Int
    public var diagnostics: [Diagnostic]

    public init(
        filesDiscovered: Int = 0,
        filesIngested: Int = 0,
        filesSkippedUnchanged: Int = 0,
        bytesRead: Int = 0,
        eventsDecoded: Int = 0,
        eventsInserted: Int = 0,
        sessionsUpdated: Int = 0,
        decoderErrors: Int = 0,
        diagnostics: [Diagnostic] = []
    ) {
        self.filesDiscovered = filesDiscovered
        self.filesIngested = filesIngested
        self.filesSkippedUnchanged = filesSkippedUnchanged
        self.bytesRead = bytesRead
        self.eventsDecoded = eventsDecoded
        self.eventsInserted = eventsInserted
        self.sessionsUpdated = sessionsUpdated
        self.decoderErrors = decoderErrors
        self.diagnostics = diagnostics
    }
}

/// Incremental, rotation-safe, bounded-concurrency session log ingestor (`PLAN.md` §6.2).
///
/// - Resumes plain `.jsonl` files from `log_file.offset_consumed` and restores per-file decoder state.
/// - Detects rotation or copy-truncation via `inode != prior.inode || size < prior.offsetConsumed`,
///   re-reading from byte offset `0` while deduplicating persisted rows on deterministic `(agent, session_id, event_uid)`.
/// - Treats closed `.zst` archives as immutable unless `(size, mtime, inode)` changes.
public struct LogIngestor: Sendable {
    private struct CursorEnvelope: Codable {
        var decoderPayload: Data?
        var eventKeyCounts: [String: Int]
    }

    private struct FileTaskOutcome: Sendable {
        var index: Int
        var source: LogSource
        var skippedUnchanged: Bool
        var batch: IngestedLogBatch?
        var bytesRead: Int
        var eventsDecoded: Int
        var decoderErrors: Int
        var diagnostics: [Diagnostic]
    }

    public let fileSystem: any ReadOnlyFileSystem
    public let store: any LogIngestPersisting
    public let maxConcurrency: Int

    /// Creates a log ingestor backed by `fileSystem` and `store`.
    public init(
        fileSystem: any ReadOnlyFileSystem = LocalReadOnlyFileSystem(),
        store: any LogIngestPersisting,
        maxConcurrency: Int = 4
    ) {
        self.fileSystem = fileSystem
        self.store = store
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// Ingests `targets` with bounded concurrency (`maxConcurrency`), persisting `log_file`,
    /// `usage_event`, and `session` rows atomically per file.
    public func ingest(
        targets: [LogIngestTarget],
        onProgress: (@Sendable (LogIngestProgress) -> Void)? = nil
    ) async throws -> LogIngestReport {
        try Task.checkCancellation()
        guard !targets.isEmpty else {
            return LogIngestReport()
        }

        let sortedTargets = targets.sorted {
            $0.source.url.standardizedFileURL.path < $1.source.url.standardizedFileURL.path
        }
        let totalFiles = sortedTargets.count

        // Pre-fetch persisted `log_file` cursor states before fanning out concurrent file decode tasks.
        var priorStates: [String: LogFileState] = [:]
        for target in sortedTargets {
            let stdPath = target.source.url.standardizedFileURL.path
            if let existing = try store.logFileState(forPath: stdPath) {
                priorStates[stdPath] = existing
            }
        }

        var outcomesByIndex = [FileTaskOutcome?](repeating: nil, count: totalFiles)
        let fs = fileSystem
        let concurrencyLimit = min(maxConcurrency, totalFiles)

        try await withThrowingTaskGroup(of: FileTaskOutcome.self) { group in
            var nextIndex = 0

            while nextIndex < concurrencyLimit {
                let idx = nextIndex
                let target = sortedTargets[idx]
                let prior = priorStates[target.source.url.standardizedFileURL.path]
                group.addTask {
                    try Task.checkCancellation()
                    return try Self.processSingleFile(
                        index: idx,
                        target: target,
                        priorState: prior,
                        fileSystem: fs
                    )
                }
                nextIndex += 1
            }

            while let completed = try await group.next() {
                try Task.checkCancellation()
                outcomesByIndex[completed.index] = completed

                if nextIndex < totalFiles {
                    let idx = nextIndex
                    let target = sortedTargets[idx]
                    let prior = priorStates[target.source.url.standardizedFileURL.path]
                    group.addTask {
                        try Task.checkCancellation()
                        return try Self.processSingleFile(
                            index: idx,
                            target: target,
                            priorState: prior,
                            fileSystem: fs
                        )
                    }
                    nextIndex += 1
                }
            }
        }

        var report = LogIngestReport(filesDiscovered: totalFiles)

        for idx in 0..<totalFiles {
            try Task.checkCancellation()
            guard let outcome = outcomesByIndex[idx] else { continue }

            report.bytesRead += outcome.bytesRead
            report.eventsDecoded += outcome.eventsDecoded
            report.decoderErrors += outcome.decoderErrors
            report.diagnostics.append(contentsOf: outcome.diagnostics)

            if outcome.skippedUnchanged {
                report.filesSkippedUnchanged += 1
            } else if let batch = outcome.batch {
                report.filesIngested += 1
                let persisted = try store.recordIngestedLogBatch(batch)
                report.eventsInserted += persisted.eventsInserted
                report.sessionsUpdated += persisted.sessionsUpdated
            }

            onProgress?(
                LogIngestProgress(
                    completedFiles: idx + 1,
                    totalFiles: totalFiles,
                    currentPath: outcome.source.url.standardizedFileURL.path,
                    agent: outcome.source.agent,
                    bytesReadSoFar: report.bytesRead,
                    eventsDecodedSoFar: report.eventsDecoded
                )
            )
        }

        return report
    }

    // MARK: - Per-File Streaming Decode

    private static func processSingleFile(
        index: Int,
        target: LogIngestTarget,
        priorState: LogFileState?,
        fileSystem: any ReadOnlyFileSystem
    ) throws -> FileTaskOutcome {
        let source = target.source
        let stdURL = source.url.standardizedFileURL

        guard fileSystem.exists(stdURL) else {
            return FileTaskOutcome(
                index: index,
                source: source,
                skippedUnchanged: true,
                batch: nil,
                bytesRead: 0,
                eventsDecoded: 0,
                decoderErrors: 0,
                diagnostics: []
            )
        }

        let attrs = try fileSystem.attributes(stdURL)

        // 1. Compressed `.zst`: immutable once closed; skip re-read unless (size, mtime, inode) changed.
        if source.isCompressed {
            if let prior = priorState,
                prior.isCompressed,
                prior.size == attrs.size,
                prior.inode == attrs.inode,
                sameMtime(prior.mtime, attrs.modificationDate)
            {
                return FileTaskOutcome(
                    index: index,
                    source: source,
                    skippedUnchanged: true,
                    batch: nil,
                    bytesRead: 0,
                    eventsDecoded: 0,
                    decoderErrors: 0,
                    diagnostics: []
                )
            }

            var decoder = target.makeDecoder()
            var rawEvents: [UsageEvent] = []
            let zstdOutcome = try ZstdLineReader(url: stdURL).readLines { lineData in
                rawEvents.append(contentsOf: decoder.decode(line: lineData, source: source))
            }

            var eventKeyCounts: [String: Int] = [:]
            let batch = buildBatch(
                source: source,
                attrs: attrs,
                offsetConsumed: zstdOutcome.consumedOffset,
                lastError: zstdOutcome.errorMessage ?? Self.decoderErrorSummary(decoder.errorCount),
                decoderStateData: nil,
                rawEvents: rawEvents,
                observedModels: decoder.observedModelsBySession,
                eventKeyCounts: &eventKeyCounts
            )

            return FileTaskOutcome(
                index: index,
                source: source,
                skippedUnchanged: false,
                batch: batch,
                bytesRead: Int(zstdOutcome.bytesRead),
                eventsDecoded: rawEvents.count,
                decoderErrors: decoder.errorCount,
                diagnostics: zstdOutcome.diagnostics
            )
        }

        // 2. Monolithic `.json` document (e.g. legacy Gemini `session-*.json`).
        let isMonolithicJSON = stdURL.pathExtension.lowercased() == "json"
        if isMonolithicJSON {
            if let prior = priorState,
                prior.inode == attrs.inode,
                prior.size == attrs.size,
                prior.offsetConsumed == attrs.size,
                sameMtime(prior.mtime, attrs.modificationDate)
            {
                return FileTaskOutcome(
                    index: index,
                    source: source,
                    skippedUnchanged: true,
                    batch: nil,
                    bytesRead: 0,
                    eventsDecoded: 0,
                    decoderErrors: 0,
                    diagnostics: []
                )
            }

            let data = try fileSystem.contents(at: stdURL)
            var decoder = target.makeDecoder()
            let rawEvents = decoder.decodeDocument(data: data, source: source)
            var eventKeyCounts: [String: Int] = [:]
            let batch = buildBatch(
                source: source,
                attrs: attrs,
                offsetConsumed: UInt64(data.count),
                lastError: Self.decoderErrorSummary(decoder.errorCount),
                decoderStateData: nil,
                rawEvents: rawEvents,
                observedModels: decoder.observedModelsBySession,
                eventKeyCounts: &eventKeyCounts
            )

            return FileTaskOutcome(
                index: index,
                source: source,
                skippedUnchanged: false,
                batch: batch,
                bytesRead: data.count,
                eventsDecoded: rawEvents.count,
                decoderErrors: decoder.errorCount,
                diagnostics: []
            )
        }

        // 3. Plain `.jsonl` with resumable `offset_consumed` and rotation/truncation detection.
        let didRotateOrTruncate: Bool
        if let prior = priorState {
            didRotateOrTruncate = (prior.inode != attrs.inode) || (attrs.size < prior.offsetConsumed)
        } else {
            didRotateOrTruncate = false
        }

        if let prior = priorState,
            !didRotateOrTruncate,
            attrs.size == prior.offsetConsumed
        {
            return FileTaskOutcome(
                index: index,
                source: source,
                skippedUnchanged: true,
                batch: nil,
                bytesRead: 0,
                eventsDecoded: 0,
                decoderErrors: 0,
                diagnostics: []
            )
        }

        let startOffset: UInt64 = didRotateOrTruncate ? 0 : (priorState?.offsetConsumed ?? 0)
        var decoder = target.makeDecoder()
        var eventKeyCounts: [String: Int] = [:]

        if !didRotateOrTruncate,
            startOffset > 0,
            let envelopeData = priorState?.decoderState,
            let envelope = try? JSONDecoder().decode(CursorEnvelope.self, from: envelopeData)
        {
            if let payload = envelope.decoderPayload {
                decoder.restoreResumeState(payload)
            }
            eventKeyCounts = envelope.eventKeyCounts
        }

        var rawEvents: [UsageEvent] = []
        let lineOutcome = try StreamingLineReader(url: stdURL, startOffset: startOffset).readLines { lineData in
            rawEvents.append(contentsOf: decoder.decode(line: lineData, source: source))
        }

        let updatedEnvelope = CursorEnvelope(
            decoderPayload: decoder.exportResumeState(),
            eventKeyCounts: eventKeyCounts
        )
        // Note: buildBatch mutates `eventKeyCounts` for newly decoded events, so encode envelope AFTER buildBatch.
        var mutableCounts = updatedEnvelope.eventKeyCounts
        var batch = buildBatch(
            source: source,
            attrs: attrs,
            offsetConsumed: lineOutcome.consumedOffset,
            lastError: lineOutcome.errorMessage ?? Self.decoderErrorSummary(decoder.errorCount),
            decoderStateData: nil,
            rawEvents: rawEvents,
            observedModels: decoder.observedModelsBySession,
            eventKeyCounts: &mutableCounts
        )
        let finalEnvelope = CursorEnvelope(
            decoderPayload: decoder.exportResumeState(),
            eventKeyCounts: mutableCounts
        )
        batch.fileState.decoderState = try? JSONEncoder().encode(finalEnvelope)

        return FileTaskOutcome(
            index: index,
            source: source,
            skippedUnchanged: false,
            batch: batch,
            bytesRead: Int(lineOutcome.consumedOffset - startOffset),
            eventsDecoded: rawEvents.count,
            decoderErrors: decoder.errorCount,
            diagnostics: lineOutcome.diagnostics
        )
    }

    private static func buildBatch(
        source: LogSource,
        attrs: FileAttributes,
        offsetConsumed: UInt64,
        lastError: String?,
        decoderStateData: Data?,
        rawEvents: [UsageEvent],
        observedModels: [String: String],
        eventKeyCounts: inout [String: Int]
    ) -> IngestedLogBatch {
        var storedEvents: [StoredUsageEvent] = []
        storedEvents.reserveCapacity(rawEvents.count)

        var sessionsByID: [String: SessionRecord] = [:]

        for event in rawEvents {
            let modelForSession = observedModels[event.sessionID] ?? Self.sessionStartModel(from: event.kind)
            let eventUID = deterministicEventID(for: event, counts: &eventKeyCounts)
            storedEvents.append(
                StoredUsageEvent(
                    id: eventUID,
                    event: event,
                    repoID: nil,
                    model: modelForSession
                )
            )

            var session =
                sessionsByID[event.sessionID]
                ?? SessionRecord(
                    agent: event.agent,
                    sessionID: event.sessionID,
                    startedAt: event.timestamp,
                    cwd: event.cwd,
                    repoID: nil,
                    model: modelForSession,
                    firstTurnInput: nil
                )

            if event.timestamp < session.startedAt {
                session.startedAt = event.timestamp
            }
            if session.cwd == nil, let cwd = event.cwd {
                session.cwd = cwd
            }
            if let modelForSession {
                session.model = modelForSession
            }
            if case .tokenUsage(let input, _, _, let turnIndex) = event.kind,
                turnIndex == 0,
                session.firstTurnInput == nil
            {
                session.firstTurnInput = input
            }

            sessionsByID[event.sessionID] = session
        }

        let orderedSessions = sessionsByID.values.sorted {
            if $0.startedAt != $1.startedAt {
                return $0.startedAt < $1.startedAt
            }
            return $0.sessionID < $1.sessionID
        }

        let fileState = LogFileState(
            path: source.url.standardizedFileURL.path,
            agent: source.agent,
            size: attrs.size,
            mtime: attrs.modificationDate,
            inode: attrs.inode,
            offsetConsumed: offsetConsumed,
            isCompressed: source.isCompressed,
            lastError: lastError,
            decoderState: decoderStateData
        )

        return IngestedLogBatch(
            fileState: fileState,
            events: storedEvents,
            sessions: orderedSessions
        )
    }

    private static func deterministicEventID(
        for event: UsageEvent,
        counts: inout [String: Int]
    ) -> String {
        let tsMillis = Int64((event.timestamp.timeIntervalSince1970 * 1000.0).rounded())
        let descriptor: String
        switch event.kind {
        case .sessionStart:
            // At most one canonical sessionStart row per `(agent, sessionID)`.
            let canonical = "\(event.agent.rawValue)|\(event.sessionID)|sessionStart"
            return ContentHasher.sha256Hex(Data(canonical.utf8))
        case .tokenUsage(let input, let cached, let output, let turnIndex):
            descriptor = "tokenUsage:\(turnIndex):\(input):\(cached ?? -1):\(output):\(tsMillis)"
        case .skillInvoked(let name):
            descriptor = "skill:\(name):\(tsMillis)"
        case .mcpToolCalled(let server, let tool):
            descriptor = "mcp:\(server):\(tool):\(tsMillis)"
        case .subagentInvoked(let name):
            descriptor = "subagent:\(name):\(tsMillis)"
        case .commandInvoked(let name):
            descriptor = "command:\(name):\(tsMillis)"
        case .builtinToolCalled(let name):
            descriptor = "builtin:\(name):\(tsMillis)"
        }

        let scopedKey = "\(event.agent.rawValue)|\(event.sessionID)|\(descriptor)"
        let occurrence = counts[scopedKey, default: 0]
        counts[scopedKey] = occurrence + 1
        let fullIdentity = "\(scopedKey)|\(occurrence)"
        return ContentHasher.sha256Hex(Data(fullIdentity.utf8))
    }

    private static func sessionStartModel(from kind: UsageEvent.Kind) -> String? {
        if case .sessionStart(let model) = kind {
            return model
        }
        return nil
    }

    private static func decoderErrorSummary(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "Skipped \(count) malformed JSON log line(s)."
    }

    private static func sameMtime(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince1970 - rhs.timeIntervalSince1970) < 0.000_001
    }
}
