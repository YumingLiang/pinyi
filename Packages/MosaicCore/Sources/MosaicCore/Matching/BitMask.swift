/// 定长位图掩码：标记哪些素材可参与匹配（技术方案 §2.7「选相簿」→ 位图掩码；5 万位 ≈ 6 KB）。
public struct BitMask: Hashable, Sendable {
    /// 位数（应等于素材数）。
    public let count: Int
    /// 64 位字存储，低位在前；末字多余位恒为 0。
    public private(set) var words: [UInt64]

    /// 创建掩码。
    /// - Parameters:
    ///   - count: 位数，≥ 0。
    ///   - allSet: 初始是否全部置 1。
    public init(count: Int, allSet: Bool = false) {
        precondition(count >= 0, "BitMask count must be >= 0")
        self.count = count
        let wordCount = (count + 63) / 64
        words = [UInt64](repeating: allSet ? ~0 : 0, count: wordCount)
        if allSet { clearTail() }
    }

    /// 用置 1 的下标集合创建掩码。越界下标会触发前置条件失败。
    public init<S: Sequence>(count: Int, setIndices: S) where S.Element == Int {
        self.init(count: count)
        for i in setIndices { self[i] = true }
    }

    /// 读写第 `index` 位。
    public subscript(index: Int) -> Bool {
        get {
            precondition(index >= 0 && index < count, "BitMask index out of range")
            return words[index >> 6] & (1 << UInt64(index & 63)) != 0
        }
        set {
            precondition(index >= 0 && index < count, "BitMask index out of range")
            let bit: UInt64 = 1 << UInt64(index & 63)
            if newValue { words[index >> 6] |= bit } else { words[index >> 6] &= ~bit }
        }
    }

    /// 置 1 的位数。
    public var setCount: Int {
        words.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// 并集（多选相簿，技术方案 §2.7）。
    /// - Precondition: 两个掩码长度相同。
    public func union(_ other: BitMask) -> BitMask {
        precondition(count == other.count, "BitMask length mismatch")
        var r = self
        for i in r.words.indices { r.words[i] |= other.words[i] }
        return r
    }

    /// 交集。
    /// - Precondition: 两个掩码长度相同。
    public func intersection(_ other: BitMask) -> BitMask {
        precondition(count == other.count, "BitMask length mismatch")
        var r = self
        for i in r.words.indices { r.words[i] &= other.words[i] }
        return r
    }

    private mutating func clearTail() {
        let rem = count & 63
        if rem != 0, !words.isEmpty {
            words[words.count - 1] &= (1 << UInt64(rem)) - 1
        }
    }
}
