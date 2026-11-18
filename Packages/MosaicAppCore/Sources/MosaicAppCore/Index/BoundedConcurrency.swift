/// 有界并发 map（技术方案 §5：缩略图请求并发 ≤ 16–32，生成期间降到 4）。
/// 结果顺序与输入一致；被取消时抛 `CancellationError`（已开始的子任务会收到取消）。
public enum BoundedConcurrency {
    public static func map<T: Sendable, R: Sendable>(
        _ items: [T], maxConcurrent: Int, _ transform: @escaping @Sendable (T) async -> R
    ) async throws -> [R] {
        let limit = max(1, maxConcurrent)
        var results = [R?](repeating: nil, count: items.count)
        try await withThrowingTaskGroup(of: (Int, R).self) { group in
            var next = 0
            func addNext() {
                let i = next
                let item = items[i]
                group.addTask {
                    try Task.checkCancellation()
                    return (i, await transform(item))
                }
                next += 1
            }
            while next < min(limit, items.count) { addNext() }
            while let (i, r) = try await group.next() {
                results[i] = r
                if Task.isCancelled { group.cancelAll(); throw CancellationError() }
                if next < items.count { addNext() }
            }
        }
        try Task.checkCancellation()
        return results.map { $0! }
    }
}
