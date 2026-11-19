import Foundation

/// 分页流缓存清理范围
public enum PaginationCacheScope: Sendable {
    case all
    case explore
    case search
}

/// 原始上游页拉取结果
public struct RawPageResult: Sendable {
    public let items: [Manga]
    public let hasMore: Bool

    public init(items: [Manga], hasMore: Bool? = nil) {
        self.items = items
        self.hasMore = hasMore ?? !items.isEmpty
    }
}

/// 统一前端分页协调器
/// 将不同上游页大小（如 JM 80 本/页、WNACG 12 本/页）统一适配为固定每页 18 本，
/// 同时支持顺序无缝拼页缓存与远距离快速跳页定位。
public actor UniformPaginator {
    public static let defaultPageSize = 18

    private struct StreamState {
        let sessionID: UUID
        var rawPages: [Int: RawPageResult] = [:]
        var orderedItems: [Manga] = []
        var seenIDs: Set<String> = []
        var nextSequentialRawPage: Int = 1
        var isExhausted: Bool = false
        var updatedAt: Date = Date()

        init(sessionID: UUID = UUID(), updatedAt: Date = Date()) {
            self.sessionID = sessionID
            self.updatedAt = updatedAt
        }
    }

    public let pageSize: Int
    public let approxRawPageSize: Int
    public let ttlSeconds: TimeInterval
    public let maxStreamCount: Int
    public let maxCatchUpRawPages: Int
    public let maxSparseRawPagesPerStream: Int

    private var streams: [String: StreamState] = [:]

    public init(
        pageSize: Int = UniformPaginator.defaultPageSize,
        approxRawPageSize: Int,
        ttlSeconds: TimeInterval = 120,
        maxStreamCount: Int = 24,
        maxCatchUpRawPages: Int = 3,
        maxSparseRawPagesPerStream: Int = 20
    ) {
        self.pageSize = max(1, pageSize)
        self.approxRawPageSize = max(1, approxRawPageSize)
        self.ttlSeconds = ttlSeconds
        self.maxStreamCount = max(1, maxStreamCount)
        self.maxCatchUpRawPages = max(1, maxCatchUpRawPages)
        self.maxSparseRawPagesPerStream = max(4, maxSparseRawPagesPerStream)
    }

    public func invalidateAll() {
        streams.removeAll()
    }

    public func invalidate(prefix: String) {
        let matchingKeys = streams.keys.filter { $0.hasPrefix(prefix) }
        for key in matchingKeys {
            streams.removeValue(forKey: key)
        }
    }

    public func fetchPage(
        key: String,
        page: Int,
        fetchRawPage: @escaping @Sendable (Int) async throws -> RawPageResult
    ) async throws -> [Manga] {
        guard page >= 1 else { return [] }

        let now = Date()
        pruneStreams(now: now)
        if let existing = streams[key], now.timeIntervalSince(existing.updatedAt) > ttlSeconds {
            streams.removeValue(forKey: key)
        }

        if streams[key] == nil {
            streams[key] = StreamState(updatedAt: now)
        }
        let initialState = streams[key]!
        let sessionID = initialState.sessionID

        let start = (page - 1) * pageSize
        let end = page * pageSize

        if initialState.orderedItems.count >= end || initialState.isExhausted {
            streams[key]?.updatedAt = now
            return slice(initialState.orderedItems, start: start, end: end)
        }

        let missingCount = end - initialState.orderedItems.count
        let estimatedNeededRawPages = (missingCount + approxRawPageSize - 1) / approxRawPageSize

        if estimatedNeededRawPages <= maxCatchUpRawPages {
            return try await fetchSequentialWindow(
                key: key,
                sessionID: sessionID,
                initialFallbackState: initialState,
                start: start,
                end: end,
                fetchRawPage: fetchRawPage
            )
        } else {
            return try await fetchDirectJumpWindow(
                key: key,
                sessionID: sessionID,
                start: start,
                fetchRawPage: fetchRawPage
            )
        }
    }

    // MARK: - Sequential Window

    private func fetchSequentialWindow(
        key: String,
        sessionID: UUID,
        initialFallbackState: StreamState,
        start: Int,
        end: Int,
        fetchRawPage: @escaping @Sendable (Int) async throws -> RawPageResult
    ) async throws -> [Manga] {
        var fallbackState = initialFallbackState
        var safetyIterations = 0
        let maxIterations = 20

        while safetyIterations < maxIterations {
            try Task.checkCancellation()
            safetyIterations += 1

            let isActiveSession = (streams[key]?.sessionID == sessionID)
            var workingState: StreamState
            if isActiveSession, var shared = streams[key] {
                advanceState(&shared)
                streams[key] = shared
                workingState = shared
                fallbackState = shared
            } else {
                advanceState(&fallbackState)
                workingState = fallbackState
            }

            if workingState.orderedItems.count >= end || workingState.isExhausted {
                return slice(workingState.orderedItems, start: start, end: end)
            }

            let startRawPage = workingState.nextSequentialRawPage
            let remainingNeeded = end - workingState.orderedItems.count
            let estimatedBatch = (remainingNeeded + approxRawPageSize - 1) / approxRawPageSize
            let batchCount = min(max(1, estimatedBatch), 2)

            var pagesToFetch: [Int] = []
            for offset in 0..<batchCount {
                let candidate = startRawPage + offset
                if workingState.rawPages[candidate] == nil {
                    pagesToFetch.append(candidate)
                }
            }

            if pagesToFetch.isEmpty {
                break
            }

            let fetchedMap = try await fetchRawPagesBatch(pagesToFetch, fetchRawPage: fetchRawPage)
            try Task.checkCancellation()

            if streams[key]?.sessionID == sessionID, var shared = streams[key] {
                for (rawPage, result) in fetchedMap {
                    shared.rawPages[rawPage] = result
                }
                shared.updatedAt = Date()
                advanceState(&shared)
                streams[key] = shared
                fallbackState = shared

                if shared.orderedItems.count >= end || shared.isExhausted {
                    return slice(shared.orderedItems, start: start, end: end)
                }
            } else {
                for (rawPage, result) in fetchedMap {
                    fallbackState.rawPages[rawPage] = result
                }
                advanceState(&fallbackState)

                if fallbackState.orderedItems.count >= end || fallbackState.isExhausted {
                    return slice(fallbackState.orderedItems, start: start, end: end)
                }
            }
        }

        let finalItems = (streams[key]?.sessionID == sessionID ? streams[key]?.orderedItems : nil)
            ?? fallbackState.orderedItems
        return slice(finalItems, start: start, end: end)
    }

    // MARK: - Direct Jump Window

    private func fetchDirectJumpWindow(
        key: String,
        sessionID: UUID,
        start: Int,
        fetchRawPage: @escaping @Sendable (Int) async throws -> RawPageResult
    ) async throws -> [Manga] {
        let startRawPage = start / approxRawPageSize + 1
        var offsetInCurrentRawPage = start % approxRawPageSize

        var collected: [Manga] = []
        var collectedIDs: Set<String> = []

        var cursorRawPage = startRawPage
        var fetchedLoops = 0
        let maxJumpRawPages = max(4, (pageSize / approxRawPageSize) + 3)

        while collected.count < pageSize && fetchedLoops < maxJumpRawPages {
            try Task.checkCancellation()
            fetchedLoops += 1

            let rawResult: RawPageResult
            if streams[key]?.sessionID == sessionID, let cached = streams[key]?.rawPages[cursorRawPage] {
                rawResult = cached
            } else {
                let remaining = pageSize - collected.count
                let estimatedNeeded = (offsetInCurrentRawPage + remaining + approxRawPageSize - 1) / approxRawPageSize
                let batchCount = min(max(1, estimatedNeeded), 2)

                var toFetch: [Int] = []
                for offset in 0..<batchCount {
                    let candidate = cursorRawPage + offset
                    if streams[key]?.sessionID != sessionID || streams[key]?.rawPages[candidate] == nil {
                        toFetch.append(candidate)
                    }
                }

                let fetchedBatch = try await fetchRawPagesBatch(toFetch, fetchRawPage: fetchRawPage)
                try Task.checkCancellation()

                if streams[key]?.sessionID == sessionID, var shared = streams[key] {
                    for (p, res) in fetchedBatch {
                        storeSparseRawPage(&shared, rawPage: p, result: res)
                    }
                    shared.updatedAt = Date()
                    streams[key] = shared
                }

                guard let resolved = fetchedBatch[cursorRawPage]
                    ?? (streams[key]?.sessionID == sessionID ? streams[key]?.rawPages[cursorRawPage] : nil) else {
                    break
                }
                rawResult = resolved
            }

            if rawResult.items.isEmpty {
                break
            }
            if offsetInCurrentRawPage >= rawResult.items.count {
                if rawResult.hasMore && rawResult.items.count >= approxRawPageSize / 2 {
                    cursorRawPage += 1
                    offsetInCurrentRawPage = 0
                    continue
                }
                break
            }

            var addedThisPage = 0
            for item in rawResult.items.dropFirst(offsetInCurrentRawPage) {
                if collectedIDs.insert(item.id).inserted {
                    collected.append(item)
                    addedThisPage += 1
                    if collected.count >= pageSize {
                        break
                    }
                }
            }

            if !rawResult.hasMore || addedThisPage == 0 {
                break
            }

            cursorRawPage += 1
            offsetInCurrentRawPage = 0
        }

        return collected
    }

    // MARK: - Helpers

    private func fetchRawPagesBatch(
        _ pages: [Int],
        fetchRawPage: @escaping @Sendable (Int) async throws -> RawPageResult
    ) async throws -> [Int: RawPageResult] {
        let sortedPages = pages.sorted()
        if sortedPages.count == 1, let single = sortedPages.first {
            let result = try await fetchRawPage(single)
            return [single: result]
        }

        return try await withThrowingTaskGroup(of: (Int, Result<RawPageResult, Error>).self) { group in
            for rawPage in sortedPages {
                group.addTask {
                    do {
                        let result = try await fetchRawPage(rawPage)
                        return (rawPage, .success(result))
                    } catch {
                        return (rawPage, .failure(error))
                    }
                }
            }

            var outcomeMap: [Int: Result<RawPageResult, Error>] = [:]
            for try await (rawPage, outcome) in group {
                outcomeMap[rawPage] = outcome
            }

            var resolved: [Int: RawPageResult] = [:]
            for rawPage in sortedPages {
                guard let outcome = outcomeMap[rawPage] else { continue }
                switch outcome {
                case .success(let res):
                    resolved[rawPage] = res
                    if res.items.isEmpty || !res.hasMore {
                        return resolved
                    }
                case .failure(let error):
                    throw error
                }
            }
            return resolved
        }
    }

    private func advanceState(_ state: inout StreamState) {
        while !state.isExhausted, let result = state.rawPages[state.nextSequentialRawPage] {
            let currentRawPage = state.nextSequentialRawPage
            state.rawPages.removeValue(forKey: currentRawPage)
            state.nextSequentialRawPage = currentRawPage + 1

            if result.items.isEmpty {
                state.isExhausted = true
                break
            }

            var addedCount = 0
            for item in result.items {
                if state.seenIDs.insert(item.id).inserted {
                    state.orderedItems.append(item)
                    addedCount += 1
                }
            }

            if !result.hasMore || addedCount == 0 {
                state.isExhausted = true
                break
            }
        }
    }

    private func storeSparseRawPage(_ state: inout StreamState, rawPage: Int, result: RawPageResult) {
        state.rawPages[rawPage] = result
        if state.rawPages.count > maxSparseRawPagesPerStream {
            let excess = state.rawPages.count - maxSparseRawPagesPerStream
            let keysToDrop = state.rawPages.keys.sorted().prefix(excess)
            for k in keysToDrop {
                state.rawPages.removeValue(forKey: k)
            }
        }
    }

    private func slice(_ items: [Manga], start: Int, end: Int) -> [Manga] {
        guard start < items.count, start < end else { return [] }
        return Array(items[start..<min(end, items.count)])
    }

    private func pruneStreams(now: Date) {
        let expiredKeys = streams.compactMap { key, state in
            now.timeIntervalSince(state.updatedAt) > ttlSeconds ? key : nil
        }
        for key in expiredKeys {
            streams.removeValue(forKey: key)
        }

        if streams.count > maxStreamCount {
            let excess = streams.count - maxStreamCount
            let oldestKeys = streams
                .sorted { $0.value.updatedAt < $1.value.updatedAt }
                .prefix(excess)
                .map(\.key)
            for key in oldestKeys {
                streams.removeValue(forKey: key)
            }
        }
    }
}
