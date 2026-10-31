/// Errors thrown when loading or initializing tokenizers (`PLAN.md` §6.3, §10).
public enum BentoTokenizerError: Error, Sendable, Equatable {
    /// Bundled vocabulary resource could not be located for `encoding`.
    case missingVocabularyResource(String)
    /// Compressed vocabulary resource failed deflate decompression.
    case vocabularyDecompressionFailed(String)
    /// Vocabulary line had invalid `<base64> <rank>` formatting.
    case malformedVocabularyEntry(encoding: String, line: Int)
    /// Pre-tokenization regular expression failed to compile.
    case invalidPreTokenizationPattern(String)
}
