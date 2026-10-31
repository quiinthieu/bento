# BentoMCPProbe

`BentoMCPProbe` probes explicitly consented MCP servers (`MCPConsentStore`, keyed by `MCPServerConfigHasher` SHA-256 digests) over scrubbed non-TTY child processes (`StdioMCPClient`, 15 s timeout, bounded 16 KB stderr) or Streamable HTTP/SSE (`StreamableHTTPMCPClient`, skipping v1 OAuth `401`/`403` servers), follows `tools/list` `nextCursor` pagination, and caches tool schemas via `MCPProbeCaching`.
