import BentoCore
import Synchronization

/// Thread-safe content-hash token count cache so unchanged artifact bytes are never re-tokenized (`PLAN.md` §6.1, §11 T08).
public final class CachingTokenCounter: Sendable {
    private struct CacheKey: Hashable, Sendable {
        var counterID: String
        var contentHash: String
    }

    private let maxEntries: Int
    private let cache = Mutex<[CacheKey: Int]>([:])

    /// Creates a content-hash token count cache.
    public init(maxEntries: Int = 32_768) {
        self.maxEntries = max(64, maxEntries)
    }

    /// Returns a cached token count for `(counter.id, contentHash)` or computes and caches `counter.count(text)`.
    public func count(_ text: String, contentHash: String?, using counter: any TokenCounter) -> Int {
        guard !text.isEmpty else { return 0 }
        guard let contentHash, !contentHash.isEmpty else {
            return counter.count(text)
        }

        let key = CacheKey(counterID: counter.id, contentHash: contentHash)
        if let hit = cache.withLock({ $0[key] }) {
            return hit
        }

        let computed = counter.count(text)
        cache.withLock { map in
            if map.count >= maxEntries {
                map.removeAll(keepingCapacity: true)
            }
            map[key] = computed
        }
        return computed
    }

    /// Clears all cached token counts.
    public func removeAll() {
        cache.withLock { $0.removeAll() }
    }
}
