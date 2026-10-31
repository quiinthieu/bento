/// Typed errors thrown by `BentoHygiene` (`PLAN.md` §6.5, §10).
public enum BentoHygieneError: Error, Sendable, Equatable {
    /// Bundled `Resources/hygiene/conflicts.yaml` could not be located.
    case missingConflictCatalog
    /// `conflicts.yaml` failed YAML decoding or validation.
    case malformedConflictCatalog(String)
}
