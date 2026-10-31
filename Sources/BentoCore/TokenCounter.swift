/// Offline or API-backed token counter (`PLAN.md` §6.3).
public protocol TokenCounter: Sendable {
    /// Stable identifier of the counter (for example `"o200k_base"`, `"cl100k_base"`, or `"heuristic"`).
    var id: String { get }

    /// Counts the number of tokens represented by `text`.
    func count(_ text: String) -> Int
}
