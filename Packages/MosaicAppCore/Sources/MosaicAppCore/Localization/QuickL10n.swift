/// 「再拼一张」/ 相簿多选文案 key（copy_v1.1.md「v1.4 补充」）。单独成文件，避免和其他线同时改 `L10nKey.swift`。
public extension L10nKey {
    static let quickAgain = L10nKey(rawValue: "quick.again")
    /// 参数：name、count。
    static let quickSourceSummary = L10nKey(rawValue: "quick.source.summary")
    static let quickSourceChange = L10nKey(rawValue: "quick.source.change")
    static let quickUnsavedTitle = L10nKey(rawValue: "quick.unsaved.title")
    static let quickUnsavedSave = L10nKey(rawValue: "quick.unsaved.save")
    static let quickUnsavedDiscard = L10nKey(rawValue: "quick.unsaved.discard")
    static let quickUnsavedCancel = L10nKey(rawValue: "quick.unsaved.cancel")

    /// 本模块用到的全部 key（`QuickAgainTests` 断言都在 Localizable.strings 里）。
    static let allQuick: [L10nKey] = [
        quickAgain, quickSourceSummary, quickSourceChange, quickUnsavedTitle, quickUnsavedSave, quickUnsavedDiscard,
        quickUnsavedCancel,
    ]
}
