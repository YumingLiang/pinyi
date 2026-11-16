/// 可复现的伪随机数生成器（技术方案 §11.1：约束贪心用自带 PRNG，不用系统随机数）。
///
/// 为保证 Linux / iOS、不同 Swift 版本间结果逐位一致，本模块**不使用**标准库的
/// `shuffle(using:)` / `Int.random(in:using:)`（其算法属于实现细节，可能随版本变化），
/// 而是自带 `nextBounded(_:)` 与 Fisher–Yates 洗牌。
public protocol SeededRandomGenerator: RandomNumberGenerator, Sendable {
    /// 用 64 位种子初始化。
    init(seed: UInt64)
}

extension SeededRandomGenerator {
    /// 返回 `[0, upperBound)` 内均匀分布的整数（Lemire 乘法 + 拒绝采样，无偏）。
    /// - Precondition: `upperBound > 0`。
    public mutating func nextBounded(_ upperBound: UInt64) -> UInt64 {
        precondition(upperBound > 0, "upperBound must be > 0")
        var product = next().multipliedFullWidth(by: upperBound)
        if product.low < upperBound {
            let threshold = (0 &- upperBound) % upperBound
            while product.low < threshold {
                product = next().multipliedFullWidth(by: upperBound)
            }
        }
        return product.high
    }

    /// 返回 `[0, 1)` 内的 Float（取高 24 位）。
    public mutating func nextUnitFloat() -> Float {
        Float(next() >> 40) * (1.0 / 16_777_216.0)
    }

    /// 生成 `0..<count` 的可复现随机排列（Fisher–Yates，从后往前）。
    public mutating func permutation(count: Int) -> [Int] {
        precondition(count >= 0)
        var a = Array(0..<count)
        var i = count - 1
        while i > 0 {
            let j = Int(nextBounded(UInt64(i + 1)))
            a.swapAt(i, j)
            i -= 1
        }
        return a
    }
}

/// SplitMix64（Steele, Lea, Flood 2014；Vigna 参考实现）。
/// 状态 64 位、速度快，常用于为其它生成器播种。
public struct SplitMix64: SeededRandomGenerator {
    /// 内部状态。
    public private(set) var state: UInt64

    /// 用种子初始化（任意值均可，包括 0）。
    public init(seed: UInt64) {
        state = seed
    }

    /// 下一个 64 位输出。
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// xoshiro256**（Blackman & Vigna 2018）。用 SplitMix64 展开种子以避免全零状态。
/// 约束贪心默认使用它生成遍历顺序。
public struct Xoshiro256StarStar: SeededRandomGenerator {
    private var s0: UInt64
    private var s1: UInt64
    private var s2: UInt64
    private var s3: UInt64

    /// 用 64 位种子初始化（内部经 SplitMix64 展开为 256 位状态）。
    public init(seed: UInt64) {
        var sm = SplitMix64(seed: seed)
        s0 = sm.next()
        s1 = sm.next()
        s2 = sm.next()
        s3 = sm.next()
    }

    /// 直接用 256 位状态初始化（用于与参考实现对拍）。
    /// - Precondition: 状态不能全为 0。
    public init(state: (UInt64, UInt64, UInt64, UInt64)) {
        precondition(state != (0, 0, 0, 0), "xoshiro256** state must not be all zero")
        (s0, s1, s2, s3) = state
    }

    /// 下一个 64 位输出。
    public mutating func next() -> UInt64 {
        let result = rotl(s1 &* 5, 7) &* 9
        let t = s1 << 17
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = rotl(s3, 45)
        return result
    }

    @inline(__always)
    private func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }
}
