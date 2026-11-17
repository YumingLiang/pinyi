// QA 回归：预览放大时小格子发糊（AndyL 11-16 反馈）。方案：qa/perf/gen-perf-regression-plan.md §9。
//
// 指标：每格「屏幕像素 / 源像素」之比 r = (格子在当前缩放下的屏幕像素边长) / (这一格实际画上去的源像素边长)。
//   r ≤ k 视为不发糊。k 默认 1.0，**待架构师修复方案确定后对齐**（环境变量 PINYI_PREVIEW_MAX_RATIO 覆盖）。
// 源像素 = min(预览位图每格像素, 每格缩略图请求像素)。当前 App（d31925f）：
//   - 预览位图每格像素：App/Rendering/MosaicPreviewRenderer.cellPixels = max(8, min(32, 2400 / max(列, 行)))，只画一次，不随缩放重画；
//   - 每格缩略图：ThumbnailRequest.scanDisplay（128 px，居中裁方），缩放时不重新请求。
// App 层这两处在 iOS target 里，Linux 测不到 → 这里是**镜像**，另有同步守卫（源码里公式变了就红，提示改用全栈提供的钩子，见 plan §9.4 P1–P3）。
//
// 默认只出报告（打印表格 + 写 PINYI_PREVIEW_OUT），PINYI_PREVIEW_GATE=1 时按 k 断言。
import Foundation
import XCTest
import MosaicCore
import MosaicAppCore

/// 设备与视口（iPhone 17 Pro Max：440×956 pt，@3x）。结果页预览区的实际视口待真机量，先取 440×600 pt。
struct GPDevice: Sendable {
    var name = "iPhone 17 Pro Max"
    var screenScale = 3.0
    var viewport = ZoomState.Vector(x: 440, y: 600)
}

/// App 预览取图 / 绘制策略的镜像（待全栈把它收进 MosaicAppCore 后改为直接调用，见 P1）。
enum GPAppPreviewMirror {
    /// = App/Rendering/MosaicPreviewRenderer.cellPixels(for:)
    static func previewBitmapCellPixels(columns: Int, rows: Int) -> Int { max(8, min(32, 2400 / max(columns, rows))) }
    /// = MosaicPreviewRenderer.thumbnails 里的 `.scanDisplay`
    static var thumbnailRequest: ThumbnailRequest { .scanDisplay }
    /// 缩放时是否按 zoom 重新请求更大的图（当前没有）。
    static func sourcePixelsPerCell(columns: Int, rows: Int, zoom: Double, screenPxPerCell: Double) -> Int {
        min(previewBitmapCellPixels(columns: columns, rows: rows), thumbnailRequest.targetPixelSize)
    }
}

struct GPPreviewRow: Codable {
    var density: String
    var aspect: String
    var columns: Int
    var rows: Int
    var zoomLabel: String
    var zoom: Double
    var screenPxPerCell: Double
    var sourcePxPerCell: Int
    var ratio: Double
    var exportUHDCellPx: Int
    var exportHDCellPx: Int
}

final class PreviewZoomResolutionTests: XCTestCase {
    static var maxRatio: Double { Double(ProcessInfo.processInfo.environment["PINYI_PREVIEW_MAX_RATIO"] ?? "") ?? 1.0 /* 待定 */ }
    static var gate: Bool { ProcessInfo.processInfo.environment["PINYI_PREVIEW_GATE"] == "1" }

    static func rows(device: GPDevice = GPDevice()) throws -> [GPPreviewRow] {
        var out: [GPPreviewRow] = []
        for (aspectName, w, h) in [("4:3", 4032, 3024), ("3:4", 3024, 4032)] {
            for d in DensityChoice.allCases {
                let layout = try MosaicCore.Layout.grid(width: w, height: h, density: d.density)
                // 预览位图 = 列 × cp × 行 × cp，按它的宽高比 scaledToFit
                let fitted = ZoomableFit.fitted(Double(layout.columns) / Double(layout.rows), in: device.viewport)
                let cellPt = min(fitted.x / Double(layout.columns), fitted.y / Double(layout.rows))
                let maxScale = ZoomState.maxScaleToFillOneCell(viewport: device.viewport, fittedSize: fitted,
                                                               columns: layout.columns, rows: layout.rows)
                for (label, z) in [("1x", 1.0), ("2x", 2.0), ("4x", 4.0), ("max", maxScale)] {
                    let screen = cellPt * z * device.screenScale
                    let src = GPAppPreviewMirror.sourcePixelsPerCell(columns: layout.columns, rows: layout.rows, zoom: z, screenPxPerCell: screen)
                    out.append(GPPreviewRow(density: d.rawValue, aspect: aspectName, columns: layout.columns, rows: layout.rows,
                                            zoomLabel: label, zoom: z, screenPxPerCell: screen, sourcePxPerCell: src,
                                            ratio: screen / Double(max(src, 1)),
                                            exportUHDCellPx: ExportPlan(tier: .uhd, columns: layout.columns, rows: layout.rows).cellPixels,
                                            exportHDCellPx: ExportPlan(tier: .hd, columns: layout.columns, rows: layout.rows).cellPixels))
                }
            }
        }
        return out
    }

    /// 每格源像素 ≥ 屏幕像素 / k（即 r ≤ k）。默认只报告；PINYI_PREVIEW_GATE=1 时阻断。
    func testPerCellSourcePixelsCoverScreenPixelsWhenZoomed() throws {
        let k = Self.maxRatio
        let rows = try Self.rows()
        print("[preview-zoom] k=\(k)（待定） gate=\(Self.gate) device=iPhone 17 Pro Max viewport=440×600pt @3x")
        print("[preview-zoom] density aspect grid zoom screenPx/cell srcPx/cell ratio exportUHD exportHD verdict")
        var bad: [String] = []
        for r in rows {
            let ok = r.ratio <= k + 1e-9
            print(String(format: "[preview-zoom] %@ %@ %dx%d %@(%.1f) %.1f %d %.2f %d %d %@", r.density, r.aspect, r.columns, r.rows,
                         r.zoomLabel, r.zoom, r.screenPxPerCell, r.sourcePxPerCell, r.ratio, r.exportUHDCellPx, r.exportHDCellPx, ok ? "ok" : "BLUR"))
            if !ok { bad.append("\(r.density) \(r.aspect) \(r.zoomLabel): r=\(String(format: "%.2f", r.ratio))") }
        }
        if let p = ProcessInfo.processInfo.environment["PINYI_PREVIEW_OUT"] {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(rows).write(to: URL(fileURLWithPath: p))
        }
        if Self.gate {
            XCTAssertTrue(bad.isEmpty, "预览放大后有格子源像素不够（r > \(k)）：\n" + bad.joined(separator: "\n"))
        }
    }

    /// 同步守卫：镜像与 App 源码一致。App 改了预览取图 / 绘制方式时，这里红，提示更新镜像（或改用 P1 钩子后删掉本守卫）。
    func testMirrorMatchesAppSource() throws {
        let url = gpRepoRoot().appendingPathComponent("App/Rendering/MosaicPreviewRenderer.swift")
        guard let src = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("读不到 \(url.path)") }
        XCTAssertTrue(src.contains("max(8, min(32, 2400 / max(g.layout.columns, g.layout.rows)))"),
                      "MosaicPreviewRenderer.cellPixels 公式变了：更新 GPAppPreviewMirror.previewBitmapCellPixels")
        XCTAssertTrue(src.contains("request: .scanDisplay"), "预览取图请求参数变了：更新 GPAppPreviewMirror.thumbnailRequest")
    }

    /// 不论阈值多少都要成立：预览取图不联网、请求边长 > 0。
    func testPreviewRequestNeverAllowsNetwork() {
        XCTAssertFalse(GPAppPreviewMirror.thumbnailRequest.isNetworkAccessAllowed)
        XCTAssertGreaterThan(GPAppPreviewMirror.thumbnailRequest.targetPixelSize, 0)
    }
}

/// = App/Views/ZoomableContainer.fitted（scaledToFit）。
enum ZoomableFit {
    static func fitted(_ aspect: Double, in viewport: ZoomState.Vector) -> ZoomState.Vector {
        guard aspect > 0, viewport.x > 0, viewport.y > 0 else { return viewport }
        return viewport.x / viewport.y > aspect
            ? .init(x: viewport.y * aspect, y: viewport.y)
            : .init(x: viewport.x, y: viewport.x / aspect)
    }
}
