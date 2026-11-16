import Foundation

/// 锁保护的可变状态（全仓库唯一的"锁 + 可变状态"原语，G-1）。
///
/// **为什么是 `@unchecked Sendable`**：标准库的 `Synchronization.Mutex` 需要 iOS 18 / macOS 15，
/// 本项目最低 iOS 16；`OSAllocatedUnfairLock` 只在 Darwin 上有，Linux 测试 / TSan 跑不了。
/// 所以用 `NSLock` 自己包一层，编译器无法证明"所有访问都在锁内"，只能 unchecked。
/// 保证方式：`value` 是 private，唯一的访问路径是 `withLock` / `withLockIfAvailable`；
/// `Value: Sendable`，从锁里拿出去的东西本身可跨线程。Linux 上 `swift test --sanitize=thread` 覆盖全部使用点。
/// 其他类型一律通过持有 `let LockedState` 获得**编译器检查过的** `Sendable`，不再各自写 `@unchecked`。
/// 最低版本升到 iOS 18 后换成 `Mutex`，删掉本类型。
public final class LockedState<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    /// 在锁内读写。`body` 里不要回调外部代码、不要 await（同步闭包，编译期即保证）。
    @discardableResult
    public func withLock<R: Sendable>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    /// 拿不到锁就立刻返回 nil（不阻塞），对应 `Mutex.withLockIfAvailable`。
    public func withLockIfAvailable<R: Sendable>(_ body: (inout Value) throws -> R) rethrows -> R? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return try body(&value)
    }

    /// 读当前值的拷贝。
    public func get() -> Value { withLock { $0 } }
    /// 整体替换。
    public func set(_ newValue: Value) { withLock { $0 = newValue } }
}
