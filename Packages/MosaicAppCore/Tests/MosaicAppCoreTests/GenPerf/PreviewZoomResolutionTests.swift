// QA 回归：预览放大时小格子发糊（AndyL 11-16 反馈）。方案：qa/perf/gen-perf-regression-plan.md §9 / V3。
//
// 指标：每格「屏幕像素 / 源像素」之比 r = (格子在当前缩放下的屏幕像素边长) / (这一格实际画上去的源像素边长)。
//   r ≤ k 视为不发糊。k 默认 1.0，**待架构师修复方案确定后对齐**（环境变量 PINYI_PREVIEW_MAX_RATIO 覆盖）。
// 源像素 = min(预览位图每格像素, 每格缩略图请求像素)。#13（3021d32）之后的 App：
//   - 预览位图每格像素：MosaicPreviewRenderer.cellPixels → PreviewImageLimits.cellPixels(columns:rows:)
//     = max(1, min(64, 4096 / max(列, 行)))：粗 40×30 → 64、中 80×60 → 51、细 120×90 → 34；位图最大 4080×3060；
//   - 结果页显示插值 `.interpolation(.high)`（原来 `.none`）；
//   - 每格缩略图：ThumbnailRequest.scanDisplay（128 px，居中裁方），缩放时仍不重新请求、不重画。
// 守卫（阻断）：①每格像素不低于上面三档的新下限、位图不超过 4080×3060（防退回 / 防内存失控）；
//   ②App 源码仍调 PreviewImageLimits、仍是 `.interpolation(.high)`、仍是 `.scanDisplay`；③取图不联网。
// 清晰度比值 r 默认只出报告（打印表格 + 写 PINYI_PREVIEW_OUT），PINYI_PREVIEW_GATE=1 时按 k 断言。
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

/// App 预览取图 / 绘制策略。每格像素已由 #13 收进 MosaicAppCore（`PreviewImageLimits`，plan §9.4 P1 的一半），
/// 这里直接调用；缩略图请求仍在 iOS target 里，保留镜像 + 源码守卫。
enum GPAppPreviewMirror {
    /// = App/Rendering/MosaicPreviewRenderer.cellPixels(for:)（源码守卫锁住它仍然委托给 PreviewImageLimits）
    static func previewBitmapCellPixels(columns: Int, rows: Int) -> Int { PreviewImageLimits.cellPixels(columns: columns, rows: rows) }
    /// = MosaicPreviewRenderer.thumbnails 里的 `.scanDisplay`
    static var thumbnailRequest: ThumbnailRequest { .scanDisplay }
    /// 缩放时是否按 zoom 重新请求更大的图（当前没有）。
    static func sourcePixelsPerCell(columns: Int, rows: Int, zoom: Double, screenPxPerCell: Double) -> Int {
        min(previewBitmapCellPixels(columns: columns, rows: rows), thumbnailRequest.targetPixelSize)
    }
}

/// #13 定下的预览下限 / 上限（锁死，防退回）。改这些数必须同时改 qa 方案 V3 并说明原因。
enum GPPreviewFloor {
    /// 4:3 / 3:4 原图三档每格像素下限（= 3021d32 实测值）。
    static let cellPixels: [DensityChoice: Int] = [.coarse: 64, .medium: 51, .fine: 34]
    /// 旧口径（8–32 px，长边 2400）——新值必须严格大于它。
    static func legacy(columns: Int, rows: Int) -> Int { max(8, min(32, 2400 / max(columns, rows))) }
    /// 标准密度下预览位图上限（长边 × 短边，像素）：4080×3060（RGBA ≈ 47.6 MiB）。
    static let maxBitmapLong = 4080
    static let maxBitmapShort = 3060
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

    /// 守卫①：每格像素不低于 #13 的新下限、严格大于旧口径、不超过 64；位图不超过 4080×3060。阻断。
    func testPreviewCellPixelsFloorLocked() throws {
        var lines: [String] = []
        for (aspectName, w, h) in [("4:3", 4032, 3024), ("3:4", 3024, 4032)] {
            for d in DensityChoice.allCases {
                let layout = try MosaicCore.Layout.grid(width: w, height: h, density: d.density)
                let cp = GPAppPreviewMirror.previewBitmapCellPixels(columns: layout.columns, rows: layout.rows)
                let floor = try XCTUnwrap(GPPreviewFloor.cellPixels[d], "\(d) 没有下限")
                let bw = layout.columns * cp, bh = layout.rows * cp
                lines.append("[preview-floor] \(d.rawValue) \(aspectName) \(layout.columns)x\(layout.rows) cellPx=\(cp) floor=\(floor) bitmap=\(bw)x\(bh)")
                XCTAssertGreaterThanOrEqual(cp, floor, "[\(d.rawValue) \(aspectName)] 预览每格 \(cp) px 低于 #13 下限 \(floor) px——放大发糊会回来")
                XCTAssertGreaterThan(cp, GPPreviewFloor.legacy(columns: layout.columns, rows: layout.rows),
                                     "[\(d.rawValue) \(aspectName)] 预览每格退回旧口径（8–32 px）")
                XCTAssertLessThanOrEqual(cp, PreviewImageLimits.maxCellPixels)
                XCTAssertLessThanOrEqual(max(bw, bh), GPPreviewFloor.maxBitmapLong, "[\(d.rawValue) \(aspectName)] 预览位图 \(bw)×\(bh) 超过 4080×3060")
                XCTAssertLessThanOrEqual(min(bw, bh), GPPreviewFloor.maxBitmapShort, "[\(d.rawValue) \(aspectName)] 预览位图 \(bw)×\(bh) 超过 4080×3060")
            }
        }
        // 长边上限本身不许放大到 4096 以上（4096² RGBA = 64 MiB 是 #13 定的内存天花板）
        XCTAssertLessThanOrEqual(PreviewImageLimits.maxLongEdge, 4096)
        XCTAssertGreaterThanOrEqual(PreviewImageLimits.maxLongEdge, GPPreviewFloor.maxBitmapLong, "长边上限被调小，细 / 中档会掉到下限以下")
        lines.forEach { print($0) }
    }

    /// 守卫②：App 源码与上面的假设一致。改了预览绘制 / 显示 / 取图方式时这里红。阻断。
    func testMirrorMatchesAppSource() throws {
        let root = gpRepoRoot()
        let rendererURL = root.appendingPathComponent("App/Rendering/MosaicPreviewRenderer.swift")
        let viewURL = root.appendingPathComponent("App/Views/MainFlowView.swift")
        guard let src = try? String(contentsOf: rendererURL, encoding: .utf8) else { throw XCTSkip("读不到 \(rendererURL.path)") }
        XCTAssertTrue(src.contains("PreviewImageLimits.cellPixels(columns: g.layout.columns, rows: g.layout.rows)"),
                      "MosaicPreviewRenderer.cellPixels 不再委托 PreviewImageLimits：本测试的下限守卫就锁不住 App 了")
        XCTAssertFalse(src.contains("min(32, 2400"), "MosaicPreviewRenderer 里又出现了旧公式（8–32 px / 2400）")
        XCTAssertTrue(src.contains("request: .scanDisplay"), "预览取图请求参数变了：更新 GPAppPreviewMirror.thumbnailRequest")
        guard let view = try? String(contentsOf: viewURL, encoding: .utf8) else { throw XCTSkip("读不到 \(viewURL.path)") }
        let resultImageLines = view.split(separator: "\n").filter { $0.contains("Image(decorative: img") }
        XCTAssertFalse(resultImageLines.isEmpty, "MainFlowView 里找不到结果页预览 Image(decorative: img…)")
        for l in resultImageLines {
            XCTAssertTrue(l.contains(".interpolation(.high)"), "结果页预览插值不是 .high：\(l.trimmingCharacters(in: .whitespaces))")
        }
        XCTAssertFalse(view.contains(".interpolation(.none)"), "MainFlowView 里出现 .interpolation(.none)，放大会出马赛克硬边")
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
