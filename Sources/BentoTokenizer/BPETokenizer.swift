import BentoCore
import Foundation
import Synchronization

/// Byte-level BPE tokenizer compatible with OpenAI `tiktoken` (`o200k_base` and `cl100k_base`, `PLAN.md` §6.3).
public final class BPETokenizer: TokenCounter, Sendable {
    private struct SharedCache {
        var instances: [BPEEncoding: BPETokenizer] = [:]
    }

    private static let sharedCache = Mutex(SharedCache())

    /// Returns a cached shared `BPETokenizer` for `encoding`, loading its bundled vocabulary once.
    public static func shared(for encoding: BPEEncoding) throws -> BPETokenizer {
        if let existing = sharedCache.withLock({ $0.instances[encoding] }) {
            return existing
        }
        let loaded = try BPETokenizer(encoding: encoding)
        return sharedCache.withLock { state in
            if let raced = state.instances[encoding] {
                return raced
            }
            state.instances[encoding] = loaded
            return loaded
        }
    }

    /// Encoding identifier (`"o200k_base"` or `"cl100k_base"`).
    public let encoding: BPEEncoding

    /// Stable `TokenCounter` identifier.
    public var id: String { encoding.rawValue }

    private let table: BPERankTable
    private let pieceCountCache = PieceCountCache(maxEntries: 16_384)

    /// Initializes a `BPETokenizer` by loading the bundled vocabulary for `encoding`.
    public convenience init(encoding: BPEEncoding) throws {
        let rawData = try TokenizerResourceLoader.loadVocabularyData(for: encoding)
        try self.init(encoding: encoding, vocabularyData: rawData)
    }

    /// Initializes a `BPETokenizer` from raw `.tiktoken` `<base64> <rank>` vocabulary bytes.
    public init(encoding: BPEEncoding, vocabularyData: Data) throws {
        // Validate regex pattern upfront.
        do {
            _ = try NSRegularExpression(pattern: encoding.preTokenizationPattern, options: [])
        } catch {
            throw BentoTokenizerError.invalidPreTokenizationPattern(encoding.rawValue)
        }
        self.encoding = encoding
        self.table = try BPERankTable(
            vocabularyData: vocabularyData,
            capacity: encoding.hashTableCapacity,
            encodingName: encoding.rawValue
        )
    }

    /// Encodes `text` as ordinary text (no special-token interception) into exact BPE token ranks.
    public func encode(_ text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        var contiguous = text
        contiguous.makeContiguousUTF8()

        return contiguous.withUTF8 { utf8Buf in
            guard !utf8Buf.isEmpty, let base = utf8Buf.baseAddress else { return [] }
            let chunks = Self.computeChunkSpans(base: base, startOffset: 0, endOffset: utf8Buf.count)
            var tokens: [Int] = []
            tokens.reserveCapacity(max(8, utf8Buf.count / 3))
            var mergeParts: [(start: Int, rank: Int32)] = []
            mergeParts.reserveCapacity(128)
            var utf16Scratch: [UInt16] = []
            var utf8Scratch: [UInt8] = []

            for span in chunks where span.count > 0 {
                let chunkPtr = base + span.start
                if span.isASCII {
                    encodeASCIIChunk(ptr: chunkPtr, count: span.count, parts: &mergeParts, into: &tokens)
                } else if let regex = threadLocalRegex() {
                    let slice = UnsafeBufferPointer(start: chunkPtr, count: span.count)
                    let chunkStr = String(decoding: slice, as: UTF8.self)
                    encodeUnicodeChunk(
                        chunkStr,
                        regex: regex,
                        parts: &mergeParts,
                        utf16Scratch: &utf16Scratch,
                        utf8Scratch: &utf8Scratch,
                        into: &tokens
                    )
                }
            }
            return tokens
        }
    }

    /// Encodes `text` forcing the ICU `NSRegularExpression` path (exposed internally for parity verification tests).
    func encodeForcingUnicodeRegex(_ text: String) -> [Int] {
        guard !text.isEmpty, let regex = threadLocalRegex() else { return [] }
        var contiguous = text
        contiguous.makeContiguousUTF8()
        return contiguous.withUTF8 { utf8Buf in
            guard !utf8Buf.isEmpty, let base = utf8Buf.baseAddress else { return [] }
            let chunks = Self.computeChunkSpans(base: base, startOffset: 0, endOffset: utf8Buf.count)
            var tokens: [Int] = []
            tokens.reserveCapacity(max(8, utf8Buf.count / 3))
            var mergeParts: [(start: Int, rank: Int32)] = []
            mergeParts.reserveCapacity(128)
            var utf16Scratch: [UInt16] = []
            var utf8Scratch: [UInt8] = []
            for span in chunks where span.count > 0 {
                let slice = UnsafeBufferPointer(start: base + span.start, count: span.count)
                let chunkStr = String(decoding: slice, as: UTF8.self)
                encodeUnicodeChunk(
                    chunkStr,
                    regex: regex,
                    parts: &mergeParts,
                    utf16Scratch: &utf16Scratch,
                    utf8Scratch: &utf8Scratch,
                    into: &tokens
                )
            }
            return tokens
        }
    }

    /// Clears internal multi-byte piece caches (internal hook for cold-start throughput benchmarks).
    func resetCachesForTesting() {
        pieceCountCache.clear()
    }

    /// Counts exact BPE tokens in `text`.
    public func count(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var contiguous = text
        contiguous.makeContiguousUTF8()

        return contiguous.withUTF8 { utf8Buf in
            guard !utf8Buf.isEmpty, let base = utf8Buf.baseAddress else { return 0 }
            if utf8Buf.count >= 65_536 {
                return countLargeBufferParallel(base: base, total: utf8Buf.count)
            }
            let chunks = Self.computeChunkSpans(base: base, startOffset: 0, endOffset: utf8Buf.count)

            var localCache: [UInt64: (bytes: [UInt8], count: Int)] = [:]
            localCache.reserveCapacity(512)
            var mergeParts: [(start: Int, rank: Int32)] = []
            mergeParts.reserveCapacity(128)
            var utf16Scratch: [UInt16] = []
            var utf8Scratch: [UInt8] = []

            var total = 0
            for span in chunks {
                total += countSingleChunk(
                    base: base,
                    span: span,
                    parts: &mergeParts,
                    localCache: &localCache,
                    utf16Scratch: &utf16Scratch,
                    utf8Scratch: &utf8Scratch
                )
            }
            return total
        }
    }

    // MARK: - Thread-Local Compiled Regex & ASCII-Isolating Line Chunking

    private struct ChunkSpan: Sendable {
        var start: Int
        var count: Int
        var isASCII: Bool
    }

    private func threadLocalRegex() -> NSRegularExpression? {
        let key = "BentoTokenizer.regex.\(encoding.rawValue)" as NSString
        let dict = Thread.current.threadDictionary
        if let cached = dict.object(forKey: key) as? NSRegularExpression {
            return cached
        }
        guard let compiled = try? NSRegularExpression(pattern: encoding.preTokenizationPattern, options: []) else {
            return nil
        }
        dict.setObject(compiled, forKey: key)
        return compiled
    }

    private static let targetASCIIChunkBytes = 4_096

    private static func computeChunkSpans(
        base: UnsafePointer<UInt8>,
        startOffset: Int,
        endOffset: Int
    ) -> [ChunkSpan] {
        let sliceLen = endOffset - startOffset
        guard sliceLen > 0 else { return [] }
        var spans: [ChunkSpan] = []
        spans.reserveCapacity(max(4, sliceLen / 2_048 + 2))
        let rawBase = UnsafeRawPointer(base)

        var pendingStart = startOffset
        var segmentStart = startOffset
        var segmentHasNonASCII = false
        var pos = startOffset

        while pos < endOffset {
            // SWAR fast-skip: advance 8 bytes at once when all 8 bytes are ASCII (< 0x80) and none is '\n' (0x0A).
            if pos + 8 <= endOffset {
                let word = rawBase.loadUnaligned(fromByteOffset: pos, as: UInt64.self)
                if (word & 0x8080_8080_8080_8080) == 0 {
                    let xored = word ^ 0x0A0A_0A0A_0A0A_0A0A
                    if ((xored &- 0x0101_0101_0101_0101) & 0x8080_8080_8080_8080) == 0 {
                        pos += 8
                        continue
                    }
                }
            }

            let b = base[pos]
            if b >= 0x80 {
                segmentHasNonASCII = true
            } else if b == 10 && pos + 1 < endOffset {
                let nextByte = base[pos + 1]
                if nextByte < 0x80 && !isSpace8(nextByte) && nextByte != 47 {
                    let split = pos + 1
                    if segmentHasNonASCII {
                        if segmentStart > pendingStart {
                            spans.append(
                                ChunkSpan(start: pendingStart, count: segmentStart - pendingStart, isASCII: true)
                            )
                        }
                        spans.append(
                            ChunkSpan(start: segmentStart, count: split - segmentStart, isASCII: false)
                        )
                        pendingStart = split
                        segmentHasNonASCII = false
                    } else if split - pendingStart >= targetASCIIChunkBytes {
                        spans.append(
                            ChunkSpan(start: pendingStart, count: split - pendingStart, isASCII: true)
                        )
                        pendingStart = split
                    }
                    segmentStart = split
                }
            }
            pos += 1
        }

        if pendingStart < endOffset {
            if segmentHasNonASCII {
                if segmentStart > pendingStart {
                    spans.append(
                        ChunkSpan(start: pendingStart, count: segmentStart - pendingStart, isASCII: true)
                    )
                }
                spans.append(
                    ChunkSpan(start: segmentStart, count: endOffset - segmentStart, isASCII: false)
                )
            } else {
                spans.append(
                    ChunkSpan(start: pendingStart, count: endOffset - pendingStart, isASCII: true)
                )
            }
        }
        return spans
    }

    private func countLargeBufferParallel(base: UnsafePointer<UInt8>, total: Int) -> Int {
        let workerCount = max(2, ProcessInfo.processInfo.activeProcessorCount)
        let targetBlocks = workerCount * 4
        var coarseBlocks: [Range<Int>] = []
        coarseBlocks.reserveCapacity(targetBlocks)

        var blockStart = 0
        for blockIdx in 1..<targetBlocks {
            let nominal = (total * blockIdx) / targetBlocks
            var pos = nominal > blockStart ? nominal : blockStart
            var splitFound: Int?
            while pos + 1 < total {
                if base[pos] == 10 {
                    let nextByte = base[pos + 1]
                    if nextByte < 0x80 && !Self.isSpace8(nextByte) && nextByte != 47 {
                        splitFound = pos + 1
                        break
                    }
                }
                pos += 1
            }
            if let split = splitFound, split > blockStart {
                coarseBlocks.append(blockStart..<split)
                blockStart = split
            } else {
                break
            }
        }
        if blockStart < total {
            coarseBlocks.append(blockStart..<total)
        }

        let blocks = coarseBlocks
        let activeWorkers = min(workerCount, blocks.count)
        let partialTotals = Mutex([Int](repeating: 0, count: activeWorkers))
        let addr = Int(bitPattern: base)

        DispatchQueue.concurrentPerform(iterations: activeWorkers) { workerIdx in
            guard let ptr = UnsafePointer<UInt8>(bitPattern: addr) else { return }
            var localCache: [UInt64: (bytes: [UInt8], count: Int)] = [:]
            localCache.reserveCapacity(512)
            var mergeParts: [(start: Int, rank: Int32)] = []
            mergeParts.reserveCapacity(128)
            var utf16Scratch: [UInt16] = []
            var utf8Scratch: [UInt8] = []

            var workerSum = 0
            var idx = workerIdx
            while idx < blocks.count {
                let block = blocks[idx]
                let spans = Self.computeChunkSpans(
                    base: ptr,
                    startOffset: block.lowerBound,
                    endOffset: block.upperBound
                )
                for span in spans {
                    workerSum += countSingleChunk(
                        base: ptr,
                        span: span,
                        parts: &mergeParts,
                        localCache: &localCache,
                        utf16Scratch: &utf16Scratch,
                        utf8Scratch: &utf8Scratch
                    )
                }
                idx += activeWorkers
            }
            partialTotals.withLock { $0[workerIdx] = workerSum }
        }

        return partialTotals.withLock { $0.reduce(0, +) }
    }

    private func countSingleChunk(
        base: UnsafePointer<UInt8>,
        span: ChunkSpan,
        parts: inout [(start: Int, rank: Int32)],
        localCache: inout [UInt64: (bytes: [UInt8], count: Int)],
        utf16Scratch: inout [UInt16],
        utf8Scratch: inout [UInt8]
    ) -> Int {
        guard span.count > 0 else { return 0 }
        let chunkPtr = base + span.start
        if span.isASCII {
            return countASCIIChunk(ptr: chunkPtr, count: span.count, parts: &parts, localCache: &localCache)
        }
        guard let regex = threadLocalRegex() else { return 0 }
        let slice = UnsafeBufferPointer(start: chunkPtr, count: span.count)
        let chunkStr = String(decoding: slice, as: UTF8.self)
        return countUnicodeChunk(
            chunkStr,
            regex: regex,
            parts: &parts,
            localCache: &localCache,
            utf16Scratch: &utf16Scratch,
            utf8Scratch: &utf8Scratch
        )
    }

    // MARK: - Zero-Copy ASCII Pre-Tokenizer Fast Path

    @inline(__always)
    private static func asciiContractionLength(ptr: UnsafePointer<UInt8>, index: Int, end: Int) -> Int {
        guard index + 1 < end, ptr[index] == 39 else { return 0 }
        let c1 = ptr[index + 1] | 0x20
        if c1 == 115 || c1 == 116 || c1 == 109 || c1 == 100 {
            return 2
        }
        if index + 2 < end {
            let c2 = ptr[index + 2] | 0x20
            if (c1 == 114 && c2 == 101)
                || (c1 == 118 && c2 == 101)
                || (c1 == 108 && c2 == 108)
            {
                return 3
            }
        }
        return 0
    }

    @inline(__always)
    private static func isSpace8(_ b: UInt8) -> Bool {
        b == 32 || (b >= 9 && b <= 13)
    }

    @inline(__always)
    private static func isUpper8(_ b: UInt8) -> Bool {
        b >= 65 && b <= 90
    }

    @inline(__always)
    private static func isLower8(_ b: UInt8) -> Bool {
        b >= 97 && b <= 122
    }

    @inline(__always)
    private static func isLetter8(_ b: UInt8) -> Bool {
        (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
    }

    @inline(__always)
    private static func isDigit8(_ b: UInt8) -> Bool {
        b >= 48 && b <= 57
    }

    @inline(__always)
    private static func isAlnum8(_ b: UInt8) -> Bool {
        (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57)
    }

    @inline(__always)
    private static func isPunct8(_ b: UInt8) -> Bool {
        !(b == 32 || (b >= 9 && b <= 13))
            && !((b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57))
    }

    @inline(__always)
    private static func nextASCIITokenEnd(
        isO200k: Bool,
        ptr: UnsafePointer<UInt8>,
        start i: Int,
        end n: Int
    ) -> Int {
        let b0 = ptr[i]
        if isO200k {
            let p0 = (b0 != 10 && b0 != 13 && !isAlnum8(b0)) ? (i + 1) : i
            if p0 < n {
                var p = p0
                while p < n && isUpper8(ptr[p]) { p += 1 }
                let lowerStart = p
                while p < n && isLower8(ptr[p]) { p += 1 }
                if p > lowerStart {
                    return p + asciiContractionLength(ptr: ptr, index: p, end: n)
                }
                if isUpper8(ptr[p0]) {
                    var u = p0 + 1
                    while u < n && isUpper8(ptr[u]) { u += 1 }
                    while u < n && isLower8(ptr[u]) { u += 1 }
                    return u + asciiContractionLength(ptr: ptr, index: u, end: n)
                }
            }
            if isDigit8(b0) {
                var p = i + 1
                if p < n && isDigit8(ptr[p]) {
                    p += 1
                    if p < n && isDigit8(ptr[p]) { p += 1 }
                }
                return p
            }
            if isPunct8(b0) || (b0 == 32 && i + 1 < n && isPunct8(ptr[i + 1])) {
                var p = (b0 == 32) ? (i + 2) : (i + 1)
                while p < n && isPunct8(ptr[p]) { p += 1 }
                while p < n {
                    let bp = ptr[p]
                    if bp != 10 && bp != 13 && bp != 47 { break }
                    p += 1
                }
                return p
            }
        } else {
            let cLen = asciiContractionLength(ptr: ptr, index: i, end: n)
            if cLen > 0 {
                return i + cLen
            }
            let p0 = (b0 != 10 && b0 != 13 && !isAlnum8(b0)) ? (i + 1) : i
            if p0 < n && isLetter8(ptr[p0]) {
                var p = p0 + 1
                while p < n && isLetter8(ptr[p]) { p += 1 }
                return p
            }
            if isDigit8(b0) {
                var p = i + 1
                if p < n && isDigit8(ptr[p]) {
                    p += 1
                    if p < n && isDigit8(ptr[p]) { p += 1 }
                }
                return p
            }
            if isPunct8(b0) || (b0 == 32 && i + 1 < n && isPunct8(ptr[i + 1])) {
                var p = (b0 == 32) ? (i + 2) : (i + 1)
                while p < n && isPunct8(ptr[p]) { p += 1 }
                while p < n {
                    let bp = ptr[p]
                    if bp != 10 && bp != 13 { break }
                    p += 1
                }
                return p
            }
        }

        // Branches 5, 6, 7: whitespace (\s*[\r\n]+ | \s+(?!\S) | \s+)
        var p = i
        var lastCRLF = -1
        while p < n {
            let bp = ptr[p]
            if !isSpace8(bp) { break }
            if bp == 10 || bp == 13 {
                lastCRLF = p
            }
            p += 1
        }
        if lastCRLF >= i {
            return lastCRLF + 1
        }
        if p == n {
            return p
        }
        if p - i >= 2 {
            return p - 1
        }
        return (p > i + 1) ? p : (i + 1)
    }

    private func encodeASCIIChunk(
        ptr: UnsafePointer<UInt8>,
        count: Int,
        parts: inout [(start: Int, rank: Int32)],
        into output: inout [Int]
    ) {
        let isO200k = (encoding == .o200kBase)
        table.withPointers { ptrs in
            var cursor = 0
            while cursor < count {
                let end = Self.nextASCIITokenEnd(
                    isO200k: isO200k,
                    ptr: ptr,
                    start: cursor,
                    end: count
                )
                let tokenPtr = ptr + cursor
                let byteLen = end - cursor
                cursor = end

                if byteLen == 1 {
                    let r = ptrs.singleByte[Int(tokenPtr[0])]
                    if r >= 0 {
                        output.append(Int(r))
                        continue
                    }
                } else if byteLen == 2 {
                    let r = ptrs.twoByteASCII[(Int(tokenPtr[0]) << 7) | Int(tokenPtr[1])]
                    if r >= 0 {
                        output.append(Int(r))
                        continue
                    }
                }

                let hash = BPERankTable.fnv1a64(ptr: tokenPtr, count: byteLen)
                if let directRank = BPERankTable.lookupRaw(
                    queryBase: tokenPtr,
                    len: byteLen,
                    hash: hash,
                    ptrs: ptrs
                ) {
                    output.append(Int(directRank))
                } else {
                    let buf = UnsafeBufferPointer(start: tokenPtr, count: byteLen)
                    Self.bytePairEncode(buf, ptrs: ptrs, parts: &parts, into: &output)
                }
            }
        }
    }

    private func countASCIIChunk(
        ptr: UnsafePointer<UInt8>,
        count: Int,
        parts: inout [(start: Int, rank: Int32)],
        localCache: inout [UInt64: (bytes: [UInt8], count: Int)]
    ) -> Int {
        let isO200k = (encoding == .o200kBase)
        var chunkCount = 0

        table.withPointers { ptrs in
            let arenaBase = ptrs.arena
            let packedBase = ptrs.packedSlots
            let singleByteBase = ptrs.singleByte
            let twoByteASCIIBase = ptrs.twoByteASCII
            let tableMask = ptrs.mask
            let mask64 = UInt64(tableMask)

            var cursor = 0
            while cursor < count {
                let tokenStart = cursor
                let end = Self.nextASCIITokenEnd(
                    isO200k: isO200k,
                    ptr: ptr,
                    start: tokenStart,
                    end: count
                )
                let tokenPtr = ptr + tokenStart
                let byteLen = end - tokenStart
                cursor = end

                if byteLen == 1 {
                    if singleByteBase[Int(tokenPtr[0])] >= 0 {
                        chunkCount += 1
                        continue
                    }
                } else if byteLen == 2 {
                    if twoByteASCIIBase[(Int(tokenPtr[0]) << 7) | Int(tokenPtr[1])] >= 0 {
                        chunkCount += 1
                        continue
                    }
                }

                var hash: UInt64 = 14_695_981_039_346_656_037
                var hIdx = 0
                if tokenStart + 8 <= count && byteLen <= 8 {
                    var word = UInt64(littleEndian: UnsafeRawPointer(tokenPtr).loadUnaligned(as: UInt64.self))
                    while hIdx < byteLen {
                        hash ^= (word & 0xFF)
                        hash &*= 1_099_511_628_211
                        word >>= 8
                        hIdx += 1
                    }
                } else {
                    while hIdx < byteLen {
                        hash ^= UInt64(tokenPtr[hIdx])
                        hash &*= 1_099_511_628_211
                        hIdx += 1
                    }
                }

                var matchedSingleToken = false
                if byteLen <= Int(UInt16.max) {
                    var slotIndex = Int(hash & mask64)
                    while true {
                        let packed = packedBase[slotIndex]
                        if packed == 0 {
                            break
                        }
                        if Int(packed & 0xFFFF) == byteLen,
                            memcmp(arenaBase + Int(packed >> 16), tokenPtr, byteLen) == 0
                        {
                            matchedSingleToken = true
                            break
                        }
                        slotIndex = (slotIndex + 1) & tableMask
                    }
                }
                if matchedSingleToken {
                    chunkCount += 1
                    continue
                }

                let buf = UnsafeBufferPointer(start: tokenPtr, count: byteLen)
                if byteLen <= 64 {
                    if let hit = localCache[hash],
                        hit.bytes.count == byteLen,
                        hit.bytes.withUnsafeBufferPointer({
                            guard let hitBase = $0.baseAddress else { return false }
                            return memcmp(hitBase, tokenPtr, byteLen) == 0
                        })
                    {
                        chunkCount += hit.count
                        continue
                    }
                    if let sharedHit = pieceCountCache.lookup(buf, hash: hash) {
                        if localCache.count < 4_096 {
                            localCache[hash] = (Array(buf), sharedHit)
                        }
                        chunkCount += sharedHit
                        continue
                    }
                }

                let mergedCount = Self.bytePairCount(buf, ptrs: ptrs, parts: &parts)
                if byteLen <= 64 {
                    let saved = Array(buf)
                    if localCache.count < 4_096 {
                        localCache[hash] = (saved, mergedCount)
                    }
                    pieceCountCache.store(saved, hash: hash, count: mergedCount)
                }
                chunkCount += mergedCount
            }
        }
        return chunkCount
    }

    // MARK: - Unicode ICU Fallback Path

    private func encodeUnicodeChunk(
        _ chunk: String,
        regex: NSRegularExpression,
        parts: inout [(start: Int, rank: Int32)],
        utf16Scratch: inout [UInt16],
        utf8Scratch: inout [UInt8],
        into output: inout [Int]
    ) {
        let nsChunk = chunk as NSString
        let utf16Len = nsChunk.length
        guard utf16Len > 0 else { return }

        if utf16Scratch.count < utf16Len {
            utf16Scratch = [UInt16](repeating: 0, count: max(utf16Len, 256))
        }
        nsChunk.getCharacters(&utf16Scratch, range: NSRange(location: 0, length: utf16Len))
        let neededUTF8 = max(64, utf16Len * 3)
        if utf8Scratch.count < neededUTF8 {
            utf8Scratch = [UInt8](repeating: 0, count: neededUTF8)
        }

        utf16Scratch.withUnsafeBufferPointer { utf16Ptr in
            utf8Scratch.withUnsafeMutableBufferPointer { scratchPtr in
                table.withPointers { ptrs in
                    guard let utf16Base = utf16Ptr.baseAddress,
                        let scratchBase = scratchPtr.baseAddress
                    else {
                        return
                    }

                    regex.enumerateMatches(
                        in: chunk,
                        options: [],
                        range: NSRange(location: 0, length: utf16Len)
                    ) { match, _, _ in
                        guard let range = match?.range, range.length > 0 else { return }
                        let byteLen = Self.transcodeUTF16ToUTF8(
                            src: utf16Base.advanced(by: range.location),
                            length: range.length,
                            dst: scratchBase
                        )
                        guard byteLen > 0 else { return }
                        if byteLen == 1 {
                            let r = ptrs.singleByte[Int(scratchBase[0])]
                            if r >= 0 {
                                output.append(Int(r))
                                return
                            }
                        }
                        let buf = UnsafeBufferPointer(start: scratchBase, count: byteLen)
                        let hash = BPERankTable.fnv1a64(ptr: scratchBase, count: byteLen)
                        if let directRank = BPERankTable.lookupRaw(
                            queryBase: scratchBase,
                            len: byteLen,
                            hash: hash,
                            ptrs: ptrs
                        ) {
                            output.append(Int(directRank))
                            return
                        }
                        Self.bytePairEncode(buf, ptrs: ptrs, parts: &parts, into: &output)
                    }
                }
            }
        }
    }

    private func countUnicodeChunk(
        _ chunk: String,
        regex: NSRegularExpression,
        parts: inout [(start: Int, rank: Int32)],
        localCache: inout [UInt64: (bytes: [UInt8], count: Int)],
        utf16Scratch: inout [UInt16],
        utf8Scratch: inout [UInt8]
    ) -> Int {
        let nsChunk = chunk as NSString
        let utf16Len = nsChunk.length
        guard utf16Len > 0 else { return 0 }

        if utf16Scratch.count < utf16Len {
            utf16Scratch = [UInt16](repeating: 0, count: max(utf16Len, 256))
        }
        nsChunk.getCharacters(&utf16Scratch, range: NSRange(location: 0, length: utf16Len))
        let neededUTF8 = max(64, utf16Len * 3)
        if utf8Scratch.count < neededUTF8 {
            utf8Scratch = [UInt8](repeating: 0, count: neededUTF8)
        }

        var chunkCount = 0
        utf16Scratch.withUnsafeBufferPointer { utf16Ptr in
            utf8Scratch.withUnsafeMutableBufferPointer { scratchPtr in
                table.withPointers { ptrs in
                    guard let utf16Base = utf16Ptr.baseAddress,
                        let scratchBase = scratchPtr.baseAddress
                    else {
                        return
                    }

                    regex.enumerateMatches(
                        in: chunk,
                        options: [],
                        range: NSRange(location: 0, length: utf16Len)
                    ) { match, _, _ in
                        guard let range = match?.range, range.length > 0 else { return }
                        let byteLen = Self.transcodeUTF16ToUTF8(
                            src: utf16Base.advanced(by: range.location),
                            length: range.length,
                            dst: scratchBase
                        )
                        guard byteLen > 0 else { return }
                        if byteLen == 1 && ptrs.singleByte[Int(scratchBase[0])] >= 0 {
                            chunkCount += 1
                            return
                        }
                        let hash = BPERankTable.fnv1a64(ptr: scratchBase, count: byteLen)
                        if BPERankTable.lookupRaw(
                            queryBase: scratchBase,
                            len: byteLen,
                            hash: hash,
                            ptrs: ptrs
                        ) != nil {
                            chunkCount += 1
                            return
                        }

                        let buf = UnsafeBufferPointer(start: scratchBase, count: byteLen)
                        if byteLen <= 64 {
                            if let hit = localCache[hash],
                                hit.bytes.count == byteLen,
                                hit.bytes.withUnsafeBufferPointer({
                                    guard let hitBase = $0.baseAddress else { return false }
                                    return memcmp(hitBase, scratchBase, byteLen) == 0
                                })
                            {
                                chunkCount += hit.count
                                return
                            }
                            if let sharedHit = pieceCountCache.lookup(buf, hash: hash) {
                                if localCache.count < 4_096 {
                                    localCache[hash] = (Array(buf), sharedHit)
                                }
                                chunkCount += sharedHit
                                return
                            }
                        }

                        let mergedCount = Self.bytePairCount(buf, ptrs: ptrs, parts: &parts)
                        if byteLen <= 64 {
                            let saved = Array(buf)
                            if localCache.count < 4_096 {
                                localCache[hash] = (saved, mergedCount)
                            }
                            pieceCountCache.store(saved, hash: hash, count: mergedCount)
                        }
                        chunkCount += mergedCount
                    }
                }
            }
        }
        return chunkCount
    }

    @inline(__always)
    private static func transcodeUTF16ToUTF8(
        src: UnsafePointer<UInt16>,
        length: Int,
        dst: UnsafeMutablePointer<UInt8>
    ) -> Int {
        var idx = 0
        var out = 0
        while idx < length {
            let unit = src[idx]
            if unit < 0x80 {
                dst[out] = UInt8(truncatingIfNeeded: unit)
                out += 1
                idx += 1
            } else if unit < 0x800 {
                dst[out] = UInt8(0xC0 | (unit >> 6))
                dst[out + 1] = UInt8(0x80 | (unit & 0x3F))
                out += 2
                idx += 1
            } else if unit >= 0xD800 && unit <= 0xDBFF {
                if idx + 1 < length {
                    let low = src[idx + 1]
                    if low >= 0xDC00 && low <= 0xDFFF {
                        let scalar = 0x10000 + ((UInt32(unit - 0xD800) << 10) | UInt32(low - 0xDC00))
                        dst[out] = UInt8(0xF0 | (scalar >> 18))
                        dst[out + 1] = UInt8(0x80 | ((scalar >> 12) & 0x3F))
                        dst[out + 2] = UInt8(0x80 | ((scalar >> 6) & 0x3F))
                        dst[out + 3] = UInt8(0x80 | (scalar & 0x3F))
                        out += 4
                        idx += 2
                        continue
                    }
                }
                // Unpaired high surrogate -> U+FFFD replacement bytes
                dst[out] = 0xEF
                dst[out + 1] = 0xBF
                dst[out + 2] = 0xBD
                out += 3
                idx += 1
            } else if unit >= 0xDC00 && unit <= 0xDFFF {
                // Unpaired low surrogate -> U+FFFD replacement bytes
                dst[out] = 0xEF
                dst[out + 1] = 0xBF
                dst[out + 2] = 0xBD
                out += 3
                idx += 1
            } else {
                dst[out] = UInt8(0xE0 | (unit >> 12))
                dst[out + 1] = UInt8(0x80 | ((unit >> 6) & 0x3F))
                dst[out + 2] = UInt8(0x80 | (unit & 0x3F))
                out += 3
                idx += 1
            }
        }
        return out
    }

    // MARK: - Exact tiktoken Byte-Pair Merge (`openai/tiktoken/src/lib.rs`)

    private static func bytePairEncode(
        _ piece: UnsafeBufferPointer<UInt8>,
        ptrs: BPERankTable.Pointers,
        parts: inout [(start: Int, rank: Int32)],
        into output: inout [Int]
    ) {
        runBytePairMerge(piece, ptrs: ptrs, parts: &parts)
        guard let base = piece.baseAddress else { return }
        for idx in 0..<(parts.count - 1) {
            let start = parts[idx].start
            let end = parts[idx + 1].start
            if let rank = BPERankTable.lookupFast(
                queryBase: base.advanced(by: start),
                len: end - start,
                ptrs: ptrs
            ) {
                output.append(Int(rank))
            }
        }
    }

    private static func bytePairCount(
        _ piece: UnsafeBufferPointer<UInt8>,
        ptrs: BPERankTable.Pointers,
        parts: inout [(start: Int, rank: Int32)]
    ) -> Int {
        runBytePairMerge(piece, ptrs: ptrs, parts: &parts)
        return max(0, parts.count - 1)
    }

    private static func runBytePairMerge(
        _ piece: UnsafeBufferPointer<UInt8>,
        ptrs: BPERankTable.Pointers,
        parts: inout [(start: Int, rank: Int32)]
    ) {
        let count = piece.count
        parts.removeAll(keepingCapacity: true)
        guard count > 0, let base = piece.baseAddress else { return }

        var minRank = Int32.max
        var minIndex = 0
        let twoByteBase = ptrs.twoByteASCII

        for idx in 0..<(count - 1) {
            let b0 = base[idx]
            let b1 = base[idx + 1]
            let rank: Int32
            if (b0 | b1) < 0x80 {
                let fast = twoByteBase[(Int(b0) << 7) | Int(b1)]
                rank = fast >= 0 ? fast : Int32.max
            } else {
                rank = BPERankTable.lookupFast(queryBase: base.advanced(by: idx), len: 2, ptrs: ptrs) ?? Int32.max
            }
            if rank < minRank {
                minRank = rank
                minIndex = idx
            }
            parts.append((start: idx, rank: rank))
        }
        parts.append((start: count - 1, rank: Int32.max))
        parts.append((start: count, rank: Int32.max))

        while minRank != Int32.max {
            let i = minIndex
            if i > 0 {
                parts[i - 1].rank = pairRank(at: i - 1, skippingNext: true, parts: parts, base: base, ptrs: ptrs)
            }
            parts[i].rank = pairRank(at: i, skippingNext: true, parts: parts, base: base, ptrs: ptrs)
            parts.remove(at: i + 1)

            minRank = Int32.max
            minIndex = 0
            for scanIdx in 0..<(parts.count - 1) {
                let rank = parts[scanIdx].rank
                if rank < minRank {
                    minRank = rank
                    minIndex = scanIdx
                }
            }
        }
    }

    private static func pairRank(
        at index: Int,
        skippingNext: Bool,
        parts: [(start: Int, rank: Int32)],
        base: UnsafePointer<UInt8>,
        ptrs: BPERankTable.Pointers
    ) -> Int32 {
        let endPartIndex = skippingNext ? (index + 3) : (index + 2)
        guard endPartIndex < parts.count else {
            return Int32.max
        }
        let start = parts[index].start
        let end = parts[endPartIndex].start
        return BPERankTable.lookupFast(queryBase: base.advanced(by: start), len: end - start, ptrs: ptrs) ?? Int32.max
    }
}

// MARK: - Flat Arena Open-Addressed Rank Table

private struct BPERankTable: Sendable {
    struct Pointers {
        var arena: UnsafePointer<UInt8>
        var packedSlots: UnsafePointer<UInt64>
        var ranks: UnsafePointer<Int32>
        var singleByte: UnsafePointer<Int32>
        var twoByteASCII: UnsafePointer<Int32>
        var mask: Int
    }

    let arena: [UInt8]
    let packedSlots: [UInt64]
    let ranks: [Int32]
    let singleByteRanks: [Int32]
    let twoByteASCIIRanks: [Int32]
    let mask: Int

    init(vocabularyData: Data, capacity: Int, encodingName: String) throws {
        precondition(capacity > 0 && (capacity & (capacity - 1)) == 0)
        let decodeTable = Self.base64DecodeTable
        let tableMask = capacity - 1

        var builtArena: [UInt8] = []
        builtArena.reserveCapacity(vocabularyData.count)
        var builtPacked = [UInt64](repeating: 0, count: capacity)
        var builtRanks = [Int32](repeating: 0, count: capacity)
        var builtSingleByte = [Int32](repeating: -1, count: 256)
        var builtTwoByteASCII = [Int32](repeating: -1, count: 16_384)

        try vocabularyData.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            let total = rawBuffer.count
            var cursor = 0
            var lineNumber = 0
            var decodedToken: [UInt8] = []
            decodedToken.reserveCapacity(256)

            while cursor < total {
                // Skip leading CR/LF
                while cursor < total && (ptr[cursor] == 10 || ptr[cursor] == 13) {
                    cursor += 1
                }
                if cursor >= total { break }
                lineNumber += 1

                let b64Start = cursor
                while cursor < total && ptr[cursor] != 32 && ptr[cursor] != 10 && ptr[cursor] != 13 {
                    cursor += 1
                }
                let b64End = cursor
                guard cursor < total, ptr[cursor] == 32 else {
                    throw BentoTokenizerError.malformedVocabularyEntry(encoding: encodingName, line: lineNumber)
                }
                cursor += 1  // skip space

                var parsedRank: Int32 = 0
                var hasDigits = false
                while cursor < total && ptr[cursor] >= 48 && ptr[cursor] <= 57 {
                    hasDigits = true
                    parsedRank = parsedRank &* 10 &+ Int32(ptr[cursor] - 48)
                    cursor += 1
                }
                guard hasDigits else {
                    throw BentoTokenizerError.malformedVocabularyEntry(encoding: encodingName, line: lineNumber)
                }

                // Consume until end of line
                while cursor < total && ptr[cursor] != 10 && ptr[cursor] != 13 {
                    cursor += 1
                }

                decodedToken.removeAll(keepingCapacity: true)
                let b64Slice = UnsafeBufferPointer(start: ptr.advanced(by: b64Start), count: b64End - b64Start)
                guard Self.decodeBase64(b64Slice, table: decodeTable, into: &decodedToken),
                    !decodedToken.isEmpty,
                    decodedToken.count <= Int(UInt16.max)
                else {
                    throw BentoTokenizerError.malformedVocabularyEntry(encoding: encodingName, line: lineNumber)
                }

                if decodedToken.count == 1 {
                    builtSingleByte[Int(decodedToken[0])] = parsedRank
                } else if decodedToken.count == 2 && (decodedToken[0] | decodedToken[1]) < 0x80 {
                    builtTwoByteASCII[(Int(decodedToken[0]) << 7) | Int(decodedToken[1])] = parsedRank
                }

                let tokenOffset = UInt64(builtArena.count)
                let tokenLength = UInt64(decodedToken.count)
                builtArena.append(contentsOf: decodedToken)

                let hash = decodedToken.withUnsafeBufferPointer { Self.fnv1a64($0) }
                var slotIndex = Int(truncatingIfNeeded: hash) & tableMask
                while builtPacked[slotIndex] != 0 {
                    slotIndex = (slotIndex + 1) & tableMask
                }
                builtPacked[slotIndex] = (tokenOffset << 16) | tokenLength
                builtRanks[slotIndex] = parsedRank
            }
        }

        self.arena = builtArena
        self.packedSlots = builtPacked
        self.ranks = builtRanks
        self.singleByteRanks = builtSingleByte
        self.twoByteASCIIRanks = builtTwoByteASCII
        self.mask = tableMask
    }

    @inline(__always)
    func withPointers<R>(_ body: (Pointers) -> R) -> R {
        arena.withUnsafeBufferPointer { arenaBuf in
            packedSlots.withUnsafeBufferPointer { packedBuf in
                ranks.withUnsafeBufferPointer { ranksBuf in
                    singleByteRanks.withUnsafeBufferPointer { singleBuf in
                        twoByteASCIIRanks.withUnsafeBufferPointer { twoBuf in
                            let ptrs = Pointers(
                                arena: arenaBuf.baseAddress!,
                                packedSlots: packedBuf.baseAddress!,
                                ranks: ranksBuf.baseAddress!,
                                singleByte: singleBuf.baseAddress!,
                                twoByteASCII: twoBuf.baseAddress!,
                                mask: mask
                            )
                            return body(ptrs)
                        }
                    }
                }
            }
        }
    }

    @inline(__always)
    static func lookupFast(
        queryBase: UnsafePointer<UInt8>,
        len: Int,
        ptrs: Pointers
    ) -> Int32? {
        if len == 1 {
            let r = ptrs.singleByte[Int(queryBase[0])]
            return r >= 0 ? r : nil
        }
        if len == 2 {
            let b0 = queryBase[0]
            let b1 = queryBase[1]
            if (b0 | b1) < 0x80 {
                let r = ptrs.twoByteASCII[(Int(b0) << 7) | Int(b1)]
                return r >= 0 ? r : nil
            }
        }
        let hash = fnv1a64(ptr: queryBase, count: len)
        return lookupRaw(queryBase: queryBase, len: len, hash: hash, ptrs: ptrs)
    }

    @inline(__always)
    static func lookupRaw(
        queryBase: UnsafePointer<UInt8>,
        len: Int,
        hash: UInt64,
        ptrs: Pointers
    ) -> Int32? {
        guard len > 0, len <= Int(UInt16.max) else {
            return nil
        }
        var slotIndex = Int(truncatingIfNeeded: hash) & ptrs.mask
        while true {
            let packed = ptrs.packedSlots[slotIndex]
            if packed == 0 {
                return nil
            }
            if Int(packed & 0xFFFF) == len,
                memcmp(ptrs.arena.advanced(by: Int(packed >> 16)), queryBase, len) == 0
            {
                return ptrs.ranks[slotIndex]
            }
            slotIndex = (slotIndex + 1) & ptrs.mask
        }
    }

    @inline(__always)
    static func fnv1a64(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64 {
        guard let base = bytes.baseAddress else { return 14_695_981_039_346_656_037 }
        return fnv1a64(ptr: base, count: bytes.count)
    }

    @inline(__always)
    static func fnv1a64(ptr: UnsafePointer<UInt8>, count: Int) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var idx = 0
        while idx < count {
            hash ^= UInt64(ptr[idx])
            hash &*= 1_099_511_628_211
            idx += 1
        }
        return hash
    }

    private static let base64DecodeTable: [Int8] = {
        var table = [Int8](repeating: -1, count: 256)
        for idx in 0..<26 {
            table[Int(UInt8(ascii: "A")) + idx] = Int8(idx)
            table[Int(UInt8(ascii: "a")) + idx] = Int8(26 + idx)
        }
        for idx in 0..<10 {
            table[Int(UInt8(ascii: "0")) + idx] = Int8(52 + idx)
        }
        table[Int(UInt8(ascii: "+"))] = 62
        table[Int(UInt8(ascii: "/"))] = 63
        table[Int(UInt8(ascii: "="))] = -2
        return table
    }()

    private static func decodeBase64(
        _ input: UnsafeBufferPointer<UInt8>,
        table: [Int8],
        into output: inout [UInt8]
    ) -> Bool {
        let len = input.count
        guard len > 0, len % 4 == 0 else { return false }
        var idx = 0
        while idx < len {
            let v0 = table[Int(input[idx])]
            let v1 = table[Int(input[idx + 1])]
            let v2 = table[Int(input[idx + 2])]
            let v3 = table[Int(input[idx + 3])]
            guard v0 >= 0, v1 >= 0, v2 != -1, v3 != -1 else { return false }

            let b0 = UInt8((Int(v0) << 2) | (Int(v1) >> 4))
            output.append(b0)

            if v2 == -2 {
                return v3 == -2 && (idx + 4 == len)
            }
            let b1 = UInt8(((Int(v1) & 0x0F) << 4) | (Int(v2) >> 2))
            output.append(b1)

            if v3 == -2 {
                return idx + 4 == len
            }
            let b2 = UInt8(((Int(v2) & 0x03) << 6) | Int(v3))
            output.append(b2)
            idx += 4
        }
        return true
    }
}

// MARK: - Bounded Multi-Byte Piece Count Cache

private final class PieceCountCache: Sendable {
    private let maxEntries: Int
    private let storage = Mutex<[UInt64: (bytes: [UInt8], count: Int)]>([:])

    init(maxEntries: Int) {
        self.maxEntries = maxEntries
    }

    func lookup(_ slice: UnsafeBufferPointer<UInt8>, hash: UInt64) -> Int? {
        guard let queryBase = slice.baseAddress else { return nil }
        let len = slice.count
        return storage.withLock { map in
            guard let entry = map[hash], entry.bytes.count == len else {
                return nil
            }
            let matches = entry.bytes.withUnsafeBufferPointer { buf in
                guard let entryBase = buf.baseAddress else { return false }
                return memcmp(entryBase, queryBase, len) == 0
            }
            return matches ? entry.count : nil
        }
    }

    func store(_ bytes: [UInt8], hash: UInt64, count: Int) {
        storage.withLock { map in
            if map.count >= maxEntries {
                map.removeAll(keepingCapacity: true)
            }
            map[hash] = (bytes, count)
        }
    }

    func clear() {
        storage.withLock { $0.removeAll(keepingCapacity: false) }
    }
}
