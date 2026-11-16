/// 来源页的一行（T4）。
public struct SourceRow: Sendable, Hashable, Identifiable {
    public var id: SourceSelection { selection }
    public var selection: SourceSelection
    /// 固定标题（首项）或 nil（相簿行用 `albumTitle`，用户起的名字不翻译）。
    public var titleKey: L10nKey?
    public var albumTitle: String?
    /// 第二行「N 张」/「约 N 张」。
    public var countLine: LocalizedLine
    /// 当前张数（排序 / 测试用）。
    public var count: Int
}

/// 来源页逻辑（决定 3 / 8、补充 Q2）。
public enum SourceListLogic {
    /// 首项：完全访问「全部照片」，受限「已允许访问的照片」。
    /// 扫描完成前显示资产总数「约 N 张」（不随扫描跳动），完成后显示可用张数「N 张」。
    public static func allPhotosRow(access: SourceAccess, status: IndexStatus) -> SourceRow {
        let title: L10nKey = access == .full ? .sourceListAll : .sourceListAllowed
        let (line, n) = countLine(scanComplete: isScanComplete(status), assetTotal: status.assetTotal ?? 0,
                                  available: status.available)
        return SourceRow(selection: .allPhotos, titleKey: title, albumTitle: nil, countLine: line, count: n)
    }

    /// 相簿行。隐藏资产数为 0 的相簿；扫描完成后也隐藏可用为 0 的相簿（选了也只能进空状态）。
    /// 顺序保持数据源顺序（PhotoKit 的相簿列表顺序）。
    public static func albumRows(_ albums: [AlbumInfo], availableByAlbum: [String: Int], scanComplete: Bool) -> [SourceRow] {
        albums.compactMap { a in
            guard a.assetCount > 0 else { return nil }
            let avail = availableByAlbum[a.id] ?? 0
            if scanComplete && avail == 0 { return nil }
            let (line, n) = countLine(scanComplete: scanComplete, assetTotal: a.assetCount, available: avail,
                                      completeKey: .sourceAlbumItemCount)
            return SourceRow(selection: .album(id: a.id), titleKey: nil, albumTitle: a.title, countLine: line, count: n)
        }
    }

    /// 「可用照片」= 清晰度筛选后剩下的（产品 PR #5 跟进）：扫描完成后从可用张数里减去该来源已知不够清楚的张数。
    /// 扫描未完成时显示的是资产总数「约 N 张」，不减。
    public static func excludingLowRes(_ row: SourceRow, count: Int, scanComplete: Bool) -> SourceRow {
        guard scanComplete, count > 0 else { return row }
        var r = row
        r.count = max(0, row.count - count)
        r.countLine = LocalizedLine(row.countLine.key, [CountFormat.grouped(r.count)])
        return r
    }

    /// 受限访问时来源页常驻「增加可用照片」（决定 1）。
    public static func showsAddPhotos(access: SourceAccess) -> Bool { access == .limited }

    /// 「选择相簿」是否可用：受限模式下相簿只含已授权照片，仍允许选（与系统行为一致）。
    public static func isScanComplete(_ s: IndexStatus) -> Bool {
        s.hasCompletedInitialScan && s.pending == 0 && !s.isScanning
    }

    static func countLine(scanComplete: Bool, assetTotal: Int, available: Int,
                          completeKey: L10nKey = .sourceListCount) -> (LocalizedLine, Int) {
        scanComplete
            ? (LocalizedLine(completeKey, [CountFormat.grouped(available)]), available)
            : (LocalizedLine(.sourceListCountPending, [CountFormat.grouped(assetTotal)]), assetTotal)
    }
}

/// 来源选择状态（UI 单选）。
public struct SourcePickerState: Sendable, Hashable {
    public var selection: SourceSelection = .allPhotos
    /// 相簿打不开（`source.album.unreadable`）时显示的提示。
    public var notice: L10nKey?

    public init(selection: SourceSelection = .allPhotos) { self.selection = selection }

    public mutating func select(_ s: SourceSelection) {
        selection = s
        notice = nil
    }

    /// 生成前取快照发现相簿已不存在：回到「全部照片」并提示。
    public mutating func albumBecameUnreadable() {
        selection = .allPhotos
        notice = .sourceAlbumUnreadable
    }

    /// 相簿列表刷新后，若当前选中的相簿已消失，回退到全部照片并提示。
    public mutating func reconcile(with rows: [SourceRow]) {
        if case .album = selection, !rows.contains(where: { $0.selection == selection }) { albumBecameUnreadable() }
    }
}
