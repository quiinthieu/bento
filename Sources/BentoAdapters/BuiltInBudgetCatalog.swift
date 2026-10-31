import BentoCore
import Foundation

/// Errors thrown while loading built-in agent overhead catalogs (`Resources/builtins/*.json`).
public enum BuiltInBudgetCatalogError: Error, Sendable, Equatable {
    case missingResource(AgentID)
    case malformedResource(AgentID, String)
}

/// Per-model or default token overhead profile inside a `BuiltInBudgetDocument`.
public struct BuiltInBudgetProfile: Codable, Sendable, Equatable {
    /// Estimated built-in system prompt overhead in tokens.
    public var systemPromptTokens: Int
    /// Estimated built-in native tool schema overhead in tokens.
    public var builtInToolsTokens: Int
    /// Fractional uncertainty band (`±uncertaintyFraction`) applied around the point estimate.
    public var uncertaintyFraction: Double

    /// Creates a built-in overhead profile.
    public init(
        systemPromptTokens: Int,
        builtInToolsTokens: Int,
        uncertaintyFraction: Double
    ) {
        self.systemPromptTokens = systemPromptTokens
        self.builtInToolsTokens = builtInToolsTokens
        self.uncertaintyFraction = uncertaintyFraction
    }
}

/// Provenance-documented built-in overhead catalog for one budget-capable agent (`PLAN.md` §6.3, §11 T09).
public struct BuiltInBudgetDocument: Codable, Sendable, Equatable {
    /// Agent identifier matching the JSON filename (`<agent>.json`).
    public var agent: AgentID
    /// Date on which the baseline was measured (`YYYY-MM-DD`).
    public var measuredOn: String
    /// Agent CLI version used for baseline measurement.
    public var agentVersion: String
    /// Default model identifier assumed when no model override is configured.
    public var defaultModel: String
    /// Provenance note explaining how the baseline was measured.
    public var sourceNote: String
    /// Fallback token overhead profile when a specific model is not matched in `models`.
    public var defaults: BuiltInBudgetProfile
    /// Model-specific overhead profiles keyed by lowercase model identifier.
    public var models: [String: BuiltInBudgetProfile]
}

/// Thread-safe, `fatalError`-free loader for `Resources/builtins/<agent>.json` (`PLAN.md` §6.3, §10).
public enum BuiltInBudgetCatalog: Sendable {
    private final class CacheBox: Sendable {
        private let lock = NSLock()
        // Justified nonisolated(unsafe): access to `storage` is serialized by `lock`.
        nonisolated(unsafe) private var storage: [AgentID: BuiltInBudgetDocument] = [:]

        func get(_ agent: AgentID) -> BuiltInBudgetDocument? {
            lock.lock()
            defer { lock.unlock() }
            return storage[agent]
        }

        func set(_ doc: BuiltInBudgetDocument, for agent: AgentID) {
            lock.lock()
            defer { lock.unlock() }
            storage[agent] = doc
        }
    }

    private static let cache = CacheBox()

    private static var bundleNames: [String] {
        [
            "\(Product.name)_BentoAdapters.bundle",
            "BentoPackage_BentoAdapters.bundle"
        ]
    }

    /// Loads and caches the `BuiltInBudgetDocument` for `agent`.
    public static func document(for agent: AgentID) throws -> BuiltInBudgetDocument {
        if let cached = cache.get(agent) {
            return cached
        }

        let fileName = "\(agent.rawValue).json"
        for dir in candidateDirectories() {
            let candidate = dir.appendingPathComponent(fileName)
            guard FileManager.default.isReadableFile(atPath: candidate.path),
                let data = try? Data(contentsOf: candidate)
            else {
                continue
            }

            do {
                let decoded = try JSONDecoder().decode(BuiltInBudgetDocument.self, from: data)
                cache.set(decoded, for: agent)
                return decoded
            } catch {
                throw BuiltInBudgetCatalogError.malformedResource(agent, error.localizedDescription)
            }
        }

        throw BuiltInBudgetCatalogError.missingResource(agent)
    }

    /// Builds `.builtInSystem` and `.builtInTools` `BudgetItem` records for `agent` and optional `model`.
    public static func items(
        for agent: AgentID,
        displayName: String,
        model: String?
    ) -> [BudgetItem] {
        guard let doc = try? document(for: agent) else {
            return []
        }

        let profile = selectProfile(in: doc, model: model)
        let method = "estimated (built-in, measured on \(doc.measuredOn), \(doc.agentVersion))"

        return [
            makeBuiltInItem(
                category: .builtInSystem,
                label: "\(displayName) system prompt",
                tokens: profile.systemPromptTokens,
                uncertaintyFraction: profile.uncertaintyFraction,
                method: method
            ),
            makeBuiltInItem(
                category: .builtInTools,
                label: "\(displayName) built-in tools",
                tokens: profile.builtInToolsTokens,
                uncertaintyFraction: profile.uncertaintyFraction,
                method: method
            )
        ]
    }

    private static func selectProfile(in doc: BuiltInBudgetDocument, model: String?) -> BuiltInBudgetProfile {
        guard let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return doc.defaults
        }
        let lower = raw.lowercased()
        if let exact = doc.models[lower] {
            return exact
        }
        // Prefix match longest matching model key (e.g. "claude-sonnet-4-5-20250929" -> "claude-sonnet-4-5").
        let sortedKeys = doc.models.keys.sorted { $0.count > $1.count }
        for key in sortedKeys where lower.hasPrefix(key.lowercased()) {
            if let matched = doc.models[key] {
                return matched
            }
        }
        return doc.defaults
    }

    private static func makeBuiltInItem(
        category: BudgetCategory,
        label: String,
        tokens: Int,
        uncertaintyFraction: Double,
        method: String
    ) -> BudgetItem {
        let clampedTokens = max(0, tokens)
        let clampedFraction = min(max(uncertaintyFraction, 0.0), 0.95)
        let lo = max(0, Int((Double(clampedTokens) * (1.0 - clampedFraction)).rounded(.down)))
        let hi = max(lo, Int((Double(clampedTokens) * (1.0 + clampedFraction)).rounded(.up)))
        return BudgetItem(
            artifactID: nil,
            category: category,
            label: label,
            tokens: clampedTokens,
            range: lo...hi,
            confidence: .estimated,
            method: method,
            countsTowardPrePrompt: true
        )
    }

    private static func candidateDirectories() -> [URL] {
        var dirs: [URL] = []

        func appendCandidates(around baseURL: URL) {
            for bundleName in bundleNames {
                let bundleURL = baseURL.appendingPathComponent(bundleName, isDirectory: true)
                dirs.append(bundleURL.appendingPathComponent("Resources/builtins", isDirectory: true))
                dirs.append(
                    bundleURL.appendingPathComponent("Contents/Resources/Resources/builtins", isDirectory: true)
                )
                dirs.append(bundleURL.appendingPathComponent("builtins", isDirectory: true))
            }
            dirs.append(baseURL.appendingPathComponent("Resources/builtins", isDirectory: true))
            dirs.append(baseURL.appendingPathComponent("builtins", isDirectory: true))
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

        let anchorBundleDir = Bundle(for: AdaptersBundleAnchor.self).bundleURL.deletingLastPathComponent()
        appendCandidates(around: anchorBundleDir)

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        dirs.append(sourceRoot.appendingPathComponent("Sources/BentoAdapters/Resources/builtins", isDirectory: true))
        dirs.append(sourceRoot.appendingPathComponent("Resources/builtins", isDirectory: true))

        return dirs
    }
}

private final class AdaptersBundleAnchor {}
