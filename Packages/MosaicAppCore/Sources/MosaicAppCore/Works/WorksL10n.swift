/// 「我的作品」文案 key（copy_v1.1.md §5.5，⚠️ 待文案确认）。单独成文件，避免与导出线同时改 `L10nKey.swift`。
public extension L10nKey {
    static let worksEntry = L10nKey(rawValue: "works.entry")
    static let worksNavTitle = L10nKey(rawValue: "works.nav_title")
    static let worksEmpty = L10nKey(rawValue: "works.empty")
    static let worksKeepHint = L10nKey(rawValue: "works.keep_hint")
    static let previewSaveToWorks = L10nKey(rawValue: "preview.save_to_works")
    static let previewSavedToWorks = L10nKey(rawValue: "preview.saved_to_works")
    static let worksSaveFailed = L10nKey(rawValue: "works.save_failed")
    static let worksExport = L10nKey(rawValue: "works.export")
    static let worksDelete = L10nKey(rawValue: "works.delete")
    static let worksDeleteConfirm = L10nKey(rawValue: "works.delete.confirm")
    static let worksDeleteConfirmOK = L10nKey(rawValue: "works.delete.confirm.ok")
    /// 参数：格数（`%1$@`）：本次找不到合格相近照片、用旧预览兜底的格子。
    static let worksMissing = L10nKey(rawValue: "works.missing")
    /// 参数：格数（`%1$@`）：本次换成相近照片的格子。
    static let worksReplaced = L10nKey(rawValue: "works.replaced")
    static let worksOpenFailed = L10nKey(rawValue: "works.open_failed")
    static let worksDeleteFailed = L10nKey(rawValue: "works.delete_failed")

    /// 本模块用到的全部 key（`WorksL10nTests` 断言都在 Localizable.strings 里）。
    static let allWorks: [L10nKey] = [
        worksEntry, worksNavTitle, worksEmpty, worksKeepHint, previewSaveToWorks, previewSavedToWorks, worksSaveFailed,
        worksExport, worksDelete, worksDeleteConfirm, worksDeleteConfirmOK, worksMissing, worksReplaced, worksOpenFailed, worksDeleteFailed,
    ]
}
