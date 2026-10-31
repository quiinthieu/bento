import BentoCore
import Foundation
import Yams

/// Classification of deterministic opposing-directive rules in `Resources/hygiene/conflicts.yaml`.
public enum ConflictRuleKind: String, Sendable, Codable, Equatable {
    case exclusiveChoice = "exclusive_choice"
    case polarityOpposition = "polarity_opposition"
    case numericValue = "numeric_value"
}

/// One mutually exclusive choice bucket within an `exclusive_choice` conflict rule.
public struct ConflictChoiceDefinition: Sendable, Codable, Equatable {
    /// Human-readable label for this choice (e.g. `"tabs"`, `"pnpm"`, `"Vitest"`).
    public var label: String
    /// Lowercase phrase or word terms identifying this choice.
    public var terms: [String]

    /// Creates a conflict choice definition.
    public init(label: String, terms: [String]) {
        self.label = label
        self.terms = terms
    }
}

/// Single deterministic conflict rule in `Resources/hygiene/conflicts.yaml` (`PLAN.md` §6.5).
public struct ConflictRuleDefinition: Sendable, Codable, Equatable {
    /// Stable rule identifier (e.g. `"indentation-style"`, `"js-package-manager"`).
    public var id: String
    /// Human-readable topic name used in `Finding.message`.
    public var topic: String
    /// Matching archetype.
    public var kind: ConflictRuleKind
    /// Optional subject terms at least one of which must appear in the rule unit.
    public var subjectTerms: [String]?
    /// Mutually exclusive choices for `.exclusiveChoice` rules.
    public var choices: [ConflictChoiceDefinition]?
    /// Affirmative directive phrases for `.polarityOpposition` rules.
    public var positivePhrases: [String]?
    /// Prohibitive directive phrases for `.polarityOpposition` rules.
    public var negativePhrases: [String]?
    /// Exception qualifiers that narrow the subject (e.g. `"secrets"` on `git-commit`) and suppress false conflicts.
    public var exceptionTerms: [String]?
    /// Optional unit label for `.numericValue` rules (e.g. `"columns"`, `"spaces"`, `"major"`).
    public var unit: String?
    /// Regular expression patterns with capture group 1 extracting a canonical numeric/version token.
    public var patterns: [String]?

    /// Creates a conflict rule definition.
    public init(
        id: String,
        topic: String,
        kind: ConflictRuleKind,
        subjectTerms: [String]? = nil,
        choices: [ConflictChoiceDefinition]? = nil,
        positivePhrases: [String]? = nil,
        negativePhrases: [String]? = nil,
        exceptionTerms: [String]? = nil,
        unit: String? = nil,
        patterns: [String]? = nil
    ) {
        self.id = id
        self.topic = topic
        self.kind = kind
        self.subjectTerms = subjectTerms
        self.choices = choices
        self.positivePhrases = positivePhrases
        self.negativePhrases = negativePhrases
        self.exceptionTerms = exceptionTerms
        self.unit = unit
        self.patterns = patterns
    }
}

/// Decoded `Resources/hygiene/conflicts.yaml` pattern library (`PLAN.md` §6.5, §11 T13).
public struct ConflictCatalogDocument: Sendable, Codable, Equatable {
    /// Schema version (`1`).
    public var schemaVersion: Int
    /// Ordered conflict rules.
    public var rules: [ConflictRuleDefinition]

    /// Creates a conflict catalog document.
    public init(schemaVersion: Int = 1, rules: [ConflictRuleDefinition]) {
        self.schemaVersion = schemaVersion
        self.rules = rules
    }
}

/// Thread-safe, `fatalError`-free loader for `Resources/hygiene/conflicts.yaml`.
public enum ConflictCatalog: Sendable {
    private final class CacheBox: Sendable {
        private let lock = NSLock()
        // Justified nonisolated(unsafe): access to `cached` is serialized by `lock`.
        nonisolated(unsafe) private var cached: ConflictCatalogDocument?

        func get() -> ConflictCatalogDocument? {
            lock.lock()
            defer { lock.unlock() }
            return cached
        }

        func set(_ document: ConflictCatalogDocument) {
            lock.lock()
            defer { lock.unlock() }
            cached = document
        }
    }

    private static let cache = CacheBox()

    private static var bundleNames: [String] {
        [
            "\(Product.name)_BentoHygiene.bundle",
            "BentoPackage_BentoHygiene.bundle"
        ]
    }

    /// Loads and caches the bundled `Resources/hygiene/conflicts.yaml` pattern library.
    public static func loadDefault() throws -> ConflictCatalogDocument {
        if let existing = cache.get() {
            return existing
        }

        for dir in candidateDirectories() {
            let candidate = dir.appendingPathComponent("conflicts.yaml")
            guard FileManager.default.isReadableFile(atPath: candidate.path),
                let data = try? Data(contentsOf: candidate),
                let yamlText = String(data: data, encoding: .utf8)
            else {
                continue
            }

            let decoded = try load(from: yamlText)
            cache.set(decoded)
            return decoded
        }

        throw BentoHygieneError.missingConflictCatalog
    }

    /// Parses and validates a `ConflictCatalogDocument` from a YAML string.
    public static func load(from yamlString: String) throws -> ConflictCatalogDocument {
        let document: ConflictCatalogDocument
        do {
            document = try YAMLDecoder().decode(ConflictCatalogDocument.self, from: yamlString)
        } catch {
            throw BentoHygieneError.malformedConflictCatalog(error.localizedDescription)
        }

        guard !document.rules.isEmpty else {
            throw BentoHygieneError.malformedConflictCatalog("Conflict catalog contains zero rules.")
        }

        for rule in document.rules {
            switch rule.kind {
            case .exclusiveChoice:
                guard let choices = rule.choices, choices.count >= 2 else {
                    throw BentoHygieneError.malformedConflictCatalog(
                        "Exclusive choice rule '\(rule.id)' must define at least 2 choices."
                    )
                }
            case .polarityOpposition:
                guard let pos = rule.positivePhrases, !pos.isEmpty,
                    let neg = rule.negativePhrases, !neg.isEmpty
                else {
                    throw BentoHygieneError.malformedConflictCatalog(
                        "Polarity rule '\(rule.id)' must define non-empty positivePhrases and negativePhrases."
                    )
                }
            case .numericValue:
                guard let patterns = rule.patterns, !patterns.isEmpty else {
                    throw BentoHygieneError.malformedConflictCatalog(
                        "Numeric rule '\(rule.id)' must define at least 1 regex pattern."
                    )
                }
                for pattern in patterns {
                    if (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])) == nil {
                        throw BentoHygieneError.malformedConflictCatalog(
                            "Numeric rule '\(rule.id)' has invalid regex pattern '\(pattern)'."
                        )
                    }
                }
            }
        }

        return document
    }

    private static func candidateDirectories() -> [URL] {
        var dirs: [URL] = []

        func appendCandidates(around baseURL: URL) {
            for bundleName in bundleNames {
                let bundleURL = baseURL.appendingPathComponent(bundleName, isDirectory: true)
                dirs.append(bundleURL.appendingPathComponent("Resources/hygiene", isDirectory: true))
                dirs.append(
                    bundleURL.appendingPathComponent("Contents/Resources/Resources/hygiene", isDirectory: true)
                )
                dirs.append(bundleURL.appendingPathComponent("hygiene", isDirectory: true))
            }
            dirs.append(baseURL.appendingPathComponent("Resources/hygiene", isDirectory: true))
            dirs.append(baseURL.appendingPathComponent("hygiene", isDirectory: true))
        }

        if let mainRes = Bundle.main.resourceURL {
            appendCandidates(around: mainRes)
        }
        appendCandidates(around: Bundle.main.bundleURL)

        let executableDir = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        appendCandidates(around: executableDir)
        appendCandidates(
            around: executableDir.deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
        )

        let anchorBundleDir = Bundle(for: HygieneBundleAnchor.self).bundleURL.deletingLastPathComponent()
        appendCandidates(around: anchorBundleDir)

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        dirs.append(sourceRoot.appendingPathComponent("Sources/BentoHygiene/Resources/hygiene", isDirectory: true))
        dirs.append(sourceRoot.appendingPathComponent("Resources/hygiene", isDirectory: true))

        return dirs
    }
}

private final class HygieneBundleAnchor {}
