# BentoLogIngest

`BentoLogIngest` streams plain `.jsonl` and `.jsonl.zst` agent session logs incrementally by byte offset, handles log rotation, and decodes privacy-preserving `UsageEvent` records without storing prompt or response text.
