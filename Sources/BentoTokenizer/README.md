# BentoTokenizer

Offline and calibrated token counting (`PLAN.md` §6.3):

- `BPETokenizer`: byte-level BPE port matching OpenAI `tiktoken` (`o200k_base` and `cl100k_base`) backed by bundled MIT merge tables.
- `HeuristicCounter`: prose / code / JSON character-ratio estimator for Claude Code and Gemini CLI.
- `CalibratedCounter`: scales a base `TokenCounter` by a fitted per-(agent, model) `k`-factor.
- `CachingTokenCounter`: thread-safe `(counterID, contentHash)` cache preventing redundant tokenization of unchanged artifacts.
- `AgentTokenizerRegistry`: maps `(AgentID, model)` pairs to counters, confidence labels, provenance strings, and context window capacities.
