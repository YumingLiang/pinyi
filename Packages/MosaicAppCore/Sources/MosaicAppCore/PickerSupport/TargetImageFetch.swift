import Foundation

// MARK: - 目标图取图的判定（photo-picker-v0.1 §5.2、§6.1；T3）
//
// App 层 `PhotoKitTargetImageLoader` 发 PhotoKit 请求、收回调、开定时器，**怎么判**全在这里（Linux 可测）：
// 1. 先发 `.highQualityFormat`（长边 4096，`isNetworkAccessAllowed = false`）。拿到图就用，degraded 也收。
// 2. 拿到 nil（只在 iCloud 时常带 `PHImageResultIsInCloudKey`）、出错、或超时没回调：取消它，改发 `.opportunistic`。
// 3. `.opportunistic` 可能回调多次（先 degraded 再正式版），也可能正式版是 nil：记住最后一张非 nil 的图；
//    收到非 degraded 回调就结束；只收到 degraded 的，等一小段宽限时间后用它结束；一直没回调就超时结束。
// 4. 被取消：立刻结束，结果为 nil、`reason == .cancelled`。
// 5. 任何路径都只结束一次（`finish` 只出现一次），之后的回调 / 定时器一律忽略，所以不会卡在「加载中」。
//
// 不弹任何低清提示（§5.2）：结果里只带「本机长边」等数据，给以后算叠加降级系数（§6.1 `OverlayDegrade`）和性能页用。

/// 用哪种 deliveryMode 发的请求。
public enum TargetImageRequestKind: String, Sendable, Hashable, Codable {
    /// `.highQualityFormat`：只回调一次。
    case highQuality
    /// `.opportunistic`：可能多次回调。
    case opportunistic
}

/// 一次 PhotoKit 回调里抄出来的信息（不含图本身）。
public struct TargetImageCallback: Sendable, Hashable {
    /// 是否有图（`UIImage != nil`）。
    public var hasImage: Bool
    /// 图的像素长边（无图为 0）。
    public var pixelLongSide: Int
    /// `PHImageResultIsDegradedKey`。
    public var isDegraded: Bool
    /// `PHImageResultIsInCloudKey`。
    public var isInCloud: Bool
    /// `PHImageCancelledKey`。
    public var isCancelled: Bool
    /// `PHImageErrorKey != nil`。
    public var hasError: Bool

    public init(hasImage: Bool, pixelLongSide: Int, isDegraded: Bool = false, isInCloud: Bool = false,
                isCancelled: Bool = false, hasError: Bool = false) {
        self.hasImage = hasImage
        self.pixelLongSide = hasImage ? max(0, pixelLongSide) : 0
        self.isDegraded = isDegraded
        self.isInCloud = isInCloud
        self.isCancelled = isCancelled
        self.hasError = hasError
    }
}

/// 结束原因。
public enum TargetImageFinishReason: String, Sendable, Hashable, Codable {
    /// `.highQualityFormat` 直接拿到图。
    case highQuality
    /// 回退到 `.opportunistic` 后拿到非 degraded 的正式回调（图可能来自之前的 degraded 回调）。
    case opportunisticFinal
    /// 回退后只拿到 degraded 图，宽限时间到了就用它。
    case opportunisticDegradedOnly
    /// 本机没有任何版本（两轮都没拿到图，或超时）。调用方按 §5.2 用网格缩略图兜底。
    case noLocalImage
    /// 调用方取消。
    case cancelled
}

/// 最终结果。`Image` 在 App 层是 `UIImage`，测试里随便用什么。
public struct TargetImageOutcome<Image> {
    public var image: Image?
    /// 拿到的图的像素长边（本机能拿到的版本；无图为 0）。
    public var localLongSide: Int
    public var isDegraded: Bool
    /// 过程中任何一次回调带了 InCloud 标记。
    public var sawInCloud: Bool
    public var reason: TargetImageFinishReason
    /// 是否回退到了 `.opportunistic`。
    public var usedFallback: Bool

    public init(image: Image?, localLongSide: Int, isDegraded: Bool, sawInCloud: Bool,
                reason: TargetImageFinishReason, usedFallback: Bool) {
        self.image = image
        self.localLongSide = localLongSide
        self.isDegraded = isDegraded
        self.sawInCloud = sawInCloud
        self.reason = reason
        self.usedFallback = usedFallback
    }
}

/// 状态机要 App 层做的事。按数组顺序执行。
public enum TargetImageFetchAction<Image> {
    /// 发一个请求。
    case request(TargetImageRequestKind)
    /// 取消某个已发的请求（`cancelImageRequest`）。
    case cancelRequest(TargetImageRequestKind)
    /// 开一个定时器，到点后调 `timerFired(token:)` 带回 `token`。旧 token 自动作废，不用手动取消。
    case startTimer(token: Int, seconds: Double)
    /// 结束，把结果交给调用方。整个生命周期只出现一次。
    case finish(TargetImageOutcome<Image>)
}

/// 目标图取图状态机。值类型、非线程安全：App 层在主线程驱动。
public struct TargetImageFetchMachine<Image> {
    public struct Timing: Sendable, Hashable {
        /// `.highQualityFormat` 一直不回调时，多久后放弃改走 `.opportunistic`。本机解码 48MP 到 4096 约 1 秒内。
        public var highQualityTimeout: Double
        /// `.opportunistic` 一次都没回调时，多久后按「本机没有」结束。
        public var opportunisticTimeout: Double
        /// `.opportunistic` 已给 degraded 图、正式版迟迟不来时，再等多久就用 degraded 结束。
        public var degradedGrace: Double

        public init(highQualityTimeout: Double = 10, opportunisticTimeout: Double = 5, degradedGrace: Double = 1.5) {
            self.highQualityTimeout = highQualityTimeout
            self.opportunisticTimeout = opportunisticTimeout
            self.degradedGrace = degradedGrace
        }
    }

    public enum Phase: Sendable, Hashable {
        case idle
        case highQuality
        case opportunistic
        case finished
    }

    public let timing: Timing
    public private(set) var phase: Phase = .idle
    private var timerToken = 0
    private var best: Image?
    private var bestLongSide = 0
    private var bestDegraded = false
    private var sawInCloud = false

    public init(timing: Timing = Timing()) { self.timing = timing }

    public var isFinished: Bool { phase == .finished }

    /// 开始：发 `.highQualityFormat` 请求。只在 `.idle` 时有效。
    public mutating func start() -> [TargetImageFetchAction<Image>] {
        guard phase == .idle else { return [] }
        phase = .highQuality
        return [.request(.highQuality), nextTimer(timing.highQualityTimeout)]
    }

    /// 收到某个请求的一次回调。来自已放弃的请求（例如回退后旧的 highQuality 迟到）的回调被忽略。
    public mutating func receive(_ cb: TargetImageCallback, image: Image?,
                                 from kind: TargetImageRequestKind) -> [TargetImageFetchAction<Image>] {
        if cb.isInCloud { sawInCloud = true }
        let hasImage = cb.hasImage && image != nil
        switch (phase, kind) {
        case (.highQuality, .highQuality):
            if hasImage {
                return finish(image: image, longSide: cb.pixelLongSide, degraded: cb.isDegraded,
                              reason: .highQuality, fallback: false)
            }
            // nil：只在 iCloud / 出错 / 被系统取消，都改走 .opportunistic（我们自己取消时已不在这个阶段）。
            return fallBack(cancelHighQuality: false)
        case (.opportunistic, .opportunistic):
            if hasImage {
                best = image
                bestLongSide = cb.pixelLongSide
                bestDegraded = cb.isDegraded
            }
            if !cb.isDegraded || cb.isCancelled || cb.hasError {
                // 正式回调（可能是 nil）：有图就用最后一张，没有就是本机没有。
                return finishWithBest(final: true)
            }
            // degraded：先记住，等正式版或宽限时间。
            return [nextTimer(timing.degradedGrace)]
        default:
            return []   // 已结束 / 旧请求迟到
        }
    }

    /// 定时器到点。`token` 不是最近一次 `.startTimer` 的就忽略。
    public mutating func timerFired(token: Int) -> [TargetImageFetchAction<Image>] {
        guard token == timerToken else { return [] }
        switch phase {
        case .highQuality: return fallBack(cancelHighQuality: true)
        case .opportunistic: return [.cancelRequest(.opportunistic)] + finishWithBest(final: false)
        case .idle, .finished: return []
        }
    }

    /// 调用方取消（Task 取消 / 离开页面）。
    public mutating func cancel() -> [TargetImageFetchAction<Image>] {
        switch phase {
        case .idle:
            return finish(image: nil, longSide: 0, degraded: false, reason: .cancelled, fallback: false)
        case .highQuality:
            return [.cancelRequest(.highQuality)]
                + finish(image: nil, longSide: 0, degraded: false, reason: .cancelled, fallback: false)
        case .opportunistic:
            return [.cancelRequest(.opportunistic)]
                + finish(image: nil, longSide: 0, degraded: false, reason: .cancelled, fallback: true)
        case .finished:
            return []
        }
    }

    // MARK: 内部

    private mutating func nextTimer(_ seconds: Double) -> TargetImageFetchAction<Image> {
        timerToken += 1
        return .startTimer(token: timerToken, seconds: seconds)
    }

    private mutating func fallBack(cancelHighQuality: Bool) -> [TargetImageFetchAction<Image>] {
        phase = .opportunistic
        var a: [TargetImageFetchAction<Image>] = []
        if cancelHighQuality { a.append(.cancelRequest(.highQuality)) }
        a.append(.request(.opportunistic))
        a.append(nextTimer(timing.opportunisticTimeout))
        return a
    }

    private mutating func finishWithBest(final: Bool) -> [TargetImageFetchAction<Image>] {
        guard let img = best else {
            return finish(image: nil, longSide: 0, degraded: false, reason: .noLocalImage, fallback: true)
        }
        let reason: TargetImageFinishReason = final ? .opportunisticFinal : .opportunisticDegradedOnly
        return finish(image: img, longSide: bestLongSide, degraded: bestDegraded, reason: reason, fallback: true)
    }

    private mutating func finish(image: Image?, longSide: Int, degraded: Bool, reason: TargetImageFinishReason,
                                 fallback: Bool) -> [TargetImageFetchAction<Image>] {
        guard phase != .finished else { return [] }
        phase = .finished
        timerToken += 1   // 作废所有未到点的定时器
        best = nil
        return [.finish(TargetImageOutcome(image: image, localLongSide: image == nil ? 0 : longSide,
                                           isDegraded: image == nil ? false : degraded, sawInCloud: sawInCloud,
                                           reason: reason, usedFallback: fallback))]
    }
}
