---
name: architecture-critic
description: Reviews module boundaries and dependency direction
model: gemini-2.5-pro
tools:
  - read_file
  - grep_search
---
Verify that lower-level core modules never import higher-level UI or adapter modules.
