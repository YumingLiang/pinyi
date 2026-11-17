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
    /// 参数：格数（`%1$@`，按格计，不按张）。
    static let worksMissing = L10nKey(rawValue: "works.missing")
    /// 一次性提示：原照片用不了的格子已换成相近照片（参数：格数 `%1$@`，按格计）。作品查看页 / 导出前 / 结果页共用。
    /// ⚠️ 目前只有文案：「把取不到的格子换成相近照片」还没有实现（`MissingCellRematching` 仅是预留接口），暂无调用点。
    static let worksReplaced = L10nKey(rawValue: "works.replaced")
    static let worksOpenFailed = L10nKey(rawValue: "works.open_failed")
    static let worksDeleteFailed = L10nKey(rawValue: "works.delete_failed")
    /// 存过的作品只改了叠加强度时的按钮（v1.5，B10-6）。
    static let worksUpdate = L10nKey(rawValue: "works.update")
    /// 更新成功轻提示，约 2 秒自动消失（v1.5，B10-6）。
    static let worksUpdated = L10nKey(rawValue: "works.updated")
    /// 未保存提示：存过但叠加强度改了没存时的标题（v1.5，B10-11；弹窗本身由 feat/start-new 接线）。
    /// 放在这里而不是 QuickL10n.swift：那个文件与 feat/start-new 保持逐字相同，合并时不冲突。
    static let quickUnsavedUpdateTitle = L10nKey(rawValue: "quick.unsaved.update_title")

    /// 本模块用到的全部 key（`WorksL10nTests` 断言都在 Localizable.strings 里）。
    static let allWorks: [L10nKey] = [
        worksEntry, worksNavTitle, worksEmpty, worksKeepHint, previewSaveToWorks, previewSavedToWorks, worksSaveFailed,
        worksExport, worksDelete, worksDeleteConfirm, worksDeleteConfirmOK, worksMissing, worksReplaced, worksOpenFailed, worksDeleteFailed,
        worksUpdate, worksUpdated, quickUnsavedUpdateTitle,
    ]
}
