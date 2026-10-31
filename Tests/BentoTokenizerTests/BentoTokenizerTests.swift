import BentoCore
import BentoTestSupport
import BentoTokenizer
import Foundation
import Synchronization
import Testing

struct BentoTokenizerTests {
    private struct ReferenceVector: Decodable {
        var id: Int
        var category: String
        var text: String
        var o200kBaseCount: Int
        var cl100kBaseCount: Int
        var o200kBaseTokens: [Int]
        var cl100kBaseTokens: [Int]

        enum CodingKeys: String, CodingKey {
            case id
            case category
            case text
            case o200kBaseCount = "o200k_base_count"
            case cl100kBaseCount = "cl100k_base_count"
            case o200kBaseTokens = "o200k_base_tokens"
            case cl100kBaseTokens = "cl100k_base_tokens"
        }
    }

    @Test("Bundled deflate vocabularies match Resources/tokenizers/*.tiktoken byte-for-byte")
    func bundledVocabulariesMatchCanonicalResources() throws {
        let root = FixtureHome.repositoryRoot()
        let licenseURL = root.appendingPathComponent("Resources/tokenizers/LICENSE")
        let licenseText = try String(contentsOf: licenseURL, encoding: .utf8)
        #expect(licenseText.contains("MIT License"))
        #expect(licenseText.contains("OpenAI"))

        for encoding in BPEEncoding.allCases {
            let canonicalURL = root.appendingPathComponent("Resources/tokenizers/\(encoding.rawValue).tiktoken")
            let canonicalBytes = try Data(contentsOf: canonicalURL)
            let loadedBytes = try TokenizerResourceLoader.loadVocabularyData(for: encoding)
            #expect(loadedBytes == canonicalBytes, "Mismatch for \(encoding.rawValue)")
        }
    }

    @Test("BPETokenizer achieves 100% exact token ID and count match on >= 1,000 tiktoken reference vectors")
    func bpeMatchesAllReferenceVectorsExactly() throws {
        let vectorsURL = FixtureHome.repositoryRoot()
            .appendingPathComponent("Fixtures/tokenizer/vectors.jsonl")
        let rawText = try String(contentsOf: vectorsURL, encoding: .utf8)
        let lines = rawText.split(whereSeparator: \.isNewline)
        #expect(lines.count >= 1_000, "Expected >= 1,000 reference vectors, found \(lines.count)")

        let o200k = try BPETokenizer.shared(for: .o200kBase)
        let cl100k = try BPETokenizer.shared(for: .cl100kBase)
        let decoder = JSONDecoder()

        var o200kMismatches = 0
        var cl100kMismatches = 0

        for line in lines {
            let vector = try decoder.decode(ReferenceVector.self, from: Data(line.utf8))

            let actualO200kTokens = o200k.encode(vector.text)
            let actualO200kCount = o200k.count(vector.text)
            if actualO200kTokens != vector.o200kBaseTokens || actualO200kCount != vector.o200kBaseCount {
                o200kMismatches += 1
                if o200kMismatches <= 5 {
                    let msg =
                        "o200k_base mismatch on #\(vector.id) (\(vector.category)): "
                        + "got \(actualO200kTokens), expected \(vector.o200kBaseTokens)"
                    Issue.record(Comment(rawValue: msg))
                }
            }

            let actualCl100kTokens = cl100k.encode(vector.text)
            let actualCl100kCount = cl100k.count(vector.text)
            if actualCl100kTokens != vector.cl100kBaseTokens || actualCl100kCount != vector.cl100kBaseCount {
                cl100kMismatches += 1
                if cl100kMismatches <= 5 {
                    let msg =
                        "cl100k_base mismatch on #\(vector.id) (\(vector.category)): "
                        + "got \(actualCl100kTokens), expected \(vector.cl100kBaseTokens)"
                    Issue.record(Comment(rawValue: msg))
                }
            }
        }

        #expect(o200kMismatches == 0)
        #expect(cl100kMismatches == 0)
    }

    @Test("BPETokenizer throughput exceeds 5 MB/s on a >= 5 MB realistic mixed corpus")
    func bpeThroughputExceedsFiveMegabytesPerSecond() throws {
        let vectorsURL = FixtureHome.repositoryRoot()
            .appendingPathComponent("Fixtures/tokenizer/vectors.jsonl")
        let rawLines = try String(contentsOf: vectorsURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        let decoder = JSONDecoder()

        var block = ""
        block.reserveCapacity(262_144)
        for line in rawLines.prefix(500) {
            let vector = try decoder.decode(ReferenceVector.self, from: Data(line.utf8))
            block.append(vector.text)
            block.append("\n")
        }

        let targetBytes = 5 * 1_024 * 1_024
        var corpus = ""
        corpus.reserveCapacity(targetBytes + block.utf8.count)
        while corpus.utf8.count < targetBytes {
            corpus.append(block)
        }
        let totalBytes = corpus.utf8.count
        #expect(totalBytes >= targetBytes)

        // Construct a fresh BPETokenizer instance so piece-count cache starts cold for the benchmark.
        let freshTokenizer = try BPETokenizer(encoding: .o200kBase)
        let clock = ContinuousClock()
        var tokenTotal = 0
        let elapsed = clock.measure {
            tokenTotal = freshTokenizer.count(corpus)
        }

        #expect(tokenTotal > 0)
        let seconds =
            Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000.0
        let megabytes = Double(totalBytes) / (1_024.0 * 1_024.0)
        let throughputMBps = megabytes / max(seconds, 0.000_001)
        #expect(
            throughputMBps >= 5.0,
            "Expected BPETokenizer throughput >= 5 MB/s, measured \(throughputMBps) MB/s (\(seconds)s)"
        )
    }

    @Test("HeuristicCounter stays within +-20% of BPETokenizer across the fixture corpus")
    func heuristicCounterWithinTwentyPercentOnFixtureCorpus() throws {
        let homesRoot = FixtureHome.repositoryRoot().appendingPathComponent("Fixtures/homes")
        let fm = FileManager.default
        let enumerator = fm.enumerator(at: homesRoot, includingPropertiesForKeys: [.isRegularFileKey])

        let bpeO200k = try BPETokenizer.shared(for: .o200kBase)
        let bpeCl100k = try BPETokenizer.shared(for: .cl100kBase)
        let heuristic = HeuristicCounter()

        var fileCount = 0
        var heuristicTotal = 0
        var o200kTotal = 0
        var cl100kTotal = 0

        let allowedExtensions: Set<String> = ["md", "mdc", "json", "toml", "yaml", "yml", "sql"]
        while let url = enumerator?.nextObject() as? URL {
            if url.path.contains("/hostile/") { continue }
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else {
                continue
            }
            fileCount += 1
            heuristicTotal += heuristic.count(text)
            o200kTotal += bpeO200k.count(text)
            cl100kTotal += bpeCl100k.count(text)
        }

        #expect(fileCount >= 20)
        #expect(o200kTotal > 0)
        #expect(cl100kTotal > 0)

        let o200kRelativeError = abs(Double(heuristicTotal - o200kTotal)) / Double(o200kTotal)
        let cl100kRelativeError = abs(Double(heuristicTotal - cl100kTotal)) / Double(cl100kTotal)
        #expect(
            o200kRelativeError <= 0.20,
            "Heuristic total \(heuristicTotal) vs o200k \(o200kTotal) error \(o200kRelativeError) > 0.20"
        )
        #expect(
            cl100kRelativeError <= 0.20,
            "Heuristic total \(heuristicTotal) vs cl100k \(cl100kTotal) error \(cl100kRelativeError) > 0.20"
        )

        // Separate content-kind classification checks (prose, code, JSON).
        let proseSample = "Always write tests first against isolated fixture homes before implementing adapters."
        let jsonSample = "{\"mcpServers\":{\"github\":{\"command\":\"npx\",\"args\":[\"-y\",\"@mcp/github\"]}}}"
        let codeSample = "public func evaluate(items: [Int]) -> Int { return items.reduce(0, +) }"
        #expect(heuristic.classify(proseSample) == .prose)
        #expect(heuristic.classify(jsonSample) == .json)
        #expect(heuristic.classify(codeSample) == .code)
    }

    @Test("CalibratedCounter scales counts and CachingTokenCounter deduplicates by content hash")
    func calibratedAndCachingCountersBehaveDeterministically() {
        let spy = SpyTokenCounter(id: "spy", fixedCountPerCall: 100)
        let calibrated = CalibratedCounter(base: spy, kFactor: 1.12)
        #expect(calibrated.count("sample") == 112)
        #expect(calibrated.id.contains("spy"))
        #expect(spy.invocationCount == 1)

        let cache = CachingTokenCounter()
        let hashA = ContentHasher.sha256NormalizedText("alpha rules")
        let hashB = ContentHasher.sha256NormalizedText("beta rules")

        let first = cache.count("alpha rules", contentHash: hashA, using: spy)
        let second = cache.count("alpha rules", contentHash: hashA, using: spy)
        #expect(first == 100)
        #expect(second == 100)
        #expect(spy.invocationCount == 2)

        let third = cache.count("beta rules", contentHash: hashB, using: spy)
        #expect(third == 100)
        #expect(spy.invocationCount == 3)
    }

    @Test("AgentTokenizerRegistry maps (agent, model) to exact BPE or estimated heuristic counters")
    func agentTokenizerRegistryMapsModelsAndCalibrations() throws {
        var registry = try AgentTokenizerRegistry()
        let sample = "Always preserve comments and key ordering when editing configuration files."
        let sampleHash = ContentHasher.sha256NormalizedText(sample)

        // Codex + known OpenAI models -> exact BPE
        let codexO200k = registry.estimateTokens(
            text: sample,
            contentHash: sampleHash,
            agent: .codex,
            model: "gpt-5-codex"
        )
        #expect(codexO200k.confidence == .exact)
        #expect(codexO200k.counterID == "o200k_base")
        #expect(codexO200k.range == nil)
        #expect(registry.contextWindow(for: .codex, model: "gpt-5-codex") != nil)

        let codexCl100k = registry.estimateTokens(
            text: sample,
            contentHash: sampleHash,
            agent: .codex,
            model: "gpt-4"
        )
        #expect(codexCl100k.confidence == .exact)
        #expect(codexCl100k.counterID == "cl100k_base")

        // Codex + unrecognized model -> estimated o200k_base with uncertainty range
        let codexUnknown = registry.estimateTokens(
            text: sample,
            contentHash: sampleHash,
            agent: .codex,
            model: "custom-oss-coder-32b"
        )
        #expect(codexUnknown.confidence == .estimated)
        #expect(codexUnknown.range != nil)

        // Claude Code -> estimated heuristic, 200k context window
        let claudeEst = registry.estimateTokens(
            text: sample,
            contentHash: sampleHash,
            agent: .claudeCode,
            model: "claude-sonnet-4-20250514"
        )
        #expect(claudeEst.confidence == .estimated)
        #expect(claudeEst.method.contains("heuristic"))
        #expect(claudeEst.range != nil)
        #expect(registry.contextWindow(for: .claudeCode, model: "claude-sonnet-4-20250514") == 200_000)

        // Gemini -> estimated heuristic, 1M context window
        let geminiEst = registry.estimateTokens(
            text: sample,
            contentHash: sampleHash,
            agent: .gemini,
            model: "gemini-2.5-pro"
        )
        #expect(geminiEst.confidence == .estimated)
        #expect(registry.contextWindow(for: .gemini, model: "gemini-2.5-pro") == 1_048_576)

        // Copilot -> exact for OpenAI models, estimated for Claude/default
        let copilotOpenAI = registry.estimateTokens(
            text: sample,
            contentHash: sampleHash,
            agent: .copilot,
            model: "gpt-4o"
        )
        #expect(copilotOpenAI.confidence == .exact)
        #expect(copilotOpenAI.counterID == "o200k_base")

        let copilotDefault = registry.estimateTokens(
            text: sample,
            contentHash: sampleHash,
            agent: .copilot,
            model: nil
        )
        #expect(copilotDefault.confidence == .estimated)

        // Applying a fitted calibration factor updates the estimate and method string.
        registry.setCalibrationFactor(1.10, for: .claudeCode, model: "claude-sonnet-4-20250514")
        let claudeCalibrated = registry.estimateTokens(
            text: sample,
            contentHash: sampleHash,
            agent: .claudeCode,
            model: "claude-sonnet-4-20250514"
        )
        #expect(claudeCalibrated.confidence == .estimated)
        #expect(claudeCalibrated.method.contains("calibrated k=1.10"))
        #expect(claudeCalibrated.tokens >= claudeEst.tokens)
    }
}

private final class SpyTokenCounter: TokenCounter, Sendable {
    let id: String
    private let fixedCountPerCall: Int
    private let calls = Mutex(0)

    init(id: String, fixedCountPerCall: Int) {
        self.id = id
        self.fixedCountPerCall = fixedCountPerCall
    }

    var invocationCount: Int {
        calls.withLock { $0 }
    }

    func count(_ text: String) -> Int {
        calls.withLock { $0 += 1 }
        return fixedCountPerCall
    }
}
