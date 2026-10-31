import BentoCore
import Foundation

/// User-facing privacy and security copy presented during first-run onboarding and Settings (`PLAN.md` §7).
public struct OnboardingCopy: Sendable, Equatable {
    public var title: String
    public var subtitle: String
    public var localOnlyStatement: String
    public var fullDiskAccessExplanation: String
    public var mcpProbeConsentStatement: String
    public var readOnlyDefaultStatement: String

    public static func make(productName: String = Product.name) -> OnboardingCopy {
        OnboardingCopy(
            title: "Welcome to \(productName)",
            subtitle: "Audit context token budgets, load precedence, and rules hygiene across your AI coding agents.",
            localOnlyStatement:
                "Everything runs locally on your Mac with no telemetry, no analytics, and no crash upload. "
                + "Session log decoders persist only token counts, tool/skill names, timestamps, working directories, "
                + "and model identifiers — prompt and response text is never stored. Network access is used strictly "
                + "for opt-in exact token-counting APIs (after showing a request preview of artifact text only, never logs).",
            fullDiskAccessExplanation:
                "Full Disk Access is not required. Agent configuration directories (~/.claude, ~/.codex, ~/.gemini, "
                + "~/.copilot, ~/.cursor, ~/.codeium) live in your home folder and are readable without Full Disk Access. "
                + "If you keep repositories inside macOS TCC-protected folders such as ~/Documents, ~/Desktop, or "
                + "~/Downloads, macOS may prompt for folder access or report a permission denial, which \(productName) "
                + "detects and explains in place.",
            mcpProbeConsentStatement:
                "Probing an MCP server executes third-party code or connects to a configured endpoint. \(productName) "
                + "never launches or connects to an MCP server without your explicit per-server consent (remembered by "
                + "config hash, with a scrubbed environment, 15-second timeout, and no TTY).",
            readOnlyDefaultStatement:
                "Read-only by default: \"Allow changes\" starts turned off. Every suggested fix shows its planned file "
                + "operations, backup folder, and a monospaced unified diff before applying, with one-click Undo."
        )
    }
}

/// Explanation emitted when macOS TCC blocks access to a protected folder (`~/Documents`, `~/Desktop`, `~/Downloads`).
public struct TCCDenialNotice: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public var protectedFolderName: String
    public var path: String
    public var diagnosticMessage: String
    public var explanation: String

    public init(
        protectedFolderName: String,
        path: String,
        diagnosticMessage: String,
        explanation: String
    ) {
        self.protectedFolderName = protectedFolderName
        self.path = path
        self.diagnosticMessage = diagnosticMessage
        self.explanation = explanation
    }
}

/// Detects macOS Transparency, Consent, and Control (TCC) permission denials from scan/log diagnostics (`PLAN.md` §7).
public enum TCCDenialDetector {
    private static let protectedHomeSubfolders: [String] = [
        "Documents",
        "Desktop",
        "Downloads",
        "Library/Mobile Documents"
    ]

    public static func detect(
        from diagnostics: [Diagnostic],
        homePath: String,
        productName: String = Product.name
    ) -> [TCCDenialNotice] {
        let normalizedHome = URL(fileURLWithPath: homePath).standardizedFileURL.path
        let homePrefix = normalizedHome.hasSuffix("/") ? normalizedHome : normalizedHome + "/"

        var seenPaths: Set<String> = []
        var notices: [TCCDenialNotice] = []

        for diag in diagnostics {
            guard isPermissionDiagnostic(diag) else { continue }
            guard let loc = diag.location else { continue }

            let candidatePath = URL(fileURLWithPath: loc.path).standardizedFileURL.path
            guard seenPaths.insert(candidatePath).inserted else { continue }

            let folderName = classifyProtectedFolder(path: candidatePath, homePrefix: homePrefix) ?? "Protected Folder"
            let explanation =
                "macOS blocked \(productName) from reading '\(candidatePath)' inside ~/.\(folderName == "Protected Folder" ? "" : "")"
                .replacingOccurrences(of: "~/.", with: "~/\(folderName). ")
                + "Full Disk Access is not required for standard home-directory agent configs, "
                + "but repositories stored inside macOS TCC-protected folders (~/Documents, ~/Desktop, ~/Downloads) "
                + "require granting folder access in System Settings → Privacy & Security → Files and Folders "
                + "(or Full Disk Access if running from an unprompted host terminal)."

            notices.append(
                TCCDenialNotice(
                    protectedFolderName: folderName,
                    path: candidatePath,
                    diagnosticMessage: diag.message,
                    explanation: explanation
                )
            )
        }

        return notices
    }

    private static func isPermissionDiagnostic(_ diagnostic: Diagnostic) -> Bool {
        let codeLower = diagnostic.code.lowercased()
        let messageLower = diagnostic.message.lowercased()
        let keywords = [
            "permission",
            "eperm",
            "eacces",
            "operation not permitted",
            "not permitted",
            "access denied",
            "tcc",
            "don’t have permission",
            "don't have permission"
        ]
        return keywords.contains { codeLower.contains($0) || messageLower.contains($0) }
    }

    private static func classifyProtectedFolder(path: String, homePrefix: String) -> String? {
        if path.hasPrefix(homePrefix) {
            let relative = String(path.dropFirst(homePrefix.count))
            for folder in protectedHomeSubfolders {
                if relative == folder || relative.hasPrefix(folder + "/") {
                    return folder
                }
            }
        }
        for folder in ["Documents", "Desktop", "Downloads"] {
            if path.contains("/\(folder)/") || path.hasSuffix("/\(folder)") {
                return folder
            }
        }
        return nil
    }
}
