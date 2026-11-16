/// 素材供给判断（技术方案 v0.2 §2.6 / 产品决定 v0.3 第 2、16 条）。
public enum MaterialSupply: Hashable, Sendable {
    /// 可用为 0：不进生成流程，走空状态。
    case empty
    /// 0 < 可用 < 200：生成前提示一次，**不阻止生成**。
    case insufficient(available: Int)
    /// 可用 ≥ 200。
    case sufficient

    /// 素材不足统一阈值：200 张（以「所选来源的可用照片数」计；渐进扫描中按快照内已扫描可用数计）。
    public static let insufficientThreshold = 200

    /// 判断可用张数属于哪一档。
    public static func evaluate(availableCount: Int) -> MaterialSupply {
        if availableCount <= 0 { return .empty }
        if availableCount < insufficientThreshold { return .insufficient(available: availableCount) }
        return .sufficient
    }

    /// 由掩码判断（掩码为 nil 时用素材总数）。
    public static func evaluate(library: FeatureMatrix, mask: BitMask?) -> MaterialSupply {
        evaluate(availableCount: mask?.setCount ?? library.count)
    }

    /// 是否允许开始生成（仅 `.empty` 不允许）。
    public var allowsGeneration: Bool { self != .empty }
    /// 是否需要在生成前提示素材不足。
    public var needsWarning: Bool {
        if case .insufficient = self { return true }
        return false
    }
}

/// 「换一种拼法」的种子派生（产品决定第 4 条：只换随机种子，参数不变）。
public enum MosaicSeed {
    /// 由上一次的种子确定性地派生下一个种子（SplitMix64 一步）。
    /// App 也可以直接用任意新种子；用派生方式的好处是"换 N 次"的序列可复现、便于 QA 复查。
    public static func next(after seed: UInt64) -> UInt64 {
        var g = SplitMix64(seed: seed)
        return g.next()
    }
}

extension BitMask {
    /// 多个素材源（相簿）掩码取并集（技术方案 v0.2 §2.7：MVP UI 单选，引擎保留并集能力）。
    /// 同一张照片出现在多个相簿中只计一次（位图天然去重）。
    /// - Parameters:
    ///   - masks: 各来源的掩码，长度必须都等于 `count`。
    ///   - count: 素材总数（特征表行数）。
    /// - Throws: 任一掩码长度 ≠ `count` 时抛 `MosaicError.countMismatch`。
    public static func union(_ masks: [BitMask], count: Int) throws -> BitMask {
        var r = BitMask(count: count)
        for m in masks {
            guard m.count == count else { throw MosaicError.countMismatch(expected: count, actual: m.count) }
            r = r.union(m)
        }
        return r
    }

    /// 由多个来源的行号列表构造并集掩码，重复行号（同一照片在多个相簿）自动去重。
    /// - Throws: 行号越界时抛 `MosaicError.countMismatch`。
    public init(count: Int, sources: [[Int]]) throws {
        self.init(count: count)
        for src in sources {
            for row in src {
                guard row >= 0, row < count else { throw MosaicError.countMismatch(expected: count, actual: row) }
                self[row] = true
            }
        }
    }
}
