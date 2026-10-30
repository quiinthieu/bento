import Foundation
import Testing

struct LintWritesTests {
    @Test("Scripts/lint-writes.sh passes on repository Sources")
    func lintWritesPassesOnRepo() throws {
        let script = Self.repositoryRoot().appendingPathComponent("Scripts/lint-writes.sh")
        let result = try Self.runScript(at: script)
        #expect(result.exitCode == 0, "Expected lint-writes.sh to pass, got: \(result.output)")
    }

    @Test("Scripts/test-lint-writes.sh verifies failure on Data.write in Core")
    func lintWritesSelfTestPasses() throws {
        let script = Self.repositoryRoot().appendingPathComponent("Scripts/test-lint-writes.sh")
        let result = try Self.runScript(at: script)
        #expect(result.exitCode == 0, "Expected test-lint-writes.sh to pass, got: \(result.output)")
    }

    private static func runScript(at url: URL) throws -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [url.path]
        process.currentDirectoryURL = repositoryRoot()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
