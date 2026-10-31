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
        guard !text.isEmpty, let regex = threadLocalRegex() else { return [] }

        var tokens: [Int] = []
        tokens.reserveCapacity(max(8, text.utf8.count / 3))

        forEachChunk(of: text) { chunk in
            encodeChunk(chunk, regex: regex, into: &tokens)
        }
        return tokens
    }

    /// Counts exact BPE tokens in `text`.
    public func count(_ text: String) -> Int {
        guard !text.isEmpty, let regex = threadLocalRegex() else { return 0 }

        var localCache: [UInt64: (bytes: [UInt8], count: Int)] = [:]
        localCache.reserveCapacity(1_024)

        var total = 0
        forEachChunk(of: text) { chunk in
            total += countChunk(chunk, regex: regex, localCache: &localCache)
        }
        return total
    }

    // MARK: - Thread-Local Compiled Regex & Chunked Pre-Tokenization

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

    private static let targetChunkUTF8Bytes = 32_768

    private func forEachChunk(of text: String, body: (String) -> Void) {
        let utf8View = text.utf8
        guard utf8View.count > Self.targetChunkUTF8Bytes * 2 else {
            body(text)
            return
        }

        var chunkStart = text.startIndex
        var cursor = chunkStart
        var bytesInChunk = 0

        while cursor < text.endIndex {
            let next = utf8View.index(after: cursor)
            let byte = utf8View[cursor]
            bytesInChunk += 1

            if bytesInChunk >= Self.targetChunkUTF8Bytes,
                byte == UInt8(ascii: "\n"),
                next < text.endIndex
            {
                let nextByte = utf8View[next]
                let isASCIIAlnum =
                    (nextByte >= UInt8(ascii: "A") && nextByte <= UInt8(ascii: "Z"))
                    || (nextByte >= UInt8(ascii: "a") && nextByte <= UInt8(ascii: "z"))
                    || (nextByte >= UInt8(ascii: "0") && nextByte <= UInt8(ascii: "9"))
                if isASCIIAlnum {
                    body(String(text[chunkStart..<next]))
                    chunkStart = next
                    bytesInChunk = 0
                }
            }
            cursor = next
        }

        if chunkStart < text.endIndex {
            body(String(text[chunkStart..<text.endIndex]))
        }
    }

    private func encodeChunk(_ chunk: String, regex: NSRegularExpression, into output: inout [Int]) {
        let nsChunk = chunk as NSString
        let utf16Len = nsChunk.length
        guard utf16Len > 0 else { return }

        var utf16Buf = [UInt16](repeating: 0, count: utf16Len)
        nsChunk.getCharacters(&utf16Buf, range: NSRange(location: 0, length: utf16Len))
        var scratchUTF8 = [UInt8](repeating: 0, count: max(64, utf16Len * 3))
        var mergeParts: [(start: Int, rank: Int32)] = []
        mergeParts.reserveCapacity(128)
        let tableMask = table.mask

        utf16Buf.withUnsafeBufferPointer { utf16Ptr in
            scratchUTF8.withUnsafeMutableBufferPointer { scratchPtr in
                table.arena.withUnsafeBufferPointer { arenaPtr in
                    table.slots.withUnsafeBufferPointer { slotsPtr in
                        guard let utf16Base = utf16Ptr.baseAddress,
                            let scratchBase = scratchPtr.baseAddress,
                            let arenaBase = arenaPtr.baseAddress,
                            let slotsBase = slotsPtr.baseAddress
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
                            let buf = UnsafeBufferPointer(start: scratchBase, count: byteLen)
                            let hash = BPERankTable.fnv1a64(ptr: scratchBase, count: byteLen)
                            if let directRank = BPERankTable.lookupRaw(
                                queryBase: scratchBase,
                                len: byteLen,
                                hash: hash,
                                arenaBase: arenaBase,
                                slotsBase: slotsBase,
                                mask: tableMask
                            ) {
                                output.append(Int(directRank))
                                return
                            }
                            Self.bytePairEncode(buf, table: table, parts: &mergeParts, into: &output)
                        }
                    }
                }
            }
        }
    }

    private func countChunk(
        _ chunk: String,
        regex: NSRegularExpression,
        localCache: inout [UInt64: (bytes: [UInt8], count: Int)]
    ) -> Int {
        let nsChunk = chunk as NSString
        let utf16Len = nsChunk.length
        guard utf16Len > 0 else { return 0 }

        var utf16Buf = [UInt16](repeating: 0, count: utf16Len)
        nsChunk.getCharacters(&utf16Buf, range: NSRange(location: 0, length: utf16Len))
        var scratchUTF8 = [UInt8](repeating: 0, count: max(64, utf16Len * 3))
        var mergeParts: [(start: Int, rank: Int32)] = []
        mergeParts.reserveCapacity(128)
        let tableMask = table.mask

        var chunkCount = 0
        utf16Buf.withUnsafeBufferPointer { utf16Ptr in
            scratchUTF8.withUnsafeMutableBufferPointer { scratchPtr in
                table.arena.withUnsafeBufferPointer { arenaPtr in
                    table.slots.withUnsafeBufferPointer { slotsPtr in
                        guard let utf16Base = utf16Ptr.baseAddress,
                            let scratchBase = scratchPtr.baseAddress,
                            let arenaBase = arenaPtr.baseAddress,
                            let slotsBase = slotsPtr.baseAddress
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
                            let hash = BPERankTable.fnv1a64(ptr: scratchBase, count: byteLen)
                            if BPERankTable.lookupRaw(
                                queryBase: scratchBase,
                                len: byteLen,
                                hash: hash,
                                arenaBase: arenaBase,
                                slotsBase: slotsBase,
                                mask: tableMask
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

                            let mergedCount = Self.bytePairCount(buf, table: table, parts: &mergeParts)
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
        table: BPERankTable,
        parts: inout [(start: Int, rank: Int32)],
        into output: inout [Int]
    ) {
        runBytePairMerge(piece, table: table, parts: &parts)
        guard let base = piece.baseAddress else { return }
        for idx in 0..<(parts.count - 1) {
            let start = parts[idx].start
            let end = parts[idx + 1].start
            let sub = UnsafeBufferPointer(start: base.advanced(by: start), count: end - start)
            if let rank = table.lookup(sub) {
                output.append(Int(rank))
            }
        }
    }

    private static func bytePairCount(
        _ piece: UnsafeBufferPointer<UInt8>,
        table: BPERankTable,
        parts: inout [(start: Int, rank: Int32)]
    ) -> Int {
        runBytePairMerge(piece, table: table, parts: &parts)
        return max(0, parts.count - 1)
    }

    private static func runBytePairMerge(
        _ piece: UnsafeBufferPointer<UInt8>,
        table: BPERankTable,
        parts: inout [(start: Int, rank: Int32)]
    ) {
        let count = piece.count
        parts.removeAll(keepingCapacity: true)
        guard count > 0, let base = piece.baseAddress else { return }

        var minRank = Int32.max
        var minIndex = 0

        for idx in 0..<(count - 1) {
            let pair = UnsafeBufferPointer(start: base.advanced(by: idx), count: 2)
            let rank = table.lookup(pair) ?? Int32.max
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
                parts[i - 1].rank = pairRank(at: i - 1, skippingNext: true, parts: parts, base: base, table: table)
            }
            parts[i].rank = pairRank(at: i, skippingNext: true, parts: parts, base: base, table: table)
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
        table: BPERankTable
    ) -> Int32 {
        let endPartIndex = skippingNext ? (index + 3) : (index + 2)
        guard endPartIndex < parts.count else {
            return Int32.max
        }
        let start = parts[index].start
        let end = parts[endPartIndex].start
        let slice = UnsafeBufferPointer(start: base.advanced(by: start), count: end - start)
        return table.lookup(slice) ?? Int32.max
    }
}

// MARK: - Flat Arena Open-Addressed Rank Table

private struct BPERankTable: Sendable {
    struct Slot: Sendable {
        var offset: UInt32
        var length: UInt16
        var occupied: Bool
        var rank: Int32
    }

    let arena: [UInt8]
    let slots: [Slot]
    let mask: Int

    init(vocabularyData: Data, capacity: Int, encodingName: String) throws {
        precondition(capacity > 0 && (capacity & (capacity - 1)) == 0)
        let decodeTable = Self.base64DecodeTable
        let tableMask = capacity - 1

        var builtArena: [UInt8] = []
        builtArena.reserveCapacity(vocabularyData.count)
        var builtSlots = [Slot](
            repeating: Slot(offset: 0, length: 0, occupied: false, rank: 0),
            count: capacity
        )

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

                let tokenOffset = UInt32(builtArena.count)
                let tokenLength = UInt16(decodedToken.count)
                builtArena.append(contentsOf: decodedToken)

                let hash = decodedToken.withUnsafeBufferPointer { Self.fnv1a64($0) }
                var slotIndex = Int(truncatingIfNeeded: hash) & tableMask
                while builtSlots[slotIndex].occupied {
                    slotIndex = (slotIndex + 1) & tableMask
                }
                builtSlots[slotIndex] = Slot(
                    offset: tokenOffset,
                    length: tokenLength,
                    occupied: true,
                    rank: parsedRank
                )
            }
        }

        self.arena = builtArena
        self.slots = builtSlots
        self.mask = tableMask
    }

    @inline(__always)
    func lookup(_ slice: UnsafeBufferPointer<UInt8>) -> Int32? {
        guard let base = slice.baseAddress else { return nil }
        return lookup(slice, precomputedHash: Self.fnv1a64(ptr: base, count: slice.count))
    }

    @inline(__always)
    func lookup(_ slice: UnsafeBufferPointer<UInt8>, precomputedHash hash: UInt64) -> Int32? {
        guard let queryBase = slice.baseAddress else { return nil }
        return arena.withUnsafeBufferPointer { arenaBuf in
            slots.withUnsafeBufferPointer { slotsBuf in
                guard let arenaBase = arenaBuf.baseAddress, let slotsBase = slotsBuf.baseAddress else {
                    return nil
                }
                return Self.lookupRaw(
                    queryBase: queryBase,
                    len: slice.count,
                    hash: hash,
                    arenaBase: arenaBase,
                    slotsBase: slotsBase,
                    mask: mask
                )
            }
        }
    }

    @inline(__always)
    static func lookupRaw(
        queryBase: UnsafePointer<UInt8>,
        len: Int,
        hash: UInt64,
        arenaBase: UnsafePointer<UInt8>,
        slotsBase: UnsafePointer<Slot>,
        mask: Int
    ) -> Int32? {
        guard len > 0, len <= Int(UInt16.max) else {
            return nil
        }
        let targetLen = UInt16(len)
        var slotIndex = Int(truncatingIfNeeded: hash) & mask
        while true {
            let slot = slotsBase[slotIndex]
            if !slot.occupied {
                return nil
            }
            if slot.length == targetLen,
                memcmp(arenaBase.advanced(by: Int(slot.offset)), queryBase, len) == 0
            {
                return slot.rank
            }
            slotIndex = (slotIndex + 1) & mask
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
}
