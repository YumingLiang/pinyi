import SwiftUI
import MosaicAppCore

/// 可复用的缩放平移容器：结果预览用，后续「作品查看」也用它。
///
/// 状态与规则全部在 `MosaicAppCore.ZoomState`（Linux 单测）：捏合 = 基准 × 本次增量、结束时提交；
/// 上限至少让单格铺满屏幕；双击在上限前逐级 ×2、到顶后复位；平移夹在内容边界内。
/// 不用 CATiledLayer / UIScrollView：内容是一张 scaledToFit 的位图（加可选叠加层），SwiftUI 变换即可。
///
/// 状态由调用方持有（`Binding<ZoomState>`，结果页放在 `AppModel` 里），视图重建、旋转、切后台都不丢倍数。
/// 系统取消手势时 `onEnded` 不触发：用 `@GestureState` 标记「手势进行中」，复位时调 `pinchCancelled()` /
/// `panCancelled()`（onEnded 已提交时它们是空操作）。
struct ZoomableContainer<Content: View>: View {
    /// 内容宽高比（宽 / 高），用来算 scale = 1 时的 fitted 尺寸。
    let aspectRatio: Double
    /// 网格列 / 行数，用来算「单格铺满屏幕」的上限；未知时传 0。
    let columns: Int
    let rows: Int

    @Binding var zoom: ZoomState
    @ViewBuilder let content: () -> Content

    @GestureState private var pinching = false
    @GestureState private var panning = false

    var body: some View {
        GeometryReader { geo in
            let viewport = ZoomState.Vector(x: geo.size.width, y: geo.size.height)
            content()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(zoom.scale)
                .offset(x: zoom.offset.x, y: zoom.offset.y)
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .updating($pinching) { _, active, _ in active = true }
                        .onChanged { zoom.pinchChanged(Double($0)) }
                        .onEnded { zoom.pinchEnded(Double($0)) }
                        .simultaneously(with: DragGesture()
                            .updating($panning) { _, active, _ in active = true }
                            .onChanged { zoom.panChanged(.init(x: $0.translation.width, y: $0.translation.height)) }
                            .onEnded { _ in zoom.panEnded() })
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) { zoom.doubleTap() }
                }
                .onChange(of: pinching) { if !$0 { zoom.pinchCancelled() } }
                .onChange(of: panning) { if !$0 { zoom.panCancelled() } }
                .onAppear { relayout(viewport) }
                .onChange(of: geo.size) { _ in relayout(viewport) }
                .onChange(of: columns) { _ in relayout(viewport) }
                .onChange(of: rows) { _ in relayout(viewport) }
        }
    }

    private func relayout(_ viewport: ZoomState.Vector) {
        zoom.updateLayout(viewport: viewport, fittedSize: Self.fitted(aspectRatio, in: viewport), columns: columns, rows: rows)
    }

    static func fitted(_ aspect: Double, in viewport: ZoomState.Vector) -> ZoomState.Vector {
        guard aspect > 0, viewport.x > 0, viewport.y > 0 else { return viewport }
        return viewport.x / viewport.y > aspect
            ? .init(x: viewport.y * aspect, y: viewport.y)
            : .init(x: viewport.x, y: viewport.x / aspect)
    }
}
