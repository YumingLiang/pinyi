import Foundation
import MosaicCore
import MosaicAppCore

/// 导出器的 Apple 实现（T8）。本提交只有临时目录管理；条带渲染见 feat/render-export。
/// 导出文件一律放在 `tmp/export/`，启动时整个目录清空（B-27）。
struct LiveMosaicExporter: MosaicExporting {
    let thumbnails: any ThumbnailProviding

    static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
    }

    func estimatedBytes(for request: ExportRequest) -> Int64 { 0 }

    func availableBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func export(_ request: ExportRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        throw ExportError.encodingFailed   // T8 实现
    }

    func discard(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    func removeStaleExports() { try? FileManager.default.removeItem(at: Self.exportDirectory) }
}
