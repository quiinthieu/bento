# AGENTS.md

This repo builds **Bento** (placeholder name, set in `Sources/BentoCore/Product.swift` and `Config/Product.xcconfig`). It's a native macOS app (Swift 6, SwiftUI, macOS 15+) and a companion CLI that audit context budget and rules hygiene for AI coding agents.

**The source of truth is [`PLAN.md`](./PLAN.md). Read §0 "Instructions for agents" before doing anything.**

Short version:
- Repo: `git@github.com:quiinthieu/bento.git`. Branch from `main` as `task/TNN-slug`, one task per PR, squash-merge after CI passes (PLAN "Repository & workflow").
- Work on the lowest-numbered unchecked task in `PLAN.md` §11, and only that task. Tick it and update `CHANGELOG.md` when its acceptance criteria pass.
- Write tests first, against `Fixtures/homes/*`. Never touch the real `$HOME`.
- Only `Sources/BentoFixes` (and `BentoStore` for its own DB) may write to disk. `Scripts/lint-writes.sh` enforces this.
- Never launch MCP servers without explicit consent. No telemetry and no network except opt-in token-count APIs.
- Agent config paths are assumptions. Verify them against current docs and record the result in `Docs/adapters/<agent>.md`.
- Swift 6 strict concurrency, `swift-format`, Swift Testing. Respect the module dependency graph (PLAN §3.2).
- Commands: `swift build`, `swift test`, `Scripts/lint-writes.sh`, `swift format lint -r Sources Tests`.
