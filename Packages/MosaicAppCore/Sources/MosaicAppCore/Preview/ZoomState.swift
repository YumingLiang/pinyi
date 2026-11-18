/// 预览 / 作品查看共用的缩放平移状态（纯值类型，Linux 可测）。
///
/// 修复「第二次放大失效」：`MagnificationGesture` 的值是**相对本次手势开始**的倍数（每次从 1 起）。
/// 旧实现 `scale = value` 没把它累乘进基准，第二次捏合又从 1 开始——看起来「没放大 / 没反应」，
/// 往小捏还会直接跳回 1。这里分成 `baseScale`（已提交）× `liveMagnification`（手势进行中），
/// 手势结束时提交；平移同理（`baseOffset` + `liveTranslation`）。
public struct ZoomState: Equatable, Sendable {
    public struct Vector: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
        public static let zero = Vector(x: 0, y: 0)
    }

    public static let minScale: Double = 1
    /// 上限的下限：网格很粗时也至少能放大到这个倍数。
    public static let minimumMaxScale: Double = 4
    /// 双击逐级放大的倍数。
    public static let doubleTapStep: Double = 2

    /// 内容按 scaledToFit 放进视口后的尺寸（scale = 1 时）。
    public private(set) var fittedSize: Vector
    /// 视口尺寸。
    public private(set) var viewport: Vector
    public private(set) var maxScale: Double

    public private(set) var baseScale: Double = 1
    public private(set) var liveMagnification: Double = 1
    public private(set) var baseOffset: Vector = .zero
    public private(set) var liveTranslation: Vector = .zero

    public init(viewport: Vector = .zero, fittedSize: Vector = .zero, maxScale: Double = ZoomState.minimumMaxScale) {
        self.viewport = viewport
        self.fittedSize = fittedSize
        self.maxScale = max(Self.minScale, maxScale)
    }

    /// 当前显示倍数（已夹在 [1, maxScale]）。
    public var scale: Double { clampScale(baseScale * liveMagnification) }
    /// 当前显示偏移（已夹在内容边界内）。
    public var offset: Vector {
        clampOffset(Vector(x: baseOffset.x + liveTranslation.x, y: baseOffset.y + liveTranslation.y), scale: scale)
    }
    public var isZoomed: Bool { scale > Self.minScale + 1e-9 }

    /// 上限：至少让**单格**铺满视口短边（格子在 scale = 1 时宽 fitted / columns）。
    public static func maxScaleToFillOneCell(viewport: Vector, fittedSize: Vector, columns: Int, rows: Int) -> Double {
        guard columns > 0, rows > 0, fittedSize.x > 0, fittedSize.y > 0, viewport.x > 0, viewport.y > 0 else {
            return minimumMaxScale
        }
        let cell = min(fittedSize.x / Double(columns), fittedSize.y / Double(rows))
        let need = min(viewport.x, viewport.y) / cell
        return max(minimumMaxScale, need)
    }

    /// 视口 / 内容 / 网格变化（旋转、换图）时调用；保留当前倍数并重新夹取。
    /// 视口为 0（切后台 / 过渡动画中 GeometryReader 可能报 0）时忽略，不丢倍数。
    public mutating func updateLayout(viewport: Vector, fittedSize: Vector, columns: Int, rows: Int) {
        guard viewport.x > 0, viewport.y > 0 else { return }
        self.viewport = viewport
        self.fittedSize = fittedSize
        maxScale = Self.maxScaleToFillOneCell(viewport: viewport, fittedSize: fittedSize, columns: columns, rows: rows)
        baseScale = clampScale(baseScale)
        baseOffset = clampOffset(baseOffset, scale: baseScale)
    }

    // MARK: 捏合

    /// `value` 是手势给的相对倍数（本次手势开始时 = 1）。
    public mutating func pinchChanged(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        liveMagnification = value
    }

    /// 结束时把本次倍数累乘进基准。`value` 为 nil 时用最后一次 onChanged 的值。
    public mutating func pinchEnded(_ value: Double? = nil) {
        if let value { pinchChanged(value) }
        let committed = scale
        let committedOffset = offset
        baseScale = committed
        liveMagnification = 1
        baseOffset = committed <= Self.minScale ? .zero : clampOffset(committedOffset, scale: committed)
    }

    /// 手势被系统取消（来电、切后台、被别的手势抢走，`onEnded` 不会触发）：丢掉本次增量，基准不变。
    public mutating func pinchCancelled() {
        liveMagnification = 1
    }

    // MARK: 平移

    public mutating func panChanged(_ translation: Vector) {
        guard isZoomed else { liveTranslation = .zero; return }
        liveTranslation = translation
    }

    public mutating func panEnded() {
        baseOffset = offset
        liveTranslation = .zero
    }

    public mutating func panCancelled() {
        liveTranslation = .zero
    }

    // MARK: 双击

    /// 上限前逐级 ×2（不超过上限）；已在上限时复位到 1。
    public mutating func doubleTap() {
        commitLive()
        if baseScale >= maxScale - 1e-9 {
            reset()
        } else {
            baseScale = min(maxScale, baseScale * Self.doubleTapStep)
            baseOffset = clampOffset(baseOffset, scale: baseScale)
        }
    }

    public mutating func reset() {
        baseScale = 1
        liveMagnification = 1
        baseOffset = .zero
        liveTranslation = .zero
    }

    // MARK: 私有

    private mutating func commitLive() {
        let s = scale, o = offset
        baseScale = s
        baseOffset = o
        liveMagnification = 1
        liveTranslation = .zero
    }

    private func clampScale(_ s: Double) -> Double {
        guard s.isFinite else { return Self.minScale }
        return min(maxScale, max(Self.minScale, s))
    }

    /// 放大后内容超出视口的一半就是允许的最大偏移；没超出就居中。
    private func clampOffset(_ o: Vector, scale: Double) -> Vector {
        let mx = max(0, (fittedSize.x * scale - viewport.x) / 2)
        let my = max(0, (fittedSize.y * scale - viewport.y) / 2)
        return Vector(x: min(mx, max(-mx, o.x)), y: min(my, max(-my, o.y)))
    }
}
