# Bento

**Bento** is a native macOS 15+ application (Swift 6, SwiftUI, Swift Charts) and companion CLI (`bentoctx`) that audit context token budgets, session usage, and rules hygiene across AI coding agents.

For any repository on your Mac, Bento answers three questions:
1. **What configuration does each agent load here, and in what precedence?**
2. **How many tokens does that cost before you type your first message?**
3. **Which skills, MCP servers, and rules do you actually use—and what can you safely trim?**

---

## Supported Agents

| Agent | Inventory & Precedence | Context Token Budget | Session Log Usage & Calibration | Rules Hygiene | Reversible Fixes |
|---|:---:|:---:|:---:|:---:|:---:|
| **Claude Code** | Yes | Yes | Yes | Yes | Yes |
| **OpenAI Codex CLI** | Yes | Yes | Yes | Yes | Yes |
| **Google Gemini CLI** | Yes | Yes | Yes | Yes | Yes |
| **GitHub Copilot CLI** | Yes | Yes | Yes | Yes | MCP disable/enable |
| **Cursor** | Yes (scoped) | — | — | Yes | — |
| **Windsurf** | Yes (scoped) | — | — | Yes (incl. 6k/12k caps) | — |

Verified configuration paths, precedence rules, and documentation links for each agent are recorded in [`Docs/adapters/`](./Docs/adapters/).

---

## Key Capabilities

- **Precedence-Resolved Inventory:** Discovers managed, global, project, project-local, and nested directory rules (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.cursor/rules/*.mdc`, `.windsurfrules`, `.github/copilot-instructions.md`), `@import` chains, skills, MCP servers, subagents, slash commands, hooks, and plugins—explaining exactly why shadowed items were overridden.
- **Pre-Prompt Context Token Budget:** Computes per-agent stacked token breakdowns (`exact` BPE `o200k_base`/`cl100k_base` or opt-in provider count APIs, `estimated` calibrated heuristics, and `measured` first-turn session medians), separating always-loaded frontmatter/descriptions from deferred skill bodies and tool-search MCP schemas.
- **Local Session Usage & Calibration:** Streams plain `.jsonl` and Zstandard `.jsonl.zst` session logs incrementally to rank `"Cost × Unused"` artifacts (e.g. an MCP server costing ~4,000 tokens/session with 0 calls in 30 days) and fit per-model calibration factors.
- **Rules Hygiene Engine:** Detects exact and MinHash-LSH near-duplicate rules across agent files, flags opposing directives (`Resources/hygiene/conflicts.yaml`), verifies `@import` targets, and checks Windsurf 6,000/12,000-character and Codex `project_doc_max_bytes` truncation limits.
- **Safe, Reversible Fixes (Read-Only by Default):** Previews coloured unified diffs, creates SHA-256 verified backups, applies minimal comment-preserving JSONC/TOML edits or skill-consolidation symlinks, verifies post-apply state with automatic rollback, moves removed items to the macOS Trash, and supports one-click **Undo**.

---

## Installation

### Option 1: Download Universal DMG (Apple Silicon & Intel, macOS 15+)

1. Download the latest `Bento-<version>.dmg` from [GitHub Releases](https://github.com/quiinthieu/bento/releases).
2. Open the DMG and drag **Bento.app** to **Applications**.
3. *(Optional)* To use `bentoctx` in your terminal, open **Bento → Settings → Command Line Tool (`bentoctx`)** (or **Workspace → Install Command Line Tool…**) and confirm installing a symlink to `~/.local/bin/bentoctx` or `/usr/local/bin/bentoctx`.
   - You can also run the embedded CLI directly from the app bundle at `/Applications/Bento.app/Contents/Helpers/bentoctx`.

### Option 2: Homebrew Cask (`agent-bento`)

```sh
brew tap quiinthieu/tap
brew install --cask agent-bento
```

The `agent-bento` cask installs both `Bento.app` and the `bentoctx` binary symlink automatically (see [`Casks/README.md`](./Casks/README.md)).

---

## Companion CLI (`bentoctx`)

`bentoctx` shares the same core engine as the macOS app and supports `--json` output for scripting and CI checks (full JSON schemas in [`Docs/cli-schema.md`](./Docs/cli-schema.md)):

```sh
# Discover agents, repositories, and configuration artifacts
bentoctx scan --json
bentoctx inventory --repo ~/Projects/my-app --agent claudeCode

# Inspect precedence-resolved active & shadowed artifacts for a folder
bentoctx resolve --repo ~/Projects/my-app --agent codex

# Compute pre-prompt token budget (offline BPE/heuristic + optional consented MCP probe)
bentoctx budget --repo ~/Projects/my-app --agent claudeCode
bentoctx budget --repo ~/Projects/my-app --agent claudeCode --probe-mcp github

# Ingest local session logs and rank "Cost × Unused" skills/MCP servers
bentoctx ingest
bentoctx usage --repo ~/Projects/my-app --days 30

# Audit cross-agent rule duplicates, opposing directives, and size caps
bentoctx hygiene --repo ~/Projects/my-app --fail-on warning

# Preview (dry-run default) or apply & undo reversible fixes
bentoctx fix disableMCPServer unused-server --agent claudeCode --repo ~/Projects/my-app
bentoctx fix disableMCPServer unused-server --agent claudeCode --repo ~/Projects/my-app --apply --yes
bentoctx undo <fix-id>
```

---

## Privacy

Bento is built strictly local-first (`PLAN.md` §7):

- **Zero Telemetry or Analytics:** Bento contains no telemetry, analytics, crash reporting, accounts, or cloud sync.
- **Read-Only by Default:** Every scan, budget calculation, log ingestion, and hygiene check opens your agent configs and logs strictly read-only. A CI write-isolation lint (`Scripts/lint-writes.sh`) forbids filesystem write/symlink/delete APIs outside `BentoFixes` and `BentoStore`. Configuration edits are disabled until you explicitly enable **"Allow changes"** in Settings (or pass `--apply` in the CLI).
- **Parse-Time Secret Redaction & Keychain-Only Keys:** Environment values, HTTP headers, `Authorization` tokens, and keys matching `/(key|token|secret|password)/i` in MCP or agent configs are redacted to `«redacted»` at parse time and are never written to SQLite, diffs, logs, or exports. Optional API keys for exact token counting are stored exclusively in the **macOS Keychain**.
- **Session Log Privacy:** When ingesting local agent session logs, Bento persists only invocation counts, tool/skill names, timestamps, working directory (`cwd`), model name, and first-message character count for calibration. **Prompt and conversation text is never stored.** You can wipe all local SQLite data (and optionally Keychain keys) anytime via **Settings → Delete all Bento data…**.
- **Explicit Per-Server MCP Probe Consent:** Bento never spawns MCP servers automatically. Probing `tools/list` requires explicit per-server consent (keyed by config hash), runs with a scrubbed environment (`PATH`, `HOME`, and declared keys only), has no TTY, and enforces a strict 15-second timeout ceiling.
- **Opt-In Network Access Only:** Bento makes zero network requests unless you explicitly opt in to:
  1. **Exact Token-Count APIs** (Anthropic `count_tokens` or Gemini `countTokens`), which always display a per-request payload preview containing artifact text only (never session logs) before sending; or
  2. **Sparkle Application Updates** (EdDSA-verified `appcast.xml`), which default to **off** and can be turned off at any time in **Settings → Application Updates** (or via `BENTO_DISABLE_SPARKLE=1`).
- **Hardened Runtime & macOS Folder Permissions:** Bento is distributed outside the Mac App Store (non-sandboxed, signed with Hardened Runtime) so it can read `~/.claude`, `~/.codex`, `~/.gemini`, and `~/.copilot` without requiring Full Disk Access. If a repository resides in a macOS TCC-protected folder (`~/Documents`, `~/Desktop`, `~/Downloads`), Bento explains why macOS prompts for folder access and degrades gracefully if declined.

---

## Building, Testing & Packaging from Source

### Requirements

- macOS 15.0 (Sequoia) or newer
- Swift 6.0+ / Xcode 16.2+
- Optional: `xcodegen` (`brew install xcodegen`) for generating `Bento.xcodeproj`

### Build & Test

```sh
# Build all SwiftPM targets and CLI
swift build

# Run the full test suite (all tests use hermetic Fixtures/homes/*; real $HOME is never touched)
swift test

# Enforce write-isolation and Swift formatting lints
Scripts/lint-writes.sh
Scripts/bump-version.sh --verify
swift format lint --strict -r Package.swift Sources Tests XcodeApp XcodeUITests
```

### Universal DMG, Developer ID Signing & Notarization

Local and CI builds work out-of-the-box with ad-hoc (`-`) code signing when `Config/Signing.xcconfig` is absent:

```sh
# Build universal (arm64 + x86_64) Bento.app (with Contents/Helpers/bentoctx) and dist/Bento-<version>.dmg
Scripts/make-dmg.sh --output-dir dist
```

To sign with an Apple **Developer ID Application** certificate and notarize:

1. Copy [`Config/Signing.xcconfig.example`](./Config/Signing.xcconfig.example) to `Config/Signing.xcconfig` (gitignored) and set `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY = Developer ID Application`, and `SPARKLE_PUBLIC_ED_KEY`.
2. Build and sign the universal DMG, then notarize and staple:

```sh
Scripts/bump-version.sh 0.1.0 1
Scripts/make-dmg.sh --output-dir dist
NOTARYTOOL_PROFILE="bento-notary" Scripts/notarize.sh dist/Bento-0.1.0.dmg
```

Tagged pushes matching `v*` trigger [`.github/workflows/release.yml`](./.github/workflows/release.yml), which verifies version synchronization, runs the test suite, builds the universal `.app` and `.dmg`, signs and notarizes when repository secrets (`DEVELOPER_ID_CERT_P12_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_API_KEY_BASE64`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `SPARKLE_PUBLIC_ED_KEY`, `SPARKLE_EDDSA_PRIVATE_KEY`) are configured, renders `agent-bento.rb` and `appcast.xml`, smoke-tests `brew install --cask` in a local tap, and publishes the GitHub Release.

---

## License

Released under the [MIT License](./LICENSE). Copyright (c) 2026 Uyen Thieu.
See [`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md) for third-party open-source attributions.
