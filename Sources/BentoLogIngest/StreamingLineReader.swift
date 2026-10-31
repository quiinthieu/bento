import BentoCore
import Darwin
import Foundation

/// High-speed streaming JSONL line reader over a read-only `FileHandle` (`PLAN.md` §6.2).
///
/// - Uses a 64 KB buffer by default (`bufferSize = 65_536`).
/// - Leaves partial trailing lines uncommitted (`consumedOffset` advances only past complete `\n` delimiters).
/// - Caps single-line buffering at 16 MB (`maxLineBytes = 16 * 1024 * 1024`), skipping oversized lines with
///   an `ingest.lineOversized` diagnostic without allocating unbounded memory.
public struct StreamingLineReader: AsyncSequence, Sendable {
    public typealias Element = Data

    /// Default 64 KB read buffer size (`PLAN.md` §6.2).
    public static let defaultBufferSize = 65_536
    /// Default 16 MB single-line byte cap (`PLAN.md` §6.2).
    public static let defaultMaxLineBytes = 16 * 1024 * 1024

    public let url: URL
    public let startOffset: UInt64
    public let bufferSize: Int
    public let maxLineBytes: Int

    /// Creates a streaming line reader starting at `startOffset`.
    public init(
        url: URL,
        startOffset: UInt64 = 0,
        bufferSize: Int = StreamingLineReader.defaultBufferSize,
        maxLineBytes: Int = StreamingLineReader.defaultMaxLineBytes
    ) {
        self.url = url.standardizedFileURL
        self.startOffset = startOffset
        self.bufferSize = Swift.max(1, bufferSize)
        self.maxLineBytes = Swift.max(64, maxLineBytes)
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            url: url,
            startOffset: startOffset,
            bufferSize: bufferSize,
            maxLineBytes: maxLineBytes
        )
    }

    /// Synchronously streams complete `\n`-delimited lines to `onLine` using zero-copy slices for lines
    /// contained within a single buffer chunk, returning the committed byte offset and any diagnostics.
    public func readLines(_ onLine: (Data) throws -> Void) throws -> LineReadOutcome {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw BentoLogIngestError.unreadableLogFile(
                path: url.path,
                underlyingDescription: error.localizedDescription
            )
        }
        defer { try? handle.close() }

        let fd = handle.fileDescriptor
        if startOffset > 0 {
            let seekResult = Darwin.lseek(fd, off_t(startOffset), SEEK_SET)
            if seekResult < 0 {
                throw BentoLogIngestError.seekFailed(path: url.path, offset: startOffset, errnoCode: errno)
            }
        }

        let bufCap = bufferSize
        let rawBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufCap)
        defer { rawBuf.deallocate() }

        var accumulator: [UInt8] = []
        var discardingOversized = false
        var oversizedByteCount = 0
        var diagnostics: [Diagnostic] = []

        var chunkFileOffset = startOffset
        var committedOffset = startOffset
        var totalBytesRead: UInt64 = 0

        while true {
            let bytesReadNow = Darwin.read(fd, rawBuf, bufCap)
            if bytesReadNow < 0 {
                if errno == EINTR {
                    continue
                }
                throw BentoLogIngestError.readFailed(path: url.path, errnoCode: errno)
            }
            if bytesReadNow == 0 {
                break
            }

            totalBytesRead += UInt64(bytesReadNow)
            var cursor = 0

            while cursor < bytesReadNow {
                let remaining = bytesReadNow - cursor
                let slicePtr = rawBuf.advanced(by: cursor)

                if let foundRaw = memchr(slicePtr, 0x0A, remaining) {
                    let foundPtr = foundRaw.assumingMemoryBound(to: UInt8.self)
                    let segLen = foundPtr - slicePtr
                    let newlineIndexInChunk = cursor + segLen
                    committedOffset = chunkFileOffset + UInt64(newlineIndexInChunk + 1)

                    if discardingOversized {
                        oversizedByteCount += segLen
                        diagnostics.append(
                            Diagnostic(
                                code: "ingest.lineOversized",
                                severity: .warning,
                                message:
                                    "Skipped oversized log line (\(oversizedByteCount) bytes exceeds \(maxLineBytes) byte limit).",
                                location: SourceLocation(path: url.path, realPath: url.path)
                            )
                        )
                        discardingOversized = false
                        oversizedByteCount = 0
                    } else if !accumulator.isEmpty {
                        if accumulator.count + segLen > maxLineBytes {
                            let totalOversized = accumulator.count + segLen
                            accumulator.removeAll(keepingCapacity: false)
                            diagnostics.append(
                                Diagnostic(
                                    code: "ingest.lineOversized",
                                    severity: .warning,
                                    message:
                                        "Skipped oversized log line (\(totalOversized) bytes exceeds \(maxLineBytes) byte limit).",
                                    location: SourceLocation(path: url.path, realPath: url.path)
                                )
                            )
                        } else {
                            if segLen > 0 {
                                accumulator.append(contentsOf: UnsafeBufferPointer(start: slicePtr, count: segLen))
                            }
                            if accumulator.last == 0x0D {
                                accumulator.removeLast()
                            }
                            if !accumulator.isEmpty {
                                try accumulator.withUnsafeMutableBytes { accBytes in
                                    if let base = accBytes.baseAddress {
                                        let view = Data(
                                            bytesNoCopy: base,
                                            count: accBytes.count,
                                            deallocator: .none
                                        )
                                        try onLine(view)
                                    }
                                }
                            }
                            accumulator.removeAll(keepingCapacity: true)
                        }
                    } else {
                        var lineLen = segLen
                        if lineLen > 0 && slicePtr[lineLen - 1] == 0x0D {
                            lineLen -= 1
                        }
                        if lineLen > maxLineBytes {
                            diagnostics.append(
                                Diagnostic(
                                    code: "ingest.lineOversized",
                                    severity: .warning,
                                    message:
                                        "Skipped oversized log line (\(lineLen) bytes exceeds \(maxLineBytes) byte limit).",
                                    location: SourceLocation(path: url.path, realPath: url.path)
                                )
                            )
                        } else if lineLen > 0 {
                            let view = Data(
                                bytesNoCopy: UnsafeMutableRawPointer(slicePtr),
                                count: lineLen,
                                deallocator: .none
                            )
                            try onLine(view)
                        }
                    }

                    cursor = newlineIndexInChunk + 1
                } else {
                    // No newline in remaining chunk bytes -> buffer up to maxLineBytes (stays uncommitted if EOF follows).
                    if discardingOversized {
                        oversizedByteCount += remaining
                    } else if accumulator.count + remaining > maxLineBytes {
                        oversizedByteCount = accumulator.count + remaining
                        accumulator.removeAll(keepingCapacity: false)
                        discardingOversized = true
                    } else {
                        accumulator.append(contentsOf: UnsafeBufferPointer(start: slicePtr, count: remaining))
                    }
                    cursor = bytesReadNow
                }
            }

            chunkFileOffset += UInt64(bytesReadNow)
        }

        return LineReadOutcome(
            consumedOffset: committedOffset,
            bytesRead: totalBytesRead,
            diagnostics: diagnostics,
            errorMessage: nil
        )
    }

    // MARK: - AsyncIterator

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let url: URL
        private let startOffset: UInt64
        private let bufferSize: Int
        private let maxLineBytes: Int

        private var handle: FileHandle?
        private var buffer: [UInt8] = []
        private var bufferLen = 0
        private var cursor = 0
        private var accumulator: [UInt8] = []
        private var discardingOversized = false
        private var didOpen = false
        private var reachedEOF = false

        init(url: URL, startOffset: UInt64, bufferSize: Int, maxLineBytes: Int) {
            self.url = url
            self.startOffset = startOffset
            self.bufferSize = bufferSize
            self.maxLineBytes = maxLineBytes
        }

        public mutating func next() async throws -> Data? {
            if reachedEOF {
                return nil
            }

            if !didOpen {
                didOpen = true
                do {
                    let opened = try FileHandle(forReadingFrom: url)
                    if startOffset > 0 {
                        let rc = Darwin.lseek(opened.fileDescriptor, off_t(startOffset), SEEK_SET)
                        if rc < 0 {
                            try? opened.close()
                            throw BentoLogIngestError.seekFailed(
                                path: url.path,
                                offset: startOffset,
                                errnoCode: errno
                            )
                        }
                    }
                    handle = opened
                    buffer = [UInt8](repeating: 0, count: bufferSize)
                } catch let ingestErr as BentoLogIngestError {
                    reachedEOF = true
                    throw ingestErr
                } catch {
                    reachedEOF = true
                    throw BentoLogIngestError.unreadableLogFile(
                        path: url.path,
                        underlyingDescription: error.localizedDescription
                    )
                }
            }

            guard let fd = handle?.fileDescriptor else {
                reachedEOF = true
                return nil
            }

            while true {
                try Task.checkCancellation()

                if cursor >= bufferLen {
                    let readCount = buffer.withUnsafeMutableBytes { rawBuf -> Int in
                        guard let ptr = rawBuf.baseAddress else { return 0 }
                        return Darwin.read(fd, ptr, rawBuf.count)
                    }
                    if readCount < 0 {
                        if errno == EINTR { continue }
                        closeHandle()
                        throw BentoLogIngestError.readFailed(path: url.path, errnoCode: errno)
                    }
                    if readCount == 0 {
                        // Partial trailing line in `accumulator` is intentionally left uncommitted at EOF.
                        accumulator.removeAll(keepingCapacity: false)
                        closeHandle()
                        return nil
                    }
                    bufferLen = readCount
                    cursor = 0
                }

                // Scan for newline in buffer[cursor..<bufferLen]
                var newlineIdx: Int?
                for idx in cursor..<bufferLen where buffer[idx] == 0x0A {
                    newlineIdx = idx
                    break
                }

                if let nl = newlineIdx {
                    let segLen = nl - cursor
                    if discardingOversized {
                        discardingOversized = false
                        cursor = nl + 1
                        continue
                    }

                    if !accumulator.isEmpty {
                        if accumulator.count + segLen > maxLineBytes {
                            accumulator.removeAll(keepingCapacity: false)
                            cursor = nl + 1
                            continue
                        }
                        if segLen > 0 {
                            accumulator.append(contentsOf: buffer[cursor..<nl])
                        }
                        if accumulator.last == 0x0D {
                            accumulator.removeLast()
                        }
                        cursor = nl + 1
                        if accumulator.isEmpty {
                            continue
                        }
                        let result = Data(accumulator)
                        accumulator.removeAll(keepingCapacity: true)
                        return result
                    } else {
                        var end = nl
                        if end > cursor && buffer[end - 1] == 0x0D {
                            end -= 1
                        }
                        let lineLen = end - cursor
                        let start = cursor
                        cursor = nl + 1
                        if lineLen > maxLineBytes || lineLen == 0 {
                            continue
                        }
                        return Data(buffer[start..<end])
                    }
                } else {
                    let rem = bufferLen - cursor
                    if !discardingOversized {
                        if accumulator.count + rem > maxLineBytes {
                            accumulator.removeAll(keepingCapacity: false)
                            discardingOversized = true
                        } else {
                            accumulator.append(contentsOf: buffer[cursor..<bufferLen])
                        }
                    }
                    cursor = bufferLen
                }
            }
        }

        private mutating func closeHandle() {
            reachedEOF = true
            try? handle?.close()
            handle = nil
        }
    }
}
