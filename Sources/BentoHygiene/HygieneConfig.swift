/// Configurable thresholds for rule duplicate detection, block-level `@import` suggestions, and token size limits (`PLAN.md` §6.5).
public struct HygieneConfig: Sendable, Codable, Equatable {
    /// Default maximum token count for a single always-on rules document before emitting a `.sizeLimit` warning.
    public static let defaultMaxAlwaysOnRuleTokens = 10_000

    /// Word count `k` per shingle used for near-duplicate detection (`PLAN.md` §6.5: 5-gram word shingles).
    public var shingleWordCount: Int
    /// Number of deterministic MinHash permutations (`PLAN.md` §6.5: 128 perms).
    public var minHashPermutations: Int
    /// Number of LSH bands dividing `minHashPermutations` (`32` bands × `4` rows = `128`).
    public var lshBands: Int
    /// Minimum exact shingle Jaccard similarity to classify two distinct rule units as `.nearDuplicate` (`0.80`).
    public var nearDuplicateJaccardThreshold: Double
    /// Minimum fraction of a rule file's units duplicated in `AGENTS.md` to suggest `@AGENTS.md` (`0.70`).
    public var blockImportOverlapThreshold: Double
    /// Optional token threshold above which an always-on rules document triggers a `.sizeLimit` finding (`nil` disables).
    public var maxAlwaysOnRuleTokens: Int?

    /// Creates a hygiene configuration.
    public init(
        shingleWordCount: Int = 5,
        minHashPermutations: Int = 128,
        lshBands: Int = 32,
        nearDuplicateJaccardThreshold: Double = 0.80,
        blockImportOverlapThreshold: Double = 0.70,
        maxAlwaysOnRuleTokens: Int? = Self.defaultMaxAlwaysOnRuleTokens
    ) {
        self.shingleWordCount = max(1, shingleWordCount)
        let perms = max(4, minHashPermutations)
        let validBands = max(1, min(lshBands, perms))
        self.minHashPermutations = perms
        self.lshBands = validBands
        self.nearDuplicateJaccardThreshold = min(max(nearDuplicateJaccardThreshold, 0.05), 1.0)
        self.blockImportOverlapThreshold = min(max(blockImportOverlapThreshold, 0.10), 1.0)
        self.maxAlwaysOnRuleTokens = maxAlwaysOnRuleTokens.map { max(1, $0) }
    }
}
