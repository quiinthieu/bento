import BentoCore
import CZstd
import Darwin
import Foundation

/// Streaming Zstandard (`.zst`) JSONL line reader backed by vendored `CZstd` (`ZSTD_decompressStream`,
/// `PLAN.md` §6.2).
///
/// Decompresses chunks incrementally into the same 16 MB-capped line splitter as `StreamingLineReader`.
/// Corrupt or truncated `.zst` frames emit a non-fatal `Diagnostic` and `errorMessage` instead of throwing
/// or crashing, while preserving any complete lines decoded prior to the truncation point.
public struct ZstdLineReader: Sendable {
    public let url: URL
    public let maxLineBytes: Int

    /// Creates a streaming Zstandard line reader for `url`.
    public init(
        url: URL,
        maxLineBytes: Int = StreamingLineReader.defaultMaxLineBytes
    ) {
        self.url = url.standardizedFileURL
        self.maxLineBytes = max(64, maxLineBytes)
    }

    /// Streams decompressed `\n`-delimited lines to `onLine`, recording any Zstandard corruption or mid-frame
    /// EOF truncation in `LineReadOutcome.diagnostics` and `LineReadOutcome.errorMessage`.
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

        guard let dstream = ZSTD_createDStream() else {
            throw BentoLogIngestError.zstdStreamAllocationFailed
        }
        defer { ZSTD_freeDStream(dstream) }
        _ = ZSTD_initDStream(dstream)

        let inCap = max(65_536, ZSTD_DStreamInSize())
        let outCap = max(65_536, ZSTD_DStreamOutSize())
        let inRaw = UnsafeMutablePointer<UInt8>.allocate(capacity: inCap)
        let outRaw = UnsafeMutablePointer<UInt8>.allocate(capacity: outCap)
        defer {
            inRaw.deallocate()
            outRaw.deallocate()
        }

        let fd = handle.fileDescriptor
        var physicalBytesRead: UInt64 = 0
        var accumulator: [UInt8] = []
        var discardingOversized = false
        var oversizedByteCount = 0
        var diagnostics: [Diagnostic] = []
        var errorMessage: String?

        var sawAnyCompressedBytes = false
        var lastZstdReturn: Int = 0

        func feedDecompressedChunk(count: Int) throws {
            var cursor = 0
            while cursor < count {
                let remaining = count - cursor
                let slicePtr = outRaw.advanced(by: cursor)

                if let foundRaw = memchr(slicePtr, 0x0A, remaining) {
                    let foundPtr = foundRaw.assumingMemoryBound(to: UInt8.self)
                    let segLen = foundPtr - slicePtr

                    if discardingOversized {
                        oversizedByteCount += segLen
                        diagnostics.append(
                            Diagnostic(
                                code: "ingest.lineOversized",
                                severity: .warning,
                                message:
                                    "Skipped oversized decompressed log line (\(oversizedByteCount) bytes exceeds \(maxLineBytes) byte limit).",
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
                                        "Skipped oversized decompressed log line (\(totalOversized) bytes exceeds \(maxLineBytes) byte limit).",
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
                                        "Skipped oversized decompressed log line (\(lineLen) bytes exceeds \(maxLineBytes) byte limit).",
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

                    cursor += segLen + 1
                } else {
                    if discardingOversized {
                        oversizedByteCount += remaining
                    } else if accumulator.count + remaining > maxLineBytes {
                        oversizedByteCount = accumulator.count + remaining
                        accumulator.removeAll(keepingCapacity: false)
                        discardingOversized = true
                    } else {
                        accumulator.append(contentsOf: UnsafeBufferPointer(start: slicePtr, count: remaining))
                    }
                    cursor = count
                }
            }
        }

        outerReadLoop: while true {
            let n = Darwin.read(fd, inRaw, inCap)
            if n < 0 {
                if errno == EINTR { continue }
                throw BentoLogIngestError.readFailed(path: url.path, errnoCode: errno)
            }
            if n == 0 {
                break
            }

            sawAnyCompressedBytes = true
            physicalBytesRead += UInt64(n)
            var inBuffer = ZSTD_inBuffer(src: UnsafeRawPointer(inRaw), size: n, pos: 0)

            while inBuffer.pos < inBuffer.size {
                var outBuffer = ZSTD_outBuffer(dst: UnsafeMutableRawPointer(outRaw), size: outCap, pos: 0)
                let ret = ZSTD_decompressStream(dstream, &outBuffer, &inBuffer)

                if outBuffer.pos > 0 {
                    try feedDecompressedChunk(count: outBuffer.pos)
                }

                if ZSTD_isError(ret) != 0 {
                    let errName =
                        ZSTD_getErrorName(ret).map { String(cString: $0) }
                        ?? "corrupt zstd stream"
                    let message = "Zstandard decompression failed for '\(url.lastPathComponent)': \(errName)"
                    errorMessage = message
                    diagnostics.append(
                        Diagnostic(
                            code: "ingest.zstdCorrupt",
                            severity: .warning,
                            message: message,
                            location: SourceLocation(path: url.path, realPath: url.path)
                        )
                    )
                    break outerReadLoop
                }

                lastZstdReturn = ret
            }
        }

        if errorMessage == nil && sawAnyCompressedBytes && lastZstdReturn != 0 {
            let message =
                "Truncated Zstandard stream in '\(url.lastPathComponent)' (unexpected EOF mid-frame; expected \(lastZstdReturn) more bytes)."
            errorMessage = message
            diagnostics.append(
                Diagnostic(
                    code: "ingest.zstdTruncated",
                    severity: .warning,
                    message: message,
                    location: SourceLocation(path: url.path, realPath: url.path)
                )
            )
        }

        // Flush a valid non-newline-terminated trailing line only when the zstd frame closed cleanly without truncation.
        if errorMessage == nil && !discardingOversized && !accumulator.isEmpty {
            if accumulator.last == 0x0D {
                accumulator.removeLast()
            }
            if !accumulator.isEmpty {
                try accumulator.withUnsafeMutableBytes { accBytes in
                    if let base = accBytes.baseAddress {
                        let view = Data(bytesNoCopy: base, count: accBytes.count, deallocator: .none)
                        try onLine(view)
                    }
                }
            }
        }

        return LineReadOutcome(
            consumedOffset: physicalBytesRead,
            bytesRead: physicalBytesRead,
            diagnostics: diagnostics,
            errorMessage: errorMessage
        )
    }
}
