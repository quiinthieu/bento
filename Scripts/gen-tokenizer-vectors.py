#!/usr/bin/env python3
"""Downloads and verifies official MIT tiktoken BPE vocabularies (o200k_base,
cl100k_base), writes raw RFC-1951 deflate bundle resources for BentoTokenizer,
and generates >= 1,000 deterministic reference vectors in
Fixtures/tokenizer/vectors.jsonl.

Usage:
    uv run --with tiktoken python3 Scripts/gen-tokenizer-vectors.py
"""

from __future__ import annotations

import hashlib
import json
import pathlib
import random
import urllib.request
import zlib

import tiktoken

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
RESOURCES_DIR = REPO_ROOT / "Resources" / "tokenizers"
MODULE_RESOURCES_DIR = REPO_ROOT / "Sources" / "BentoTokenizer" / "Resources"
VECTORS_PATH = REPO_ROOT / "Fixtures" / "tokenizer" / "vectors.jsonl"

VOCABS: dict[str, dict[str, str]] = {
    "cl100k_base": {
        "url": "https://openaipublic.blob.core.windows.net/encodings/cl100k_base.tiktoken",
        "sha256": "223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7",
    },
    "o200k_base": {
        "url": "https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken",
        "sha256": "446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d",
    },
}

TIKTOKEN_MIT_LICENSE = """MIT License

Copyright (c) 2022 OpenAI, Shantanu Jain

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""


def raw_deflate(data: bytes) -> bytes:
    compressor = zlib.compressobj(level=9, method=zlib.DEFLATED, wbits=-15)
    return compressor.compress(data) + compressor.flush()


def ensure_vocabs() -> None:
    RESOURCES_DIR.mkdir(parents=True, exist_ok=True)
    MODULE_RESOURCES_DIR.mkdir(parents=True, exist_ok=True)

    for name, spec in VOCABS.items():
        dest = RESOURCES_DIR / f"{name}.tiktoken"
        if dest.exists():
            raw = dest.read_bytes()
        else:
            with urllib.request.urlopen(spec["url"], timeout=60) as resp:
                raw = resp.read()
        actual_sha = hashlib.sha256(raw).hexdigest()
        if actual_sha != spec["sha256"]:
            raise RuntimeError(
                f"SHA-256 mismatch for {name}: expected {spec['sha256']}, got {actual_sha}"
            )
        dest.write_bytes(raw)

        compressed = raw_deflate(raw)
        # Verify round-trip raw deflate immediately.
        restored = zlib.decompress(compressed, wbits=-15)
        assert restored == raw
        (MODULE_RESOURCES_DIR / f"{name}.tiktoken.deflate").write_bytes(compressed)
        print(
            f"[ok] {name}: {len(raw):,} bytes -> {len(compressed):,} bytes deflate"
        )

    (RESOURCES_DIR / "LICENSE").write_text(TIKTOKEN_MIT_LICENSE, encoding="utf-8")
    (MODULE_RESOURCES_DIR / "LICENSE").write_text(TIKTOKEN_MIT_LICENSE, encoding="utf-8")


def build_candidate_strings() -> list[tuple[str, str]]:
    rng = random.Random(20261031)
    samples: list[tuple[str, str]] = []
    seen: set[str] = set()

    def add(category: str, text: str) -> None:
        if text not in seen:
            seen.add(text)
            samples.append((category, text))

    # 1. Empty & whitespace / newline / lookahead edge cases
    whitespace_cases = [
        "",
        " ",
        "  ",
        "   ",
        "    ",
        "        ",
        "\t",
        "\t\t  \t",
        "\n",
        "\n\n",
        "\n\n\n",
        "\r",
        "\r\n",
        "\r\n\r\n",
        " \n",
        "  \n  ",
        "   \r\n   ",
        "hello ",
        "hello  ",
        "hello   ",
        "hello    ",
        " hello",
        "  hello",
        "   hello",
        "    hello",
        "a   b",
        "a    b    c",
        "line1   \nline2   \r\nline3   ",
        "\tindented\n\t\tdouble indented\n    four spaces\n        eight spaces",
    ]
    for s in whitespace_cases:
        add("whitespace", s)

    # 2. Single ASCII characters & control characters
    for code in range(1, 128):
        add("ascii_single", chr(code))

    # 3. Contractions & apostrophe casing (exercises (?i:'s|'t|'re|'ve|'m|'ll|'d))
    contractions = [
        "I'm",
        "I'M",
        "don't",
        "DON'T",
        "Don't",
        "we're",
        "WE'RE",
        "they've",
        "THEY'VE",
        "she'll",
        "SHE'LL",
        "he'd",
        "HE'D",
        "it's",
        "IT'S",
        "can't've",
        "wouldn't've",
        "'s",
        "'t",
        "'re",
        "'ve",
        "'m",
        "'ll",
        "'d",
        "''s",
        "'hello'",
        "user's repo's agent's token's budget's",
        "O'Reilly's book isn't where you'd think it'll be.",
    ]
    for s in contractions:
        add("contractions", s)

    # 4. Numbers & numeric boundaries (\p{N}{1,3})
    numbers = [
        "0",
        "1",
        "12",
        "123",
        "1234",
        "12345",
        "123456",
        "1234567",
        "1234567890",
        "3.141592653589793",
        "-42.005e-12",
        "1_000_000_000",
        "0xdeadbeef",
        "0b10101011",
        "2026-10-31T09:52:32+07:00",
        "192.168.1.254:8080/v1/health",
        "sha256:446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d",
        "٠٠١٢٣٤٥٦٧٨٩",  # Arabic-Indic digits (\p{N})
        "１２３４５６７８９０",  # Fullwidth digits (\p{N})
    ]
    for s in numbers:
        add("numbers", s)

    # 5. Identifier styles (exercises o200k uppercase/lowercase regex branches)
    identifiers = [
        "ClaudeCodeAdapter",
        "HTTPURLResponse",
        "JSONCParser",
        "TOMLDecoder",
        "XMLHttpRequest",
        "URLSessionConfiguration",
        "FSEventStreamCreateFlagFileEvents",
        "mcp__github__create_pull_request",
        "mcp__postgres__query_readonly",
        "o200k_base",
        "cl100k_base",
        "AGENTS.override.md",
        "CLAUDE.local.md",
        "SKILL.md",
        "gemini-2.5-pro-preview-05-06",
        "claude-sonnet-4-20250514",
        "gpt-5-codex",
        " camelCaseWithLeadingSpace",
        " PascalCaseWithLeadingSpace",
        " ALLCAPSWORD",
        " MixedCAPSAndLower123",
    ]
    for s in identifiers:
        add("identifiers", s)

    # 6. Punctuation, slashes, URLs, paths, special tokens as ordinary text
    punctuation_cases = [
        "/",
        "//",
        "///",
        "/// Doc comment on public API\n",
        "/* multi\n * line\n * comment */\n",
        "https://api.anthropic.com/v1/messages/count_tokens",
        "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-pro:countTokens",
        "~/.claude/projects/-Users-alice-Developer-app/session.jsonl",
        "@~/shared/security-rules.md",
        "@./docs/architecture.md",
        "<|endoftext|>",
        "<|fim_prefix|>func demo() {<|fim_suffix|>}<|fim_middle|>",
        "|--|--|--|",
        "├─ Sources/\n│  ├─ BentoCore/\n└─ Tests/\n",
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{\"cursor\":\"abc==\"}}",
        "================================================================================",
        "--------------------------------------------------------------------------------",
        "?!?!?!...---***+++===///\\\\\\",
    ]
    for s in punctuation_cases:
        add("punctuation_paths", s)

    # 7. Multilingual Unicode, combining marks (\p{M}), CJK, Emoji + ZWJ
    unicode_cases = [
        "Café naïve résumé façade coöperate",
        "Cafe\u0301 nai\u0308ve re\u0301sume\u0301",  # NFD combining marks
        "Xin chào Việt Nam — Nguyễn Thị Minh Khai, Quận 1, TP. Hồ Chí Minh",
        "Привет, мир! Проверка токенизации кириллицы и UTF-8 байтов.",
        "مرحبا بالعالم — اختبار تجزئة النصوص العربية مع التشكيل: كِتَابٌ",
        "नमस्ते दुनिया — देवनागरी लिपि और संयुक्त अक्षरों का परीक्षण",
        "สวัสดีชาวโลก ทดสอบการตัดคำภาษาไทยและวรรณยุกต์",
        "日本語のトークン化テスト：漢字、ひらがな、カタカナ、全角記号「」【】。",
        "中文分词与字节对编码（BPE）基准测试：上下文预算与规则卫生审计。",
        "한국어 토크나이저 테스트: 한글 음절과 자모 분리 검증!",
        "🚀✨🔥🧪📦🔍🛡️",
        "👨‍👩‍👧‍👦 🏳️‍🌈 👩🏽‍💻 👍🏻 👍🏽 👍🏿 🇺🇸 🇻🇳 🇯🇵",
        "∀x ∈ ℝ, ∃ε > 0 : ‖f(x + ε) - f(x)‖₂ ≤ δ · √(α² + β²)",
        "Greek: αβγδεζηθικλμνξοπρστυφχψω ΑΒΓΔΕΖΗΘΙΚΛΜΝΞΟΠΡΣΤΥΦΧΨΩ",
    ]
    for s in unicode_cases:
        add("unicode", s)

    # 8. Real files & line slices from Fixtures/homes/*
    fixtures_root = REPO_ROOT / "Fixtures" / "homes"
    if fixtures_root.exists():
        for path in sorted(fixtures_root.rglob("*")):
            if not path.is_file() or path.suffix in {".zst", ".bin"}:
                continue
            try:
                content = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            if 0 < len(content) <= 4000:
                add("fixture_file", content)
            for line in content.splitlines(keepends=True):
                if line.strip():
                    add("fixture_line", line)

    # 9. Programmatic combinations: Markdown rules, JSON schemas, TOML configs, Swift/TS/Python snippets
    verbs = ["Always", "Never", "Prefer", "Avoid", "Require", "Enforce", "Verify", "Document"]
    subjects = [
        "strict concurrency in Swift 6 modules",
        "read-only file system access outside Fixes",
        "explicit user consent before MCP server probes",
        "4-space indentation and 120-column line limits",
        "parse-time secret redaction for API keys and tokens",
        "deterministic SHA-256 ArtifactID generation",
        "resumable byte-offset JSONL log ingestion",
        "format-preserving minimal span edits in TOML and JSONC",
    ]
    langs = ["swift", "typescript", "python", "json", "toml", "bash"]
    models = ["gpt-5-codex", "gpt-4o-mini", "o3-mini", "claude-sonnet-4-0", "gemini-2.5-pro"]
    globs = ["Sources/**/*.swift", "Tests/**/*Tests.swift", "packages/*/src/**/*.{ts,tsx}", "*.md"]

    for i in range(450):
        v1 = verbs[i % len(verbs)]
        v2 = verbs[(i * 3 + 1) % len(verbs)]
        s1 = subjects[i % len(subjects)]
        s2 = subjects[(i * 5 + 2) % len(subjects)]
        lang = langs[i % len(langs)]
        model = models[i % len(models)]
        glob = globs[i % len(globs)]

        if i % 5 == 0:
            md = (
                f"---\ndescription: Rule #{i} for {model}\nglobs:\n  - \"{glob}\"\nalwaysApply: {str(i % 2 == 0).lower()}\n---\n\n"
                f"# Section {i}: Engineering Guidelines\n\n"
                f"- **{v1}** {s1} (`rule_{i:03d}`).\n"
                f"- {v2} {s2} when editing `{glob}`.\n"
                f"  1. Run `swift test --parallel` (timeout <= {15 + (i % 45)}s).\n"
                f"  2. Check ratio {((i + 1) * 1.37):.2f}% against baseline.\n"
            )
            add("synthetic_markdown", md)
        elif i % 5 == 1:
            schema = json.dumps(
                {
                    "name": f"mcp_tool_{i:03d}",
                    "description": f"{v1} {s1} and {v2.lower()} {s2}.",
                    "inputSchema": {
                        "type": "object",
                        "properties": {
                            "repoPath": {"type": "string", "description": f"Path matching {glob}"},
                            "maxTokens": {"type": "integer", "minimum": 1, "maximum": 128000, "default": 4096 + i},
                            "includeDeferred": {"type": "boolean"},
                            "tags": {"type": "array", "items": {"type": "string"}},
                        },
                        "required": ["repoPath"],
                        "additionalProperties": False,
                    },
                },
                indent=2 if i % 2 == 0 else None,
            )
            add("synthetic_json_schema", schema)
        elif i % 5 == 2:
            toml_text = (
                f"# Configuration profile {i}\n"
                f"model = \"{model}\"\n"
                f"project_doc_max_bytes = {32768 + i * 128}\n\n"
                f"[mcp_servers.server_{i:03d}]\n"
                f"command = \"uvx\"\n"
                f"args = [\"--from\", \"pkg-{i}==1.{(i % 9)}.0\", \"serve\", \"--port\", \"{8000 + i}\"]\n"
                f"enabled = {'true' if i % 3 != 0 else 'false'}\n"
            )
            add("synthetic_toml", toml_text)
        elif i % 5 == 3:
            code = (
                f"public struct CounterSample{i}: Sendable, Hashable {{\n"
                f"    public let id: String = \"sample-{i:04d}\"\n"
                f"    public var weight: Double = {(i * 0.125):.3f}\n\n"
                f"    public func evaluate(input: String) -> Int {{\n"
                f"        guard !input.isEmpty else {{ return 0 }}\n"
                f"        return input.utf8.count / {max(1, (i % 6) + 1)} // {lang}\n"
                f"    }}\n"
                f"}}\n"
            )
            add("synthetic_swift", code)
        else:
            # Mixed prose + unicode + punctuation + random whitespace runs
            pad = " " * ((i % 5) + 1)
            mixed = (
                f"[{i:04d}]{pad}Agent '{model}' loaded {i * 17} tokens (Δ={i - 200:+d}) "
                f"from `~/.config/agent_{i}/rules.md` — café/日本語/🚀! Don't skip checks.\r\n"
            )
            add("synthetic_mixed", mixed)

    # 10. Stress edge cases: long repeated runs of single characters / punctuation / spaces / multibyte UTF-8
    for length in [8, 17, 33, 64, 129, 257]:
        add("repeat_runs", " " * length)
        add("repeat_runs", "a" * length)
        add("repeat_runs", "-" * length)
        add("repeat_runs", "/" * length)
        add("repeat_runs", "0" * length)
        add("repeat_runs", "é" * (length // 2))
        add("repeat_runs", "🔥" * max(2, length // 4))

    # Deterministic random token mixtures to guarantee > 1,100 diverse vectors
    alphabet = [
        "function", " ", "  ", "\n", "\r\n", "const", "=>", "===", "!==",
        "~/.claude/", "AGENTS.md", "don't", "we'll", "12345", "3.14",
        "日本語", "Việt", "🚀", "/*comment*/", "{\"k\":true}", "[table.sub]",
        "CamelCaseWord", "HTTPRequest", "/usr/local/bin", "\t", "---",
    ]
    while len(samples) < 1150:
        k = rng.randint(4, 18)
        text = "".join(rng.choices(alphabet, k=k))
        add("random_composite", text)

    return samples


def generate_vectors() -> None:
    enc_o200k = tiktoken.get_encoding("o200k_base")
    enc_cl100k = tiktoken.get_encoding("cl100k_base")

    candidates = build_candidate_strings()
    assert len(candidates) >= 1000, f"Expected >= 1000 vectors, got {len(candidates)}"

    VECTORS_PATH.parent.mkdir(parents=True, exist_ok=True)
    with VECTORS_PATH.open("w", encoding="utf-8", newline="\n") as out:
        for idx, (category, text) in enumerate(candidates):
            toks_o200k = enc_o200k.encode_ordinary(text)
            toks_cl100k = enc_cl100k.encode_ordinary(text)
            record = {
                "id": idx,
                "category": category,
                "text": text,
                "o200k_base_count": len(toks_o200k),
                "cl100k_base_count": len(toks_cl100k),
                "o200k_base_tokens": toks_o200k,
                "cl100k_base_tokens": toks_cl100k,
            }
            out.write(json.dumps(record, ensure_ascii=False) + "\n")

    print(f"[ok] Wrote {len(candidates):,} reference vectors to {VECTORS_PATH}")


def main() -> None:
    ensure_vocabs()
    generate_vectors()


if __name__ == "__main__":
    main()
