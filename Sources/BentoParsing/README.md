# BentoParsing

`BentoParsing` provides tolerant, read-only configuration and rule parsers with parse-time secret redaction:
- `JSONCParser`: recursive-descent JSON and JSONC (`//`, `/* */`, trailing commas, UTF-8 BOM, nesting-depth cap) parser.
- `TOMLParser`: read-only TOML 1.1.0 parser backed by `dduan/TOMLDecoder` (`Docs/decisions/001-toml-library.md`).
- `FrontmatterParser` & `MDCParser`: YAML frontmatter (`jpsim/Yams`) and Cursor `.mdc` rule parsers with unquoted glob tolerance and body line-offset tracking.
- `MarkdownRuleSplitter`: heading-aware Markdown splitter producing normalized `RuleUnit` spans (`bullet`, `numbered`, `paragraph` sentences) while skipping fenced code blocks.
- `ImportResolver`: recursive `@import` expander for Claude Code and Gemini CLI syntax with cycle detection, hop-depth limits, and code-span/code-fence filtering against injected `ReadOnlyFileSystem` and `homeURL`.
- `SecretRedactor`: parse-time redaction (`«redacted»`) of keys matching `/(key|token|secret|password)/i`, `Authorization`, `env` / `headers` values, inline CLI/Bearer tokens, and URL credentials.
