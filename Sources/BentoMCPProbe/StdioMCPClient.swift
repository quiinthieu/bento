import BentoCore
import Darwin
import Foundation

/// Stdio MCP client executing `initialize` -> `notifications/initialized` -> paginated `tools/list`
/// inside a scrubbed, non-TTY child process with bounded stderr and strict timeout (`PLAN.md` §6.4, §7).
public struct StdioMCPClient: Sendable {
    /// Default wall-clock timeout (`15.0` seconds) per `PLAN.md` §6.4.
    public static let defaultTimeoutSeconds: TimeInterval = 15.0
    /// Hard wall-clock timeout ceiling (`16.0` seconds, `<= 15 s + 1`) per `PLAN.md` §11 T10.
    public static let maxTimeoutCeilingSeconds: TimeInterval = 16.0
    /// Maximum stderr bytes retained for diagnostic reporting (`16 KB`).
    public static let maxStderrBytes: Int = 16 * 1024

    private static let fallbackSystemPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public let timeoutSeconds: TimeInterval

    /// Creates a stdio MCP probe client with a wall-clock timeout clamped to `maxTimeoutCeilingSeconds`.
    public init(timeoutSeconds: TimeInterval = StdioMCPClient.defaultTimeoutSeconds) {
        self.timeoutSeconds = min(max(0.05, timeoutSeconds), Self.maxTimeoutCeilingSeconds)
    }

    /// Builds a scrubbed child environment containing **only** `HOME`, `PATH`, and keys listed in `config.envKeys`.
    public static func buildScrubbedEnvironment(
        config: MCPServerConfig,
        homeDirectory: URL,
        basePATH: String? = nil,
        declaredValues: [String: String] = [:]
    ) -> [String: String] {
        let resolvedPATH = (basePATH?.isEmpty == false) ? basePATH! : fallbackSystemPATH
        var scrubbed: [String: String] = [
            "HOME": homeDirectory.standardizedFileURL.path,
            "PATH": resolvedPATH
        ]
        for key in config.envKeys {
            guard key != "HOME" && key != "PATH" else { continue }
            if let value = declaredValues[key] {
                scrubbed[key] = value
            }
        }
        return scrubbed
    }

    /// Probes a stdio MCP server and returns the negotiated protocol version and paginated tool schemas.
    internal func probe(
        serverName: String,
        command: String,
        args: [String],
        config: MCPServerConfig,
        workingDirectory: URL,
        homeDirectory: URL,
        basePATH: String?,
        declaredValues: [String: String]
    ) async throws -> MCPJSONRPC.HandshakeResult {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else {
            throw BentoMCPProbeError.invalidTransport(
                serverName: serverName,
                reason: "Empty stdio command"
            )
        }

        let scrubbedEnv = Self.buildScrubbedEnvironment(
            config: config,
            homeDirectory: homeDirectory,
            basePATH: basePATH,
            declaredValues: declaredValues
        )

        guard
            let executableURL = Self.resolveExecutable(
                command: trimmedCommand,
                workingDirectory: workingDirectory,
                searchPATH: scrubbedEnv["PATH"] ?? Self.fallbackSystemPATH
            )
        else {
            throw BentoMCPProbeError.processLaunchFailed(
                serverName: serverName,
                reason: "Executable not found for command '\(trimmedCommand)'"
            )
        }

        let effectiveTimeout = timeoutSeconds
        return try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate(continuation)
            let process = Process()
            process.executableURL = executableURL
            process.arguments = args
            process.currentDirectoryURL = workingDirectory.standardizedFileURL
            process.environment = scrubbedEnv

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in
                exitSemaphore.signal()
            }

            let stderrCollector = BoundedStderrCollector(limit: Self.maxStderrBytes)
            let stderrDone = DispatchSemaphore(value: 0)

            do {
                try process.run()
            } catch {
                gate.resume(
                    throwing: BentoMCPProbeError.processLaunchFailed(
                        serverName: serverName,
                        reason: error.localizedDescription
                    )
                )
                return
            }

            // Drain stderr on a dedicated thread into a bounded 16 KB buffer so chatty servers never block
            // and GCD global-queue saturation under `swift test --parallel` cannot starve stderr collection.
            let stderrHandle = stderrPipe.fileHandleForReading
            let stderrThread = Thread {
                while true {
                    let chunk = stderrHandle.availableData
                    if chunk.isEmpty {
                        break
                    }
                    stderrCollector.append(chunk)
                }
                stderrDone.signal()
            }
            stderrThread.qualityOfService = .userInitiated
            stderrThread.start()

            // Schedule strict wall-clock timeout killer on a dedicated thread so GCD global-queue
            // saturation under parallel workloads can never delay timeout enforcement.
            let timeoutFlag = AtomicFlag()
            let completedFlag = AtomicFlag()
            let timeoutDeadline = Date().addingTimeInterval(effectiveTimeout)
            let timeoutThread = Thread {
                while true {
                    if completedFlag.isSet {
                        return
                    }
                    let remaining = timeoutDeadline.timeIntervalSinceNow
                    if remaining <= 0 {
                        break
                    }
                    Thread.sleep(forTimeInterval: min(0.025, remaining))
                }
                guard completedFlag.setIfUnset() else { return }
                timeoutFlag.set()
                try? stdinPipe.fileHandleForWriting.close()
                Self.terminateAndReap(process, exitSemaphore: exitSemaphore)
                _ = stderrDone.wait(timeout: .now() + .milliseconds(100))
                gate.resume(
                    throwing: BentoMCPProbeError.timedOut(
                        serverName: serverName,
                        seconds: effectiveTimeout,
                        stderr: stderrCollector.snapshotString()
                    )
                )
            }
            timeoutThread.qualityOfService = .userInitiated
            timeoutThread.start()

            // Run blocking pipe handshake on a dedicated thread rather than GCD's bounded global pool.
            let handshakeThread = Thread {
                defer {
                    _ = completedFlag.setIfUnset()
                    try? stdinPipe.fileHandleForWriting.close()
                    Self.terminateAndReap(process, exitSemaphore: exitSemaphore)
                }

                do {
                    let lineReader = PipeLineReader(handle: stdoutPipe.fileHandleForReading)
                    let writer = stdinPipe.fileHandleForWriting

                    // 1. initialize (id = 1)
                    let initData = try MCPJSONRPC.makeInitializeRequestData(id: 1)
                    try writer.write(contentsOf: initData)

                    let initResponse = try Self.awaitResponse(
                        expectedID: 1,
                        reader: lineReader,
                        process: process,
                        exitSemaphore: exitSemaphore,
                        stderrDone: stderrDone,
                        stderrCollector: stderrCollector,
                        timeoutFlag: timeoutFlag,
                        timeoutSeconds: effectiveTimeout,
                        serverName: serverName
                    )
                    let protocolVersion = try MCPJSONRPC.parseInitializeResult(
                        from: initResponse,
                        serverName: serverName,
                        stderr: stderrCollector.snapshotString()
                    )

                    // 2. notifications/initialized
                    let notifyData = try MCPJSONRPC.makeInitializedNotificationData()
                    try writer.write(contentsOf: notifyData)

                    // 3. tools/list with pagination
                    var allTools: [MCPToolSchema] = []
                    var seenCursors: Set<String> = []
                    var cursor: String?
                    var requestID = 2

                    for _ in 0..<MCPJSONRPC.maxPaginationPages {
                        let listReq = try MCPJSONRPC.makeToolsListRequestData(id: requestID, cursor: cursor)
                        try writer.write(contentsOf: listReq)

                        let listResp = try Self.awaitResponse(
                            expectedID: requestID,
                            reader: lineReader,
                            process: process,
                            exitSemaphore: exitSemaphore,
                            stderrDone: stderrDone,
                            stderrCollector: stderrCollector,
                            timeoutFlag: timeoutFlag,
                            timeoutSeconds: effectiveTimeout,
                            serverName: serverName
                        )
                        let page = try MCPJSONRPC.parseToolsListResult(
                            from: listResp,
                            serverName: serverName,
                            stderr: stderrCollector.snapshotString()
                        )
                        allTools.append(contentsOf: page.tools)

                        guard let next = page.nextCursor, !next.isEmpty, !seenCursors.contains(next) else {
                            break
                        }
                        seenCursors.insert(next)
                        cursor = next
                        requestID += 1
                    }

                    gate.resume(
                        returning: MCPJSONRPC.HandshakeResult(
                            protocolVersion: protocolVersion,
                            tools: allTools
                        )
                    )
                } catch let probeError as BentoMCPProbeError {
                    gate.resume(throwing: probeError)
                } catch {
                    if timeoutFlag.isSet {
                        gate.resume(
                            throwing: BentoMCPProbeError.timedOut(
                                serverName: serverName,
                                seconds: effectiveTimeout,
                                stderr: stderrCollector.snapshotString()
                            )
                        )
                    } else {
                        _ = exitSemaphore.wait(timeout: .now() + .seconds(1))
                        _ = stderrDone.wait(timeout: .now() + .seconds(2))
                        let stderrText = stderrCollector.snapshotString()
                        if !process.isRunning && process.terminationStatus != 0 {
                            gate.resume(
                                throwing: BentoMCPProbeError.processCrashed(
                                    serverName: serverName,
                                    exitCode: process.terminationStatus,
                                    stderr: stderrText
                                )
                            )
                        } else {
                            gate.resume(
                                throwing: BentoMCPProbeError.protocolError(
                                    serverName: serverName,
                                    reason: error.localizedDescription,
                                    stderr: stderrText
                                )
                            )
                        }
                    }
                }
            }
            handshakeThread.qualityOfService = .userInitiated
            handshakeThread.start()
        }
    }

    // MARK: - Private Helpers

    private static func awaitResponse(
        expectedID: Int,
        reader: PipeLineReader,
        process: Process,
        exitSemaphore: DispatchSemaphore,
        stderrDone: DispatchSemaphore,
        stderrCollector: BoundedStderrCollector,
        timeoutFlag: AtomicFlag,
        timeoutSeconds: TimeInterval,
        serverName: String
    ) throws -> [String: JSONValue] {
        while let lineData = reader.nextLine() {
            if timeoutFlag.isSet {
                throw BentoMCPProbeError.timedOut(
                    serverName: serverName,
                    seconds: timeoutSeconds,
                    stderr: stderrCollector.snapshotString()
                )
            }
            let trimmed = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            guard let obj = try? MCPJSONRPC.decodeJSONObject(Data(trimmed.utf8)) else {
                continue
            }
            if MCPJSONRPC.matchesResponseID(obj, expectedID: expectedID) {
                return obj
            }
        }

        if timeoutFlag.isSet {
            throw BentoMCPProbeError.timedOut(
                serverName: serverName,
                seconds: timeoutSeconds,
                stderr: stderrCollector.snapshotString()
            )
        }

        _ = exitSemaphore.wait(timeout: .now() + .seconds(1))
        _ = stderrDone.wait(timeout: .now() + .seconds(2))
        let stderrText = stderrCollector.snapshotString()

        if !process.isRunning {
            let status = process.terminationStatus
            if status != 0 || process.terminationReason == .uncaughtSignal {
                throw BentoMCPProbeError.processCrashed(
                    serverName: serverName,
                    exitCode: status,
                    stderr: stderrText
                )
            }
        }

        throw BentoMCPProbeError.protocolError(
            serverName: serverName,
            reason: "Server closed stdout before replying to request id \(expectedID)",
            stderr: stderrText
        )
    }

    private static func terminateAndReap(_ process: Process, exitSemaphore: DispatchSemaphore) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        if exitSemaphore.wait(timeout: .now() + .milliseconds(200)) == .timedOut {
            if pid > 0 {
                _ = Darwin.kill(pid, SIGKILL)
            }
            _ = exitSemaphore.wait(timeout: .now() + .milliseconds(250))
        }
    }

    private static func resolveExecutable(
        command: String,
        workingDirectory: URL,
        searchPATH: String
    ) -> URL? {
        let fm = FileManager.default
        if command.contains("/") {
            let candidate: URL
            if command.hasPrefix("/") {
                candidate = URL(fileURLWithPath: command).standardizedFileURL
            } else {
                candidate = workingDirectory.appendingPathComponent(command).standardizedFileURL
            }
            return fm.isExecutableFile(atPath: candidate.path) ? candidate : nil
        }

        for dir in searchPATH.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(dir), isDirectory: true)
                .appendingPathComponent(command)
                .standardizedFileURL
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Concurrency Primitives

private final class ContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Value) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }
}

private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flag {
            return false
        }
        flag = true
        return true
    }
}

private final class BoundedStderrCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var buffer = Data()

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - buffer.count
        guard remaining > 0 else { return }
        if chunk.count <= remaining {
            buffer.append(chunk)
        } else {
            buffer.append(chunk.prefix(remaining))
        }
    }

    func snapshotString() -> String {
        lock.lock()
        let copy = buffer
        lock.unlock()
        return String(decoding: copy, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class PipeLineReader {
    private static let maxLineBytes = 4 * 1024 * 1024
    private let handle: FileHandle
    private var buffer = Data()
    private var reachedEOF = false

    init(handle: FileHandle) {
        self.handle = handle
    }

    func nextLine() -> Data? {
        while true {
            if let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newlineIdx])
                buffer.removeSubrange(buffer.startIndex...newlineIdx)
                return line
            }
            if reachedEOF {
                if buffer.isEmpty {
                    return nil
                }
                let remainder = buffer
                buffer.removeAll(keepingCapacity: false)
                return remainder
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                reachedEOF = true
            } else {
                buffer.append(chunk)
                if buffer.count > Self.maxLineBytes {
                    buffer.removeAll(keepingCapacity: false)
                    reachedEOF = true
                    return nil
                }
            }
        }
    }
}
