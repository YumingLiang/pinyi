import MosaicCore

#if canImport(Accelerate)
import Accelerate

/// Accelerate（vDSP / BLAS）版 `DistanceKernel` 的扩展点。
///
/// **当前为占位实现**：直接委托给 `ScalarSIMDKernel`，保证 App 侧注入点和行为先就位。
/// 真正的 Accelerate 实现（按技术方案 §3.2 用 `|q|² + |c|² − 2·q·c` 改写成 `cblas_sgemm`
/// 后再做 top‑k）需要在 macOS / 真机上编译和基准，Linux 无法验证，留待 macOS CI 就绪后实现。
/// 实现时必须保持与参考内核一致的契约：平方欧氏距离、(距离, 下标) 升序、相对容差 1e‑4。
public struct AccelerateKernel: DistanceKernel {
    private let reference: ScalarSIMDKernel

    /// 创建内核。
    public init() {
        reference = ScalarSIMDKernel()
    }

    /// 见 `DistanceKernel.topK`。目前委托给 `ScalarSIMDKernel`。
    public func topK(
        queries: UnsafeBufferPointer<Float>, m: Int,
        candidates: UnsafeBufferPointer<Float>, n: Int,
        dims: Int, k: Int, mask: BitMask?
    ) -> TopKResult {
        reference.topK(queries: queries, m: m, candidates: candidates, n: n, dims: dims, k: k, mask: mask)
    }
}
#endif

// Metal compute 内核：技术方案 §3.2 / §11.1 结论为 MVP 不做；若真机基准不达标，
// 另建 Apple 专属包实现同一 `DistanceKernel` 协议（同样用 `#if canImport(Metal)` 守卫）。
