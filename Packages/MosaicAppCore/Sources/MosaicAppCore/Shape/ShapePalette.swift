import Foundation
import MosaicCore

/// 多色标渐变（OKLab 里分段线性插值，色标等距）。4 个固定配色是只有两个色标的特例，与按相册取色走同一条代码路径
/// （架构师 S2：`ShapePaletteBuilder`）。
public struct ShapeGradient: Sendable, Equatable {
    /// 色标（≥ 1 个；1 个时整片同色）。
    public let stops: [OKLab]

    public init(stops: [OKLab]) {
        precondition(!stops.isEmpty, "gradient needs at least one stop")
        self.stops = stops
    }

    /// t ∈ [0, 1] 处的颜色（越界钳到两端）。
    public func color(at t: Double) -> OKLab {
        guard stops.count > 1 else { return stops[0] }
        let x = min(1, max(0, t)) * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(x.rounded(.down)))
        let f = Float(x - Double(i))
        let a = stops[i], b = stops[i + 1]
        return OKLab(L: a.L + (b.L - a.L) * f, a: a.a + (b.a - a.a) * f, b: a.b + (b.b - a.b) * f)
    }

    /// 颜色到渐变折线上最近一点的 OKLab 欧氏距离（素材不足检测用，需求 §2-1）。
    public func distance(to c: OKLab) -> Float {
        guard stops.count > 1 else { return stops[0].squaredDistance(to: c).squareRoot() }
        var best = Float.infinity
        for i in 0..<(stops.count - 1) {
            let p = stops[i].simd, q = stops[i + 1].simd, x = c.simd
            let d = q - p
            let len2 = (d * d).sum()
            var t: Float = 0
            if len2 > 0 { t = min(1, max(0, ((x - p) * d).sum() / len2)) }
            let e = x - (p + d * t)
            best = min(best, (e * e).sum().squareRoot())
        }
        return best
    }
}

/// 形状配色（设计 shape-mosaic-v0.1 §4；需求 §2-1、§7 AndyL 11-17 05:55）。
public enum ShapePaletteBuilder {
    // MARK: - 固定配色

    /// 固定配色的两端色（8 位 sRGB 十六进制，需求 §2-1）。`auto` 返回 `nil`。
    public static func fixedEndpoints(_ palette: ShapePalette) -> (start: UInt32, end: UInt32)? {
        switch palette {
        case .auto: return nil
        case .warmRed: return (0xB8403A, 0xE0774E)
        case .pink: return (0xD9809A, 0xF2B6C4)
        case .blue: return (0x3C6BAF, 0x86ACDA)
        case .gold: return (0xB98A3A, 0xE6C478)
        }
    }

    /// 8 位 sRGB 十六进制 → OKLab。
    public static func oklab(hex: UInt32) -> OKLab {
        OKLab(LinearRGB(srgb8Red: UInt8((hex >> 16) & 0xFF), green: UInt8((hex >> 8) & 0xFF), blue: UInt8(hex & 0xFF)))
    }

    // MARK: - 按相册取色（auto）

    /// 近灰阈值：chroma < 0.03 的照片不参与色相分桶。
    public static let grayChroma: Float = 0.03
    /// 有彩照片占比低于 30% 时退回按明度的单色渐变。
    public static let minColorfulShare = 0.30
    /// 色相桶数。
    public static let hueBuckets = 12
    /// 选中的色相桶之间至少相隔几个桶。
    public static let minBucketGap = 2
    /// 最多几个色标。
    public static let maxHueStops = 3
    /// 一个色相桶至少要占有彩照片的多少才算「主色」（⚠️ 设计未写，见 shape-s2-questions.md Q3）。
    public static let minStopShare = 0.10
    /// 明度渐变取的分位。
    public static let lightnessQuantiles = (low: 0.20, high: 0.80)

    /// auto 配色的结果种类（测试与日志用）。
    public enum AutoKind: Sendable, Equatable {
        /// 2–3 个主色相之间的多段渐变。
        case multiHue(count: Int)
        /// 只有一个主色相：这个颜色的深浅渐变。
        case singleHue
        /// 有彩照片不到 30%（相册偏灰）：按明度的中性色渐变。
        case lightness
        /// 没有任何照片特征：中性默认渐变。
        case empty
    }

    /// auto 配色。
    public struct AutoPalette: Sendable, Equatable {
        public let gradient: ShapeGradient
        public let kind: AutoKind
    }

    /// 某个配色的渐变。`photoColors` 只在 `auto` 时使用（每张可用照片的 OKLab 平均色）。
    public static func gradient(for palette: ShapePalette, photoColors: [OKLab]) -> ShapeGradient {
        if let (s, e) = fixedEndpoints(palette) {
            return ShapeGradient(stops: [oklab(hex: s), oklab(hex: e)])
        }
        return auto(photoColors: photoColors).gradient
    }

    /// 按相册取色：去掉近灰照片后按色相分 12 桶，取照片最多、且彼此相隔 ≥ 2 桶的 2–3 个桶，按色相排序，
    /// 每桶取 L、a、b 中位数作色标，多段插值。只有一个主色相时退成它的深浅渐变；有彩照片不到 30% 时退成明度渐变。
    /// 结果只由照片颜色决定，与种子无关（「换一种拼法」不变色）。
    public static func auto(photoColors: [OKLab]) -> AutoPalette {
        guard !photoColors.isEmpty else {
            return AutoPalette(gradient: ShapeGradient(stops: [OKLab(L: 0.45, a: 0, b: 0), OKLab(L: 0.80, a: 0, b: 0)]),
                               kind: .empty)
        }
        let colorful = photoColors.filter { chroma($0) >= grayChroma }
        if Double(colorful.count) < minColorfulShare * Double(photoColors.count) {
            let ls: [Float] = photoColors.map { $0.L }
            let lo: Float = quantile(ls, lightnessQuantiles.low)
            let hi: Float = quantile(ls, lightnessQuantiles.high)
            let stops: [OKLab] = [OKLab(L: lo, a: 0, b: 0), OKLab(L: hi, a: 0, b: 0)]
            return AutoPalette(gradient: ShapeGradient(stops: stops), kind: .lightness)
        }

        var buckets = [[OKLab]](repeating: [], count: hueBuckets)
        for c in colorful { buckets[hueBucket(c)].append(c) }
        let minCount = max(1, Int((minStopShare * Double(colorful.count)).rounded(.up)))
        let counts: [Int] = buckets.map { $0.count }
        // 照片多的优先；数量相同按桶号（确定）。
        let ranked: [Int] = rankBuckets(counts).filter { counts[$0] >= minCount }
        var picked: [Int] = []
        for b in ranked where picked.count < maxHueStops {
            if picked.allSatisfy({ circularGap($0, b) >= minBucketGap }) { picked.append(b) }
        }

        if picked.count >= 2 {
            let stops: [OKLab] = picked.sorted().map { medianColor(buckets[$0]) }
            return AutoPalette(gradient: ShapeGradient(stops: stops), kind: .multiHue(count: stops.count))
        }

        // 只有一个主色相（或都太分散）：取最多的那个桶，做这个颜色的深浅渐变。
        let main: Int = picked.first ?? rankBuckets(counts)[0]
        let cs: [OKLab] = buckets[main]
        let hue = medianColor(cs)
        let ls: [Float] = cs.map { $0.L }
        var lo: Float = quantile(ls, lightnessQuantiles.low)
        var hi: Float = quantile(ls, lightnessQuantiles.high)
        if hi - lo < 0.1 {
            // 明度太集中时拉开一点，保证看得出深浅（仍在合法范围内）。
            let mid = (lo + hi) / 2
            lo = max(0.05, mid - 0.1)
            hi = min(0.95, mid + 0.1)
        }
        let stops: [OKLab] = [OKLab(L: lo, a: hue.a, b: hue.b), OKLab(L: hi, a: hue.a, b: hue.b)]
        return AutoPalette(gradient: ShapeGradient(stops: stops), kind: .singleHue)
    }

    /// 快照里每张可用照片的平均色（OKLab）。特征口径不是 OKLab 时返回空数组（调用方按 `.empty` 处理）。
    public static func photoColors(snapshot: LibrarySnapshot) -> [OKLab] {
        guard snapshot.table.spec.colorSpace == .oklab else { return [] }
        let m = snapshot.table.matrix
        var out: [OKLab] = []
        out.reserveCapacity(snapshot.availableCount)
        for i in 0..<m.count where snapshot.mask[i] {
            var l: Float = 0, a: Float = 0, b: Float = 0
            for blk in 0..<FeatureVector.blockCount {
                l += m.value(dimension: blk * 3, index: i)
                a += m.value(dimension: blk * 3 + 1, index: i)
                b += m.value(dimension: blk * 3 + 2, index: i)
            }
            let n = Float(FeatureVector.blockCount)
            out.append(OKLab(L: l / n, a: a / n, b: b / n))
        }
        return out
    }

    // MARK: - 工具

    /// 桶号按照片数降序、同数按桶号升序。
    static func rankBuckets(_ counts: [Int]) -> [Int] {
        Array(counts.indices).sorted { x, y in
            if counts[x] != counts[y] { return counts[x] > counts[y] }
            return x < y
        }
    }

    /// 一组颜色的 L、a、b 各自中位数。
    static func medianColor(_ cs: [OKLab]) -> OKLab {
        let ls: [Float] = cs.map { $0.L }
        let as_: [Float] = cs.map { $0.a }
        let bs: [Float] = cs.map { $0.b }
        return OKLab(L: median(ls), a: median(as_), b: median(bs))
    }

    static func chroma(_ c: OKLab) -> Float { (c.a * c.a + c.b * c.b).squareRoot() }

    static func hueBucket(_ c: OKLab) -> Int {
        var h = atan2(Double(c.b), Double(c.a))
        if h < 0 { h += 2 * Double.pi }
        return min(hueBuckets - 1, Int(h / (2 * Double.pi) * Double(hueBuckets)))
    }

    static func circularGap(_ a: Int, _ b: Int) -> Int {
        let d = abs(a - b)
        return min(d, hueBuckets - d)
    }

    static func median(_ xs: [Float]) -> Float { quantile(xs, 0.5) }

    /// 最近秩分位（确定、无插值）。
    static func quantile(_ xs: [Float], _ q: Double) -> Float {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let i = min(s.count - 1, max(0, Int((q * Double(s.count - 1)).rounded())))
        return s[i]
    }
}

/// 固定配色的素材不足检测（需求 §2-1；设计 §4）：近色照片 < max(50, ceil(形状内格数 ÷ 单张上限)) 时提示
/// `shape.color.shortage`，**不拦截**。auto 不做此检测（照常走 200 张门槛）。
public enum ShapeColorShortage {
    /// 近色：照片平均色到渐变折线最近点的 OKLab 距离 ≤ 0.10。
    public static let nearDistance: Float = 0.10
    /// 近色张数下限。
    public static let minimumNearPhotos = 50

    /// 近色照片张数。
    public static func nearCount(photoColors: [OKLab], gradient: ShapeGradient) -> Int {
        photoColors.reduce(0) { $0 + (gradient.distance(to: $1) <= nearDistance ? 1 : 0) }
    }

    /// 需要的近色张数：max(50, ceil(形状内格数 ÷ 单张上限))；上限与匹配器同一套（`UsageCap.resolve`，按形状内格数）。
    public static func requiredNearCount(activeCells: Int, availableCount: Int, cap: UsageCap = .default) -> Int {
        guard let c = cap.resolve(cellCount: activeCells, availableCount: availableCount), c > 0 else {
            return minimumNearPhotos
        }
        return max(minimumNearPhotos, (activeCells + c - 1) / c)
    }

    /// 是否提示 `shape.color.shortage`。
    public static func shouldWarn(palette: ShapePalette, photoColors: [OKLab], activeCells: Int,
                                  cap: UsageCap = .default) -> Bool {
        guard palette != .auto else { return false }
        let g = ShapePaletteBuilder.gradient(for: palette, photoColors: photoColors)
        return nearCount(photoColors: photoColors, gradient: g)
            < requiredNearCount(activeCells: activeCells, availableCount: photoColors.count, cap: cap)
    }
}
