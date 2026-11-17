import Foundation
import MosaicCore
import XCTest
@testable import MosaicAppCore

/// QA 复验 ed6cce7 隐私加固：生成后才被隐藏的照片，导出必须是白格子，不能露出 128px 糊图。
/// Linux 跑不了 `LiveMosaicExporter`（CG / PhotoKit），这里用与它对齐的 `ExportFillStats.decision` 做纯像素合成。
final class HiddenExportTests: XCTestCase {

    static let hiddenRGB: (UInt8, UInt8, UInt8) = (255, 16, 32)
    static let otherA: (UInt8, UInt8, UInt8) = (16, 200, 48)
    static let otherB: (UInt8, UInt8, UInt8) = (32, 64, 220)

    /// 假 PhotoFetch + ThumbnailProviding。可见集合 = PhotoFetch 能取到的 ID；隐藏后数据仍在 `library` 里。
    final class FakePhotoFetchThumbs: ThumbnailProviding, Sendable {
        struct State: Sendable {
            var library: [String: (UInt8, UInt8, UInt8)]
            var visible: Set<String>
            /// 若为 true，隐藏后 `.scanDisplay` 仍返回独特颜色（模拟按 ID 取图忽略 includeHiddenAssets / 缓存泄漏）。
            var leakScanDisplayForHidden = false
            /// 可见但高清失败（例如 iCloud 原图未下载），走 `.unavailableLocal`。
            var unavailableLocal: Set<String> = []
            var requests: [(String, Int)] = []
        }
        let state: Locked<State>

        init(library: [String: (UInt8, UInt8, UInt8)]) {
            state = Locked(State(library: library, visible: Set(library.keys)))
        }

        func hide(_ id: String) { state.update { $0.visible.remove(id) } }
        var leakScanDisplayForHidden: Bool {
            get { state.get().leakScanDisplayForHidden }
            set { state.update { $0.leakScanDisplayForHidden = newValue } }
        }

        func markUnavailableLocal(_ id: String) { state.update { $0.unavailableLocal.insert(id) } }
        func clearRequests() { state.update { $0.requests.removeAll(keepingCapacity: true) } }

        var requestIDs: [String] {
            state.get().requests.map(\.0)
        }
        var requestSizes: [(String, Int)] { state.get().requests }

        func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
            let snap = state.update { s -> (Bool, (UInt8, UInt8, UInt8)?, Bool, Bool) in
                s.requests.append((assetID, request.targetPixelSize))
                return (s.visible.contains(assetID), s.library[assetID], s.leakScanDisplayForHidden,
                        s.unavailableLocal.contains(assetID))
            }
            let (isVisible, color, leak, unavailable) = snap
            if !isVisible {
                if leak && request.targetPixelSize <= 128, let color {
                    return .image(try! Self.solid(request.targetPixelSize, color))
                }
                return .missing
            }
            if unavailable && request.targetPixelSize > 128 { return .unavailableLocal }
            guard let color else { return .failed }
            return .image(try! Self.solid(max(1, request.targetPixelSize), color))
        }

        private static func solid(_ edge: Int, _ c: (UInt8, UInt8, UInt8)) throws -> PixelBuffer {
            try PixelBuffer.solid(width: edge, height: edge, red: c.0, green: c.1, blue: c.2)
        }
    }

    /// 与 `LiveMosaicExporter.export` 取图策略对齐的软件画布（白底，格子实心填色）。
    static func exportCanvas(ids: [String?], columns: Int, rows: Int, tier: ExportTier,
                             thumbs: FakePhotoFetchThumbs,
                             availableMemoryBytes: Int64? = 8_000_000_000) async -> (pb: PixelBuffer, plan: ExportPlan, fills: ExportFillStats) {
        let plan = ExportPlan(tier: tier, columns: columns, rows: rows, availableMemoryBytes: availableMemoryBytes)
        let cp = plan.cellPixels
        let w = plan.width, h = plan.height
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        var fills = ExportFillStats()

        func paint(cell i: Int, color: (UInt8, UInt8, UInt8)) {
            let col = i % columns, row = i / columns
            let x0 = col * cp, y0 = row * cp
            for y in 0..<cp {
                var o = ((y0 + y) * w + x0) * 4
                for _ in 0..<cp {
                    bytes[o] = color.0; bytes[o + 1] = color.1; bytes[o + 2] = color.2; bytes[o + 3] = 255
                    o += 4
                }
            }
        }

        for i in 0..<ids.count {
            guard let id = ids[i], !id.isEmpty else { fills.add(.blank); continue }
            var hq = ThumbnailRequest(targetPixelSize: cp)
            hq.fastFormat = false
            hq.fastResize = false
            hq.centerCropToSquare = true
            let hqResult = await thumbs.thumbnail(for: id, request: hq)
            switch ExportFillStats.decision(afterHighQuality: hqResult) {
            case .highQuality:
                if case .image(let pb) = hqResult {
                    paint(cell: i, color: pb.rgb(x: 0, y: 0))
                    fills.add(.highQuality)
                } else {
                    fills.add(.blank)
                }
            case .blank:
                fills.add(.blank)
            case .tryScanDisplay:
                if case .image(let pb) = await thumbs.thumbnail(for: id, request: .scanDisplay) {
                    paint(cell: i, color: pb.rgb(x: 0, y: 0))
                    fills.add(.blurryFallback)
                } else {
                    fills.add(.blank)
                }
            }
        }
        let pb = try! PixelBuffer(width: w, height: h, bytes: bytes)
        return (pb, plan, fills)
    }

    static func contains(_ pb: PixelBuffer, _ c: (UInt8, UInt8, UInt8)) -> Bool {
        for y in 0..<pb.height {
            for x in 0..<pb.width {
                let p = pb.rgb(x: x, y: y)
                if p.r == c.0 && p.g == c.1 && p.b == c.2 { return true }
            }
        }
        return false
    }

    static func cellIsWhite(_ pb: PixelBuffer, index: Int, columns: Int, cellPixels: Int) -> Bool {
        let col = index % columns, row = index / columns
        let x0 = col * cellPixels, y0 = row * cellPixels
        for y in 0..<cellPixels {
            for x in 0..<cellPixels {
                let p = pb.rgb(x: x0 + x, y: y0 + y)
                if p.r != 255 || p.g != 255 || p.b != 255 { return false }
            }
        }
        return true
    }

    static func repoRoot() -> URL? {
        if let r = ProcessInfo.processInfo.environment["PINYI_REPO_ROOT"] {
            return URL(fileURLWithPath: r)
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let marker = url.appendingPathComponent("App/Adapters/PhotoKitThumbnails.swift")
        return FileManager.default.isReadableFile(atPath: marker.path) ? url : nil
    }

    /// 8×6 网格：两格共用一张「隐藏色」照片，生成后隐藏；三档导出必须白格子且整图无该颜色。
    func testExportThreeTiersHiddenCellsAreWhiteAndColorAbsent() async throws {
        let columns = 8, rows = 6
        let hiddenID = "hidden-magenta"
        var ids: [String?] = []
        ids.reserveCapacity(columns * rows)
        for i in 0..<(columns * rows) {
            if i == 3 || i == 20 { ids.append(hiddenID) }
            else { ids.append(i % 2 == 0 ? "a" : "b") }
        }
        let thumbs = FakePhotoFetchThumbs(library: [
            hiddenID: Self.hiddenRGB, "a": Self.otherA, "b": Self.otherB,
        ])
        thumbs.hide(hiddenID)

        for tier in ExportTier.allCases {
            let (pb, plan, fills) = await Self.exportCanvas(ids: ids, columns: columns, rows: rows, tier: tier, thumbs: thumbs)
            XCTAssertGreaterThan(plan.cellPixels, 0, "\(tier)")
            XCTAssertEqual(fills.blank, 2, "\(tier) 隐藏两格应为白格子，实际 hq=\(fills.highQuality) blur=\(fills.blurryFallback) blank=\(fills.blank)")
            XCTAssertEqual(fills.blurryFallback, 0, "\(tier) 不得退回 128px 糊图")
            XCTAssertEqual(fills.highQuality, columns * rows - 2, "\(tier)")
            XCTAssertTrue(Self.cellIsWhite(pb, index: 3, columns: columns, cellPixels: plan.cellPixels), "\(tier) 格 3")
            XCTAssertTrue(Self.cellIsWhite(pb, index: 20, columns: columns, cellPixels: plan.cellPixels), "\(tier) 格 20")
            XCTAssertFalse(Self.contains(pb, Self.hiddenRGB), "\(tier) 整图不得出现隐藏色 \(Self.hiddenRGB)")
            XCTAssertTrue(Self.contains(pb, Self.otherA), "\(tier) 对照格应还在")
        }
    }

    /// 即使 `.scanDisplay` 仍能取到隐藏照片（缓存泄漏），导出也不再走 128px，必须白格子。
    func testExportDoesNotPaintScanDisplayIfHiddenAssetStillFetchable() async {
        let columns = 2, rows = 2
        let hiddenID = "leaky"
        let ids: [String?] = ["a", hiddenID, hiddenID, "b"]
        let thumbs = FakePhotoFetchThumbs(library: [
            hiddenID: Self.hiddenRGB, "a": Self.otherA, "b": Self.otherB,
        ])
        thumbs.hide(hiddenID)
        thumbs.leakScanDisplayForHidden = true
        let (pb, plan, fills) = await Self.exportCanvas(ids: ids, columns: columns, rows: rows, tier: .hd, thumbs: thumbs)
        XCTAssertEqual(fills.blurryFallback, 0, "missing 后不得再走 scanDisplay")
        XCTAssertEqual(fills.blank, 2)
        XCTAssertFalse(Self.contains(pb, Self.hiddenRGB), "泄漏路径也不得把隐藏色画进导出图")
        XCTAssertTrue(Self.cellIsWhite(pb, index: 1, columns: columns, cellPixels: plan.cellPixels))
        XCTAssertTrue(Self.cellIsWhite(pb, index: 2, columns: columns, cellPixels: plan.cellPixels))
        XCTAssertFalse(thumbs.requestSizes.contains(where: { $0.0 == hiddenID && $0.1 == 128 }),
                       "资产 missing 时不应再发 128px 请求")
        XCTAssertEqual(plan.cellPixels, 160)
    }

    /// iCloud 原图取不到但照片未隐藏：仍走 128px 合法兜底。
    func testExportUsesScanDisplayWhenVisibleAssetIsUnavailableLocal() async {
        let columns = 2, rows = 1
        let cloudID = "icloud"
        let ids: [String?] = ["a", cloudID]
        let thumbs = FakePhotoFetchThumbs(library: [
            "a": Self.otherA, cloudID: Self.otherB,
        ])
        thumbs.markUnavailableLocal(cloudID)
        let (pb, _, fills) = await Self.exportCanvas(ids: ids, columns: columns, rows: rows, tier: .uhd, thumbs: thumbs)
        XCTAssertEqual(fills.highQuality, 1)
        XCTAssertEqual(fills.blurryFallback, 1)
        XCTAssertEqual(fills.blank, 0)
        XCTAssertTrue(Self.contains(pb, Self.otherB), "可见但高清失败的格子应画出 128px 颜色")
        XCTAssertTrue(thumbs.requestSizes.contains(where: { $0.0 == cloudID && $0.1 == 128 }))
    }

    /// 「完成」路径（只改叠加强度、不重新生成）：按原格子重画底图再导出。
    /// 重画走 `ThumbnailPreviewPlan` + `.scanDisplay`（与 `MosaicPreviewRenderer.thumbnails` 相同）；
    /// 导出走 `ExportFillStats.decision`。隐藏格必须白、整图无隐藏色，导出不得再发 128px。
    func testAdjustDoneRedrawAndExportHiddenCellsAreWhite() async throws {
        let columns = 4, rows = 3
        let hiddenID = "hidden-magenta"
        var ids: [String?] = []
        ids.reserveCapacity(columns * rows)
        for i in 0..<(columns * rows) {
            if i == 1 || i == 7 { ids.append(hiddenID) }
            else { ids.append(i % 2 == 0 ? "a" : "b") }
        }
        let thumbs = FakePhotoFetchThumbs(library: [
            hiddenID: Self.hiddenRGB, "a": Self.otherA, "b": Self.otherB,
        ])
        thumbs.hide(hiddenID)

        let cp = 32
        let w = columns * cp, h = rows * cp
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let previewPlan = ThumbnailPreviewPlan(cellAssetIDs: ids, maxConcurrent: 8)
        let drawn = try await previewPlan.run(
            fetch: { id in await thumbs.thumbnail(for: id, request: .scanDisplay) }
        ) { group, pb in
            let color = pb.rgb(x: 0, y: 0)
            for cell in group.cells {
                let col = cell % columns, row = cell / columns
                let x0 = col * cp, y0 = row * cp
                for y in 0..<cp {
                    var o = ((y0 + y) * w + x0) * 4
                    for _ in 0..<cp {
                        bytes[o] = color.0; bytes[o + 1] = color.1; bytes[o + 2] = color.2; bytes[o + 3] = 255
                        o += 4
                    }
                }
            }
        }
        let preview = try PixelBuffer(width: w, height: h, bytes: bytes)
        XCTAssertEqual(drawn, 2, "ThumbnailPreviewPlan 返回画出的素材张数：a/b 各一张，隐藏照片跳过")
        XCTAssertTrue(Self.cellIsWhite(preview, index: 1, columns: columns, cellPixels: cp))
        XCTAssertTrue(Self.cellIsWhite(preview, index: 7, columns: columns, cellPixels: cp))
        XCTAssertFalse(Self.contains(preview, Self.hiddenRGB), "重画底图不得出现隐藏色")
        XCTAssertTrue(Self.contains(preview, Self.otherA))

        thumbs.clearRequests()
        thumbs.leakScanDisplayForHidden = true
        let (pb, plan, fills) = await Self.exportCanvas(ids: ids, columns: columns, rows: rows, tier: .uhd, thumbs: thumbs)
        XCTAssertEqual(fills.blank, 2)
        XCTAssertEqual(fills.blurryFallback, 0, "「完成」后导出不得退回 128px")
        XCTAssertEqual(fills.highQuality, columns * rows - 2)
        XCTAssertTrue(Self.cellIsWhite(pb, index: 1, columns: columns, cellPixels: plan.cellPixels))
        XCTAssertTrue(Self.cellIsWhite(pb, index: 7, columns: columns, cellPixels: plan.cellPixels))
        XCTAssertFalse(Self.contains(pb, Self.hiddenRGB))
        XCTAssertFalse(thumbs.requestSizes.contains(where: { $0.0 == hiddenID && $0.1 == 128 }),
                       "导出在 missing 后不得再发 128px")
    }

    /// 源码守卫：assets() 取回后滤 isHidden；导出按 decision(afterHighQuality:) 处理 missing。
    func testExportAndThumbnailSourceGuards() throws {
        guard let root = Self.repoRoot() else { throw XCTSkip("repo root not found") }
        let exp = try String(contentsOf: root.appendingPathComponent("App/Export/LiveMosaicExporter.swift"), encoding: .utf8)
        let thumbs = try String(contentsOf: root.appendingPathComponent("App/Adapters/PhotoKitThumbnails.swift"), encoding: .utf8)
        let fetch = try String(contentsOf: root.appendingPathComponent("App/Adapters/PhotoFetch.swift"), encoding: .utf8)
        XCTAssertTrue(exp.contains("ExportFillStats.decision(afterHighQuality:"))
        XCTAssertTrue(exp.contains("case .blank:"))
        XCTAssertTrue(exp.contains("case .tryScanDisplay:"))
        XCTAssertTrue(exp.contains("setFillColor") && exp.contains("[1, 1, 1, 1]"), "画布应先铺白")
        XCTAssertTrue(thumbs.contains("PhotoFetch.visibleImages(withLocalIdentifiers:"))
        XCTAssertTrue(thumbs.contains("return .missing"))
        XCTAssertTrue(fetch.contains("includeHiddenAssets = false"))
        XCTAssertTrue(fetch.contains("visibleImages(withLocalIdentifiers:"))
        XCTAssertTrue(fetch.contains("isHidden"))
        XCTAssertTrue(fetch.contains("VisibleAssetFilter.accepting"))
        XCTAssertTrue(fetch.contains("func isPickedAssetAvailable"))
        XCTAssertTrue(fetch.contains("!visibleImages(withLocalIdentifiers: [id]).isEmpty"),
                      "isPickedAssetAvailable 应走 visibleImages，不单独 images + isHidden")
    }
}
