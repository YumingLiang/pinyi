/// 相簿多选文案 key（copy_v1.1.md §5.6，v1.4；quick-start v1.0 §2f）。单独成文件，避免和其他线同时改 `L10nKey.swift`。
public extension L10nKey {
    /// 参数：已选个数、去重合计。
    static let sourceSelectionSummary = L10nKey(rawValue: "source.selection.summary")
    static let sourceSelectionNone = L10nKey(rawValue: "source.selection.none")
    static let sourceSelectionDedupNote = L10nKey(rawValue: "source.selection.dedup_note")
    /// 扫描完成前（「约」）。参数同 `sourceSelectionSummary`。
    static let sourceSelectionSummaryPending = L10nKey(rawValue: "source.selection.summary_pending")
    static let sourceAlbumDone = L10nKey(rawValue: "source.album.done")
    /// 参数：name1、name2、count。
    static let quickSourceSummaryTwo = L10nKey(rawValue: "quick.source.summary_two")
    /// 参数：name1、相簿个数、count。
    static let quickSourceSummaryMany = L10nKey(rawValue: "quick.source.summary_many")

    static let allMultiAlbum: [L10nKey] = [
        sourceSelectionSummary, sourceSelectionNone, sourceSelectionDedupNote, sourceSelectionSummaryPending,
        sourceAlbumDone, quickSourceSummaryTwo, quickSourceSummaryMany,
    ]
}
