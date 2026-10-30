# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

- **T03 Parsing module:** Added ADR `Docs/decisions/001-toml-library.md` selecting `dduan/TOMLDecoder` alongside `jpsim/Yams`, implemented tolerant `JSONCParser` (`//`, `/* */`, trailing commas, depth guard), `TOMLParser`, `FrontmatterParser` + `MDCParser` (including unquoted leading-`*` glob recovery), `MarkdownRuleSplitter`, recursive `ImportResolver` (Claude/Gemini `@import` syntax, cycle detection, max-depth enforcement, code-block exclusion), parse-time `SecretRedactor`, and `Fixtures/homes/hostile/` adversarial tests.
- **T02 Core models + ReadOnlyFileSystem + fixture harness:** Implemented all §4.1 domain models and §5.1 adapter/environment protocols in `BentoCore`, collision-resistant SHA-256 `ArtifactID` and `ContentHasher`, POSIX `lstat`-backed `LocalReadOnlyFileSystem`, `FixtureHome` and `GoldenFile` test harness (`RECORD_GOLDEN=1` + `<HOME>` path normalization), and `empty/` + `polyglot/` skeleton fixtures.
- **T01 Package & tooling skeleton:** Added `Package.swift` across all §3.1 targets with Swift 6 strict concurrency, `Product` constants synchronized with `Config/Product.xcconfig`, XcodeGen `Project.yml`, `swift-format` configuration, `Scripts/lint-writes.sh` (+ self-test `Scripts/test-lint-writes.sh`), GitHub Actions `ci.yml`, and `DependencyGraphTests` / `ProductTests` / `LintWritesTests` / `RootWindowTests`.
