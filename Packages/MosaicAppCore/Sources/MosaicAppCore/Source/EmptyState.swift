/// 空状态（决定 16）。
public enum LibraryEmptyState: Sendable, Hashable {
    /// 资产数为 0：「相册里还没有照片」。
    case noPhotos
    /// 资产数 > 0 但本地可解码缩略图为 0：「照片都还没下载到这台手机」+「重新检查」。
    case notDownloaded

    public var titleKey: L10nKey { self == .noPhotos ? .emptyNoPhotosTitle : .emptyNotDownloadedTitle }
    public var bodyKey: L10nKey { self == .noPhotos ? .emptyNoPhotosBody : .emptyNotDownloadedBody }
    public var buttonKey: L10nKey { self == .noPhotos ? .emptyNoPhotosOK : .emptyNotDownloadedRetry }

    /// 全库层面的空状态。diff 前（不知道总数）返回 nil；扫描未完成时只能判断 `noPhotos`。
    public static func evaluate(_ s: IndexStatus) -> LibraryEmptyState? {
        guard let total = s.assetTotal else { return nil }
        if total == 0 { return .noPhotos }
        let complete = SourceListLogic.isScanComplete(s)
        if complete && s.available == 0 && s.unavailableLocal > 0 { return .notDownloaded }
        return nil
    }

    /// 扫描完成时的轻提示：部分未下载、但仍有可用照片 →「有些照片还没下载到这台手机，已跳过」。
    public static func completionNotice(_ s: IndexStatus) -> L10nKey? {
        SourceListLogic.isScanComplete(s) && s.unavailableLocal > 0 && s.available > 0 ? .scanSkippedUndownloaded : nil
    }
}
