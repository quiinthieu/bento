#!/usr/bin/env python3
"""Hermetic fake stdio MCP server fixture for BentoMCPProbeTests (PLAN.md §6.4, §9, §11 T10)."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time


def build_tools(count: int) -> list[dict]:
    tools = []
    for index in range(count):
        tools.append(
            {
                "name": f"tool_{index}",
                "description": (
                    f"Synthetic fixture tool #{index} that queries local workspace index metadata "
                    f"and returns structured diagnostics."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "Search query expression.",
                        },
                        "limit": {
                            "type": "integer",
                            "description": "Maximum rows to return.",
                            "default": 25,
                        },
                    },
                    "required": ["query"],
                },
            }
        )
    return tools


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Fake stdio MCP server for Bento tests.")
    parser.add_argument(
        "--mode",
        choices=["normal", "paginate", "sleep", "crash", "dump-env"],
        default="normal",
    )
    parser.add_argument("--tools", type=int, default=3)
    parser.add_argument("--page-size", type=int, default=2)
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--exit-code", type=int, default=42)
    parser.add_argument("--stderr-bytes", type=int, default=256)
    parser.add_argument("--marker-file", type=str, default=None)
    return parser.parse_args()


def record_spawn_marker(marker_path: str | None) -> None:
    if not marker_path:
        return
    with open(marker_path, "a", encoding="utf-8") as handle:
        handle.write(f"spawned:{os.getpid()}\n")
        handle.flush()


def write_response(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main() -> int:
    args = parse_args()
    record_spawn_marker(args.marker_file)

    if args.mode == "crash":
        prefix = "FAKE_MCP_CRASH: fatal startup failure in fake server | "
        filler_len = max(0, args.stderr_bytes - len(prefix) - 1)
        sys.stderr.write(prefix + ("x" * filler_len) + "\n")
        sys.stderr.flush()
        return args.exit_code

    if args.mode == "sleep":
        time.sleep(args.seconds)
        return 0

    all_tools = build_tools(max(0, args.tools))

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = message.get("method")
        req_id = message.get("id")

        if method == "initialize" and req_id is not None:
            write_response(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "protocolVersion": "2025-03-26",
                        "capabilities": {"tools": {"listChanged": False}},
                        "serverInfo": {"name": "bento-fake-mcp", "version": "1.0.0"},
                    },
                }
            )
        elif method == "notifications/initialized":
            continue
        elif method == "tools/list" and req_id is not None:
            if args.mode == "dump-env":
                report = {
                    "cwd": os.path.realpath(os.getcwd()),
                    "env": dict(sorted(os.environ.items())),
                    "isatty": sys.stdin.isatty(),
                }
                write_response(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "tools": [
                                {
                                    "name": "env_report",
                                    "description": json.dumps(report, sort_keys=True),
                                    "inputSchema": {"type": "object", "properties": {}},
                                }
                            ]
                        },
                    }
                )
            elif args.mode == "paginate":
                params = message.get("params") or {}
                cursor = params.get("cursor")
                offset = 0
                if isinstance(cursor, str) and cursor.startswith("offset_"):
                    try:
                        offset = int(cursor.split("_", 1)[1])
                    except ValueError:
                        offset = 0
                page_size = max(1, args.page_size)
                slice_end = min(len(all_tools), offset + page_size)
                page_tools = all_tools[offset:slice_end]
                result_obj: dict = {"tools": page_tools}
                if slice_end < len(all_tools):
                    result_obj["nextCursor"] = f"offset_{slice_end}"
                write_response({"jsonrpc": "2.0", "id": req_id, "result": result_obj})
            else:
                write_response(
                    {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"tools": all_tools},
                    }
                )
        elif req_id is not None:
            write_response(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32601, "message": f"Method not found: {method}"},
                }
            )

    return 0


if __name__ == "__main__":
    sys.exit(main())
