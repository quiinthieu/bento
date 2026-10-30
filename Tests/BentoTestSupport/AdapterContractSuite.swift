import BentoCore
import CryptoKit
import Darwin
import Foundation

/// Contract failure reported by `AdapterContractSuite`.
public struct AdapterContractViolation: Error, Sendable, Equatable, CustomStringConvertible {
    /// Human-readable description of the violated adapter contract rule.
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String {
        message
    }
}

/// Shared contract verification runner executed against every `AgentAdapter` implementation (PLAN §5.1).
/// Verifies `PathCatalog` provenance, empty-home detection, hermetic `ReadOnlyFileSystem` containment,
/// read-only execution on `chmod -R a-w` trees, determinism, location-independent `ArtifactID` stability,
/// and resolution structural invariants.
public enum AdapterContractSuite {
    /// Runs the full adapter contract suite against `adapter` using `fixtureScenario` and relative `repoRelativePath`.
    public static func verify<A: AgentAdapter>(
        adapter: A,
        fixtureScenario: String,
        repoRelativePath: String,
        corruptConfigRelativePath: String? = nil
    ) async throws {
        try verifyPathCatalog(of: adapter)
        try await verifyEmptyHome(adapter: adapter)

        let fixture = try FixtureHome(scenario: fixtureScenario)
        let recordingFS = RecordingReadOnlyFileSystem()
        let env = fixture.makeEnvironment(fileSystem: recordingFS)
        let folder = fixture.url.appendingPathComponent(repoRelativePath, isDirectory: true).standardizedFileURL

        let detection = await adapter.detect(in: env)
        guard detection.isDetected else {
            throw AdapterContractViolation(
                "\(adapter.displayName) failed to detect configured fixture '\(fixtureScenario)'"
            )
        }
        guard !detection.detectedPaths.isEmpty else {
            throw AdapterContractViolation(
                "\(adapter.displayName) returned isDetected=true with empty detectedPaths"
            )
        }

        let firstArtifacts = try await adapter.discover(in: env, folder: folder)
        guard !firstArtifacts.isEmpty else {
            throw AdapterContractViolation(
                "\(adapter.displayName) discovered zero artifacts in '\(fixtureScenario)'"
            )
        }

        let secondArtifacts = try await adapter.discover(in: env, folder: folder)
        guard firstArtifacts == secondArtifacts else {
            throw AdapterContractViolation(
                "\(adapter.displayName) discover() is non-deterministic across repeated invocations"
            )
        }

        let firstResolution = adapter.resolve(firstArtifacts, folder: folder, env: env)
        let secondResolution = adapter.resolve(secondArtifacts, folder: folder, env: env)
        guard firstResolution == secondResolution else {
            throw AdapterContractViolation(
                "\(adapter.displayName) resolve() is non-deterministic across repeated invocations"
            )
        }

        _ = try adapter.logSources(in: env)

        try verifyFilesystemContainment(
            accessedPaths: recordingFS.accessedPaths,
            allowedRoot: fixture.url,
            adapterName: adapter.displayName
        )
        try verifyArtifactInvariants(firstArtifacts, expectedAgent: A.id)
        try verifyResolutionInvariants(firstResolution, discovered: firstArtifacts, expectedAgent: A.id)

        try await verifyReadOnlyAndPortableIDs(
            adapter: adapter,
            fixture: fixture,
            repoRelativePath: repoRelativePath,
            expectedArtifactIDs: firstArtifacts.map(\.id),
            expectedOrderedIDs: firstResolution.ordered.map(\.artifactID),
            expectedShadowedPairs: firstResolution.shadowed.map {
                "\($0.shadowedArtifactID.rawValue)->\($0.winningArtifactID.rawValue)"
            }
        )

        if let corruptConfigRelativePath {
            try await verifyMalformedConfigTolerance(
                adapter: adapter,
                fixture: fixture,
                repoRelativePath: repoRelativePath,
                corruptConfigRelativePath: corruptConfigRelativePath
            )
        }
    }

    /// Verifies that every `PathCatalog.Entry` carries unique IDs and verified documentation provenance.
    public static func verifyPathCatalog<A: AgentAdapter>(of adapter: A) throws {
        let entries = adapter.paths.entries
        guard !entries.isEmpty else {
            throw AdapterContractViolation("\(adapter.displayName) PathCatalog must not be empty")
        }

        var seenIDs: Set<String> = []
        for entry in entries {
            if entry.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AdapterContractViolation("\(adapter.displayName) PathCatalog contains an empty entry.id")
            }
            if !seenIDs.insert(entry.id).inserted {
                throw AdapterContractViolation(
                    "\(adapter.displayName) PathCatalog contains duplicate entry.id '\(entry.id)'"
                )
            }
            if entry.pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AdapterContractViolation(
                    "\(adapter.displayName) PathCatalog entry '\(entry.id)' has an empty pattern"
                )
            }
            guard let verifiedAt = entry.verifiedAt, isISODate(verifiedAt) else {
                throw AdapterContractViolation(
                    "\(adapter.displayName) PathCatalog entry '\(entry.id)' lacks valid YYYY-MM-DD verifiedAt"
                )
            }
            guard let docURL = entry.docURL, docURL.hasPrefix("https://") else {
                throw AdapterContractViolation(
                    "\(adapter.displayName) PathCatalog entry '\(entry.id)' lacks https:// docURL"
                )
            }
        }
    }

    private static func verifyEmptyHome<A: AgentAdapter>(adapter: A) async throws {
        let emptyFixture = try FixtureHome(scenario: "empty")
        let recordingFS = RecordingReadOnlyFileSystem()
        let emptyEnv = emptyFixture.makeEnvironment(fileSystem: recordingFS)

        let detection = await adapter.detect(in: emptyEnv)
        if detection.isDetected {
            throw AdapterContractViolation("\(adapter.displayName) falsely detected agent in empty fixture home")
        }

        let discovered = try await adapter.discover(in: emptyEnv, folder: emptyFixture.url)
        if !discovered.isEmpty {
            throw AdapterContractViolation("\(adapter.displayName) discovered artifacts in empty fixture home")
        }

        try verifyFilesystemContainment(
            accessedPaths: recordingFS.accessedPaths,
            allowedRoot: emptyFixture.url,
            adapterName: adapter.displayName
        )
    }

    private static func verifyFilesystemContainment(
        accessedPaths: [String],
        allowedRoot: URL,
        adapterName: String
    ) throws {
        guard !accessedPaths.isEmpty else {
            throw AdapterContractViolation("\(adapterName) did not route filesystem reads through env.fileSystem")
        }

        let rawRoot = allowedRoot.standardizedFileURL.path
        let resolvedRoot = allowedRoot.resolvingSymlinksInPath().standardizedFileURL.path

        for path in accessedPaths {
            let inRaw = path == rawRoot || path.hasPrefix(rawRoot + "/")
            let inResolved = path == resolvedRoot || path.hasPrefix(resolvedRoot + "/")
            if !inRaw && !inResolved {
                throw AdapterContractViolation(
                    "\(adapterName) accessed path '\(path)' outside fixture root '\(rawRoot)'"
                )
            }
        }
    }

    private static func verifyArtifactInvariants(_ artifacts: [Artifact], expectedAgent: AgentID) throws {
        var seenIDs: Set<ArtifactID> = []
        for artifact in artifacts {
            if artifact.agent != expectedAgent {
                throw AdapterContractViolation(
                    "Artifact '\(artifact.name)' reported wrong agent '\(artifact.agent)'"
                )
            }
            let rawID = artifact.id.rawValue
            let validHex = rawID.count == 64 && rawID.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            if !validHex {
                throw AdapterContractViolation(
                    "Artifact '\(artifact.name)' has non-SHA256 hex ArtifactID '\(rawID)'"
                )
            }
            if !seenIDs.insert(artifact.id).inserted {
                throw AdapterContractViolation(
                    "Duplicate ArtifactID '\(rawID)' emitted for '\(artifact.name)'"
                )
            }
            if artifact.contentHash.count != 64 {
                throw AdapterContractViolation(
                    "Artifact '\(artifact.name)' has invalid contentHash '\(artifact.contentHash)'"
                )
            }
        }
    }

    private static func verifyResolutionInvariants(
        _ resolution: Resolution,
        discovered: [Artifact],
        expectedAgent: AgentID
    ) throws {
        if resolution.agent != expectedAgent {
            throw AdapterContractViolation("Resolution reported wrong agent '\(resolution.agent)'")
        }

        let knownIDs = Set(discovered.map(\.id))
        var orderedIDs: Set<ArtifactID> = []

        for item in resolution.ordered {
            if !knownIDs.contains(item.artifactID) {
                throw AdapterContractViolation(
                    "Resolution.ordered references unknown ArtifactID '\(item.artifactID)'"
                )
            }
            if !orderedIDs.insert(item.artifactID).inserted {
                throw AdapterContractViolation(
                    "Resolution.ordered contains duplicate ArtifactID '\(item.artifactID)'"
                )
            }
            if item.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AdapterContractViolation(
                    "Resolution.ordered entry '\(item.artifactID)' has an empty reason"
                )
            }
        }

        for shadow in resolution.shadowed {
            if !knownIDs.contains(shadow.shadowedArtifactID) {
                throw AdapterContractViolation(
                    "ShadowRecord references unknown shadowedArtifactID '\(shadow.shadowedArtifactID)'"
                )
            }
            if !knownIDs.contains(shadow.winningArtifactID) {
                throw AdapterContractViolation(
                    "ShadowRecord references unknown winningArtifactID '\(shadow.winningArtifactID)'"
                )
            }
            if orderedIDs.contains(shadow.shadowedArtifactID) {
                throw AdapterContractViolation(
                    "Shadowed ArtifactID '\(shadow.shadowedArtifactID)' must not also appear in Resolution.ordered"
                )
            }
            if shadow.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw AdapterContractViolation(
                    "ShadowRecord for '\(shadow.shadowedArtifactID)' has an empty reason"
                )
            }
        }
    }

    private static func verifyReadOnlyAndPortableIDs<A: AgentAdapter>(
        adapter: A,
        fixture: FixtureHome,
        repoRelativePath: String,
        expectedArtifactIDs: [ArtifactID],
        expectedOrderedIDs: [ArtifactID],
        expectedShadowedPairs: [String]
    ) async throws {
        let tempCopy = try fixture.copyToTemporaryDirectory()
        defer {
            setWritablePermissionsRecursively(at: tempCopy, writable: true)
            try? FileManager.default.removeItem(at: tempCopy)
        }

        let beforeDigest = try computeTreeDigest(at: tempCopy)
        setWritablePermissionsRecursively(at: tempCopy, writable: false)

        let tempEnv = AgentEnvironment(
            home: tempCopy,
            env: ["BENTO_SYSTEM_ROOT": tempCopy.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { FixtureHome.defaultTimestamp }
        )
        let tempFolder = tempCopy.appendingPathComponent(repoRelativePath, isDirectory: true).standardizedFileURL

        _ = await adapter.detect(in: tempEnv)
        let copiedArtifacts = try await adapter.discover(in: tempEnv, folder: tempFolder)
        let copiedResolution = adapter.resolve(copiedArtifacts, folder: tempFolder, env: tempEnv)
        _ = try adapter.logSources(in: tempEnv)

        setWritablePermissionsRecursively(at: tempCopy, writable: true)
        let afterDigest = try computeTreeDigest(at: tempCopy)

        guard beforeDigest == afterDigest else {
            throw AdapterContractViolation("\(adapter.displayName) mutated files inside read-only fixture copy")
        }

        guard copiedArtifacts.map(\.id) == expectedArtifactIDs else {
            throw AdapterContractViolation(
                "\(adapter.displayName) ArtifactIDs changed when fixture moved to another directory"
            )
        }

        guard copiedResolution.ordered.map(\.artifactID) == expectedOrderedIDs else {
            throw AdapterContractViolation(
                "\(adapter.displayName) Resolution.ordered ArtifactIDs changed when fixture moved"
            )
        }

        let actualShadowedPairs = copiedResolution.shadowed.map {
            "\($0.shadowedArtifactID.rawValue)->\($0.winningArtifactID.rawValue)"
        }
        guard actualShadowedPairs == expectedShadowedPairs else {
            throw AdapterContractViolation(
                "\(adapter.displayName) Resolution.shadowed ArtifactIDs changed when fixture moved"
            )
        }
    }

    private static func verifyMalformedConfigTolerance<A: AgentAdapter>(
        adapter: A,
        fixture: FixtureHome,
        repoRelativePath: String,
        corruptConfigRelativePath: String
    ) async throws {
        let tempCopy = try fixture.copyToTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempCopy) }

        let targetFile = tempCopy.appendingPathComponent(corruptConfigRelativePath)
        try Data("{ invalid-config ::: [".utf8).write(to: targetFile, options: [.atomic])

        let tempEnv = AgentEnvironment(
            home: tempCopy,
            env: ["BENTO_SYSTEM_ROOT": tempCopy.path],
            fileSystem: LocalReadOnlyFileSystem(),
            now: { FixtureHome.defaultTimestamp }
        )
        let tempFolder = tempCopy.appendingPathComponent(repoRelativePath, isDirectory: true).standardizedFileURL

        let artifacts = try await adapter.discover(in: tempEnv, folder: tempFolder)
        _ = adapter.resolve(artifacts, folder: tempFolder, env: tempEnv)

        let hasDiagnostic = artifacts.contains { !$0.diagnostics.isEmpty }
        if !hasDiagnostic {
            throw AdapterContractViolation(
                "\(adapter.displayName) failed to attach a Diagnostic when '\(corruptConfigRelativePath)' was corrupted"
            )
        }
    }

    private static func setWritablePermissionsRecursively(at root: URL, writable: Bool) {
        var paths: [String] = []
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for case let itemURL as URL in enumerator {
                paths.append(itemURL.path)
            }
        }
        paths.append(root.path)

        // When removing write bits, process deepest children before parent directories;
        // when restoring write bits, process parent directories before children.
        let ordered = writable ? paths.sorted() : paths.sorted().reversed()
        for path in ordered {
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            if (st.st_mode & S_IFMT) == S_IFLNK { continue }
            let newMode: mode_t = writable ? (st.st_mode | S_IWUSR) : (st.st_mode & ~mode_t(0o222))
            _ = chmod(path, newMode)
        }
    }

    private static func computeTreeDigest(at root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        var hasher = SHA256()
        var entries: [URL] = []

        if let enumerator = FileManager.default.enumerator(
            at: root.standardizedFileURL,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for case let url as URL in enumerator {
                entries.append(url.standardizedFileURL)
            }
        }

        for url in entries.sorted(by: { $0.path < $1.path }) {
            let rel = String(url.path.dropFirst(rootPath.count))
            hasher.update(data: Data(rel.utf8))
            var st = stat()
            if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
                let bytes = try Data(contentsOf: url)
                hasher.update(data: bytes)
            }
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isISODate(_ value: String) -> Bool {
        let parts = value.split(separator: "-")
        guard parts.count == 3,
            parts[0].count == 4,
            parts[1].count == 2,
            parts[2].count == 2
        else {
            return false
        }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}
