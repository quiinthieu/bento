/// Supported OpenAI `tiktoken` byte-level BPE encodings (`PLAN.md` §6.3).
public enum BPEEncoding: String, Sendable, Codable, CaseIterable {
    /// `o200k_base` (200k vocabulary used by `gpt-5*`, `gpt-4o*`, `gpt-4.1*`, `o1*`, `o3*`, `o4*`, `codex*`).
    case o200kBase = "o200k_base"
    /// `cl100k_base` (100k vocabulary used by `gpt-4`, `gpt-4-turbo`, `gpt-3.5-turbo`).
    case cl100kBase = "cl100k_base"

    /// ICU-compatible pre-tokenization pattern matching `openai/tiktoken` (`tiktoken_ext/openai_public.py`).
    var preTokenizationPattern: String {
        switch self {
        case .cl100kBase:
            return
                #"'(?i:[sdmt]|ll|ve|re)|[^\r\n\p{L}\p{N}]?+\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]++[\r\n]*|\s*[\r\n]|\s+(?!\S)|\s+"#
        case .o200kBase:
            return
                #"[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]*[\p{Ll}\p{Lm}\p{Lo}\p{M}]+(?i:'s|'t|'re|'ve|'m|'ll|'d)?|[^\r\n\p{L}\p{N}]?[\p{Lu}\p{Lt}\p{Lm}\p{Lo}\p{M}]+[\p{Ll}\p{Lm}\p{Lo}\p{M}]*(?i:'s|'t|'re|'ve|'m|'ll|'d)?|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n/]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
        }
    }

    /// Power-of-two hash table capacity sized for `< 0.45` load factor.
    var hashTableCapacity: Int {
        switch self {
        case .cl100kBase:
            return 262_144
        case .o200kBase:
            return 524_288
        }
    }
}
