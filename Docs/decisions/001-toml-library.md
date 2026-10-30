# ADR 001: Choose `dduan/TOMLDecoder` for TOML Parsing

- **Status:** Accepted
- **Date:** 2026-10-30
- **Task:** T03 Parsing module (`PLAN.md` §3.3, §11)

## Context

`BentoParsing` parses TOML configuration and command files for Codex CLI (`~/.codex/config.toml`, `<repo>/.codex/config.toml`) and Gemini CLI (`~/.gemini/commands/**/*.toml`, `<repo>/.gemini/commands/**/*.toml`). `PLAN.md` §3.3 specifies choosing between `LebJe/TOMLKit` and `dduan/TOMLDecoder` in an ADR during T03, alongside `jpsim/Yams` for YAML frontmatter.

Key architectural constraints from `PLAN.md`:
1. **Swift 6 strict concurrency & `-warnings-as-errors`** (§0 Rule 8, §10).
2. **Read-only parsing; never re-serialize TOML via a library** (§0 Rule 3, §6.6): `BentoFixes` (T14) performs minimal format-preserving span/line edits so comments and key ordering remain intact rather than serializing a `TOMLTable` back to text.
3. **Adversarial input safety** (§9 `Fixtures/homes/hostile/`): malformed or deeply nested TOML must fail gracefully with typed Swift errors and diagnostics rather than native crashes.
4. **Universal binary packaging** (§1 G7, T16): clean `arm64` + `x86_64` macOS builds without unnecessary C++ standard library bridging.

## Options Considered

### Option A: `dduan/TOMLDecoder` (`from: "0.4.5"`)
- **Pros:**
  - 100% pure Swift with zero transitive dependencies and no C/C++ runtime bridging.
  - Supports TOML 1.1.0 (`0.4.4+`) with edge-case crash fixes in `0.4.5`.
  - Ready for Swift 6 strict concurrency; compiles cleanly with `-warnings-as-errors`.
  - Exposes both `TOMLTable` (for untyped inspection into `JSONValue` / `SettingsDoc` trees prior to secret redaction) and `TOMLDecoder` (`Codable` decoding).
  - MIT license.
- **Cons:**
  - Deserialization-only (no TOML serializer), which aligns with §6.6's prohibition on full re-serialization.

### Option B: `LebJe/TOMLKit` (`from: "0.6.0"`)
- **Pros:**
  - Wraps mature `toml++` C++17 parser and includes a serializer.
- **Cons:**
  - Introduces C++17 / Objective-C++ bridging targets, increasing clean build times and C++ exception/Interop surface when fuzzing hostile inputs.
  - Its serialization API is unneeded because §6.6 mandates format-preserving line/span edits.

## Decision

Adopt **`dduan/TOMLDecoder`** (`from: "0.4.5"`) for TOML parsing in `BentoParsing` (alongside **`jpsim/Yams`** `from: "6.0.0"` for YAML frontmatter as listed in `PLAN.md` §3.3).

## Consequences

- `BentoParsing` converts `TOMLTable` structures into `BentoCore.JSONValue` and immediately runs `SecretRedactor` at parse time before returning `SettingsDoc` or `MCPServerConfig` values.
- `BentoFixes` (T14) will implement a dedicated format-preserving TOML line/span editor as planned in §6.6 without depending on any third-party TOML serializer.
