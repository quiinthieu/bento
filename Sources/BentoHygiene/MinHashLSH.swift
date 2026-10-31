import Foundation

/// Deterministic 5-gram word shingler, 128-permutation SplitMix64 MinHash generator, and LSH band index (`PLAN.md` §6.5).
public struct MinHashLSH: Sendable {
    private static let prngSeed: UInt64 = 0xBE47_0C78_4D49_4E48
    private static let fnvOffsetBasis: UInt64 = 0xCBF2_9CE4_8422_2325
    private static let fnvPrime: UInt64 = 0x0000_0100_0000_01B3

    /// Number of MinHash permutations (`128` by default).
    public let permutations: Int
    /// Number of LSH bands (`32` by default, yielding `4` rows per band).
    public let bands: Int
    /// Rows per LSH band (`permutations / bands`).
    public let rowsPerBand: Int

    private let coefficientsA: [UInt64]
    private let coefficientsB: [UInt64]

    /// Creates a deterministic MinHash + LSH indexer.
    public init(permutations: Int = 128, bands: Int = 32) {
        let clampedPerms = max(4, permutations)
        let clampedBands = max(1, min(bands, clampedPerms))
        let rows = max(1, clampedPerms / clampedBands)
        let effectivePerms = clampedBands * rows

        self.permutations = effectivePerms
        self.bands = clampedBands
        self.rowsPerBand = rows

        var state = Self.prngSeed
        var aList: [UInt64] = []
        var bList: [UInt64] = []
        aList.reserveCapacity(effectivePerms)
        bList.reserveCapacity(effectivePerms)

        for _ in 0..<effectivePerms {
            // Odd `a` ensures `a * x + b (mod 2^64)` is a bijection on UInt64.
            aList.append(Self.nextSplitMix64(&state) | 1)
            bList.append(Self.nextSplitMix64(&state))
        }
        self.coefficientsA = aList
        self.coefficientsB = bList
    }

    /// Extracts canonical word tokens from normalized rule text, stripping outer sentence punctuation.
    public static func wordTokens(_ normalizedText: String) -> [String] {
        let trimPunctuation: Set<Character> = [
            ".", ",", ";", ":", "!", "?", "\"", "'", "(", ")", "[", "]", "{", "}"
        ]
        var tokens: [String] = []
        for rawPiece in normalizedText.split(whereSeparator: \.isWhitespace) {
            var start = rawPiece.startIndex
            var end = rawPiece.endIndex
            while start < end && trimPunctuation.contains(rawPiece[start]) {
                start = rawPiece.index(after: start)
            }
            while end > start && trimPunctuation.contains(rawPiece[rawPiece.index(before: end)]) {
                end = rawPiece.index(before: end)
            }
            if start < end {
                tokens.append(String(rawPiece[start..<end]))
            }
        }
        return tokens
    }

    /// Computes deterministic 64-bit word-shingle hashes (`k = 5` words by default).
    public static func shingles(for normalizedText: String, wordCount: Int = 5) -> Set<UInt64> {
        let words = wordTokens(normalizedText)
        guard !words.isEmpty else { return [] }
        let k = max(1, min(wordCount, words.count))
        let count = words.count - k + 1
        var result = Set<UInt64>(minimumCapacity: count)
        for idx in 0..<count {
            let gram = words[idx..<(idx + k)].joined(separator: " ")
            result.insert(hashString64(gram))
        }
        return result
    }

    /// Computes exact Jaccard similarity `|A ∩ B| / |A ∪ B|` between two shingle sets.
    public static func jaccard(_ lhs: Set<UInt64>, _ rhs: Set<UInt64>) -> Double {
        if lhs.isEmpty && rhs.isEmpty {
            return 1.0
        }
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return 0.0
        }
        let (smaller, larger) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
        var intersectionCount = 0
        for item in smaller where larger.contains(item) {
            intersectionCount += 1
        }
        let unionCount = lhs.count + rhs.count - intersectionCount
        guard unionCount > 0 else { return 0.0 }
        return Double(intersectionCount) / Double(unionCount)
    }

    /// Computes a deterministic `permutations`-element MinHash signature for `shingles`.
    public func signature(for shingles: Set<UInt64>) -> [UInt64] {
        guard !shingles.isEmpty else {
            return Array(repeating: UInt64.max, count: permutations)
        }
        var mins = Array(repeating: UInt64.max, count: permutations)
        for shingle in shingles {
            for idx in 0..<permutations {
                let linear = (coefficientsA[idx] &* shingle) &+ coefficientsB[idx]
                let permuted = Self.avalanche64(linear)
                if permuted < mins[idx] {
                    mins[idx] = permuted
                }
            }
        }
        return mins
    }

    /// Indexes `signatures` across LSH bands and returns sorted unique `(lhsIndex, rhsIndex)` candidate pairs (`lhsIndex < rhsIndex`).
    public func candidatePairs(for signatures: [[UInt64]]) -> [(Int, Int)] {
        guard signatures.count >= 2 else { return [] }

        struct PairKey: Hashable, Comparable {
            var first: Int
            var second: Int

            static func < (lhs: PairKey, rhs: PairKey) -> Bool {
                if lhs.first != rhs.first {
                    return lhs.first < rhs.first
                }
                return lhs.second < rhs.second
            }
        }

        var pairs: Set<PairKey> = []

        for band in 0..<bands {
            let rowStart = band * rowsPerBand
            let rowEnd = rowStart + rowsPerBand
            var buckets: [UInt64: [Int]] = [:]

            for (docIndex, sig) in signatures.enumerated() where sig.count >= rowEnd {
                var bandHash = Self.fnvOffsetBasis ^ UInt64(band)
                var hasValidValue = false
                for row in rowStart..<rowEnd {
                    let val = sig[row]
                    if val != UInt64.max {
                        hasValidValue = true
                    }
                    bandHash = Self.mixHash(bandHash, val)
                }
                guard hasValidValue else { continue }
                buckets[bandHash, default: []].append(docIndex)
            }

            for indices in buckets.values where indices.count >= 2 {
                for i in 0..<(indices.count - 1) {
                    for j in (i + 1)..<indices.count {
                        let a = min(indices[i], indices[j])
                        let b = max(indices[i], indices[j])
                        pairs.insert(PairKey(first: a, second: b))
                    }
                }
            }
        }

        return pairs.sorted().map { ($0.first, $0.second) }
    }

    // MARK: - Deterministic 64-Bit Hashing Helpers

    static func hashString64(_ text: String) -> UInt64 {
        var hash = fnvOffsetBasis
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= fnvPrime
        }
        return avalanche64(hash)
    }

    private static func mixHash(_ acc: UInt64, _ value: UInt64) -> UInt64 {
        var h = acc ^ avalanche64(value)
        h &*= fnvPrime
        return avalanche64(h)
    }

    private static func nextSplitMix64(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return avalanche64(state)
    }

    private static func avalanche64(_ x: UInt64) -> UInt64 {
        var z = x
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
