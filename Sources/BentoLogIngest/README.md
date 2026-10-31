# BentoLogIngest

`BentoLogIngest` streams plain `.jsonl`, monolithic legacy `.json`, and Zstandard-compressed `.jsonl.zst` local agent session logs (`PLAN.md` §6.2):

- `StreamingLineReader`: `AsyncSequence<Data>` and zero-copy 64 KB chunk reader holding partial trailing lines uncommitted and skipping lines larger than 16 MB (`ingest.lineOversized`).
- `ZstdLineReader`: streaming Zstandard decompression (`ZSTD_decompressStream` via vendored `CZstd`) emitting non-fatal diagnostics on corrupt or truncated `.zst` frames.
- `LogIngestor`: bounded-concurrency (`4`) incremental log ingestor tracking `log_file.offset_consumed`, detecting inode/truncation log rotation, and persisting privacy-safe `UsageEvent` and `SessionRecord` rows into `BentoStore`.
