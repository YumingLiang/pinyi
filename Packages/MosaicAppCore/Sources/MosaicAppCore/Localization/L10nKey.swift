/// 文案 key（`App/Resources/copy_v1.1.md` → `zh-Hans.lproj/Localizable.strings`）。
///
/// 逻辑层只产出 key，不产出中文；视图层用 `Text(LocalizedStringKey(key.rawValue))` 显示。
/// `L10nKeyTests` 会读取仓库里的 `Localizable.strings`，断言这里每个 key 都真实存在（防止拼错）。
/// 刻意**不**遵守 `ExpressibleByStringLiteral`：避免 SwiftUI 里 `Text("…")` 字面量与 `Text(_: L10nKey)` 产生重载歧义。
public struct L10nKey: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
}

public extension L10nKey {
    // 首启
    static let onboarding1Title = L10nKey(rawValue: "onboarding.1.title")
    static let onboarding1Body = L10nKey(rawValue: "onboarding.1.body")
    static let onboarding1Next = L10nKey(rawValue: "onboarding.1.next")
    static let onboarding2Title = L10nKey(rawValue: "onboarding.2.title")
    static let onboarding2Body = L10nKey(rawValue: "onboarding.2.body")
    static let onboarding2Next = L10nKey(rawValue: "onboarding.2.next")
    static let onboarding3Title = L10nKey(rawValue: "onboarding.3.title")
    static let onboarding3Body = L10nKey(rawValue: "onboarding.3.body")
    static let onboarding3Start = L10nKey(rawValue: "onboarding.3.start")
    static let onboarding3Allow = L10nKey(rawValue: "onboarding.3.allow")
    // 权限
    static let permissionUndeterminedTitle = L10nKey(rawValue: "permission.undetermined.title")
    static let permissionUndeterminedBody = L10nKey(rawValue: "permission.undetermined.body")
    static let permissionUndeterminedPrimary = L10nKey(rawValue: "permission.undetermined.primary")
    static let permissionUndeterminedSecondary = L10nKey(rawValue: "permission.undetermined.secondary")
    static let limitedTitle = L10nKey(rawValue: "limited.title")
    static let limitedBody = L10nKey(rawValue: "limited.body")
    static let limitedPrimary = L10nKey(rawValue: "limited.primary")
    static let limitedSecondary = L10nKey(rawValue: "limited.secondary")
    static let limitedAllowAllLink = L10nKey(rawValue: "limited.allow_all_link")
    static let permissionDeniedTitle = L10nKey(rawValue: "permission.denied.title")
    static let permissionDeniedBody = L10nKey(rawValue: "permission.denied.body")
    static let permissionDeniedPrimary = L10nKey(rawValue: "permission.denied.primary")
    static let permissionDeniedSecondary = L10nKey(rawValue: "permission.denied.secondary")
    // 目标图
    static let targetNavTitle = L10nKey(rawValue: "target.nav_title")
    static let targetPrompt = L10nKey(rawValue: "target.prompt")
    static let targetChoose = L10nKey(rawValue: "target.choose")
    static let targetReplace = L10nKey(rawValue: "target.replace")
    static let targetNext = L10nKey(rawValue: "target.next")
    static let targetUnreadable = L10nKey(rawValue: "target.unreadable")
    // 来源
    static let sourceNavTitle = L10nKey(rawValue: "source.nav_title")
    static let sourceListAll = L10nKey(rawValue: "source.list.all")
    static let sourceListAllowed = L10nKey(rawValue: "source.list.allowed")
    static let sourceListCount = L10nKey(rawValue: "source.list.count")
    static let sourceListCountPending = L10nKey(rawValue: "source.list.count_pending")
    static let sourceListTitleFormat = L10nKey(rawValue: "source.list.title_format")
    static let sourceAlbumOption = L10nKey(rawValue: "source.album.option")
    static let sourceAlbumOptionDesc = L10nKey(rawValue: "source.album.option_desc")
    static let sourceAlbumListTitle = L10nKey(rawValue: "source.album.list_title")
    static let sourceAlbumItemCount = L10nKey(rawValue: "source.album.item_count")
    static let sourceAlbumUnreadable = L10nKey(rawValue: "source.album.unreadable")
    static let sourceAddPhotos = L10nKey(rawValue: "source.add_photos")
    static let sourceNext = L10nKey(rawValue: "source.next")
    /// 「有 N 张照片手机上的版本不够清楚，没有用上」（hd-export-req-v0.2 F5）。
    static let sourceExcludedLowRes = L10nKey(rawValue: "source.excluded_low_res")
    // 密度 / 叠加 / 生成前
    static let densitySection = L10nKey(rawValue: "density.section")
    static let densityCoarse = L10nKey(rawValue: "density.coarse")
    static let densityCoarseDesc = L10nKey(rawValue: "density.coarse.desc")
    static let densityMedium = L10nKey(rawValue: "density.medium")
    static let densityMediumDesc = L10nKey(rawValue: "density.medium.desc")
    static let densityFine = L10nKey(rawValue: "density.fine")
    static let densityFineDesc = L10nKey(rawValue: "density.fine.desc")
    static let overlaySection = L10nKey(rawValue: "overlay.section")
    static let overlayLeft = L10nKey(rawValue: "overlay.left")
    static let overlayRight = L10nKey(rawValue: "overlay.right")
    static let overlayHint = L10nKey(rawValue: "overlay.hint")
    static let generateCTA = L10nKey(rawValue: "generate.cta")
    static let generatePrivacyHint = L10nKey(rawValue: "generate.privacy_hint")
    static let shortagePregenerate = L10nKey(rawValue: "shortage.pregenerate")
    static let shortagePregenerateContinue = L10nKey(rawValue: "shortage.pregenerate.continue")
    static let shortagePregenerateBack = L10nKey(rawValue: "shortage.pregenerate.back")
    // 扫描
    static let scanTitle = L10nKey(rawValue: "scan.title")
    static let scanResume = L10nKey(rawValue: "scan.resume")
    static let scanProgress = L10nKey(rawValue: "scan.progress")
    static let scanFirstTimeHint = L10nKey(rawValue: "scan.first_time_hint")
    static let scanProgressiveReady = L10nKey(rawValue: "scan.progressive.ready")
    static let scanProgressiveHint = L10nKey(rawValue: "scan.progressive.hint")
    static let scanProgressiveCTA = L10nKey(rawValue: "scan.progressive.cta")
    static let scanCancel = L10nKey(rawValue: "scan.cancel")
    static let scanCancelConfirmTitle = L10nKey(rawValue: "scan.cancel_confirm.title")
    static let scanCancelConfirmBody = L10nKey(rawValue: "scan.cancel_confirm.body")
    static let scanCancelConfirmStop = L10nKey(rawValue: "scan.cancel_confirm.stop")
    static let scanCancelConfirmContinue = L10nKey(rawValue: "scan.cancel_confirm.continue")
    static let scanSkippedUndownloaded = L10nKey(rawValue: "scan.skipped_undownloaded")
    static let miscScanStopped = L10nKey(rawValue: "misc.scan_stopped")
    // 生成中
    static let generateProgressTitle = L10nKey(rawValue: "generate.progress.title")
    static let generateProgressBody = L10nKey(rawValue: "generate.progress.body")
    static let generateProgressCancel = L10nKey(rawValue: "generate.progress.cancel")
    /// 探测清晰度期间的进度页正文。
    static let generateProgressChecking = L10nKey(rawValue: "generate.progress.checking")
    static let generateCancelConfirmTitle = L10nKey(rawValue: "generate.cancel_confirm.title")
    static let generateCancelConfirmConfirm = L10nKey(rawValue: "generate.cancel_confirm.confirm")
    static let generateCancelConfirmContinue = L10nKey(rawValue: "generate.cancel_confirm.continue")
    static let generateAutoRetryFailed = L10nKey(rawValue: "generate.auto_retry_failed")
    static let generateAutoRetryFailedRetry = L10nKey(rawValue: "generate.auto_retry_failed.retry")
    static let generateFailedTitle = L10nKey(rawValue: "generate.failed.title")
    static let generateFailedBody = L10nKey(rawValue: "generate.failed.body")
    static let generateFailedRetry = L10nKey(rawValue: "generate.failed.retry")
    static let generateFailedBack = L10nKey(rawValue: "generate.failed.back")
    // 结果页
    static let previewNavTitle = L10nKey(rawValue: "preview.nav_title")
    static let previewHint = L10nKey(rawValue: "preview.hint")
    static let previewSave = L10nKey(rawValue: "preview.save")
    static let previewShare = L10nKey(rawValue: "preview.share")
    static let previewAdjust = L10nKey(rawValue: "preview.adjust")
    static let previewReshuffle = L10nKey(rawValue: "preview.reshuffle")
    static let shortageResult = L10nKey(rawValue: "shortage.result")
    // 导出 / 保存 / 分享（文案 §4.9、§4.10、§5.3）
    static let exportSizeSection = L10nKey(rawValue: "export.size.section")
    static let exportSize4000 = L10nKey(rawValue: "export.size.4000")
    static let exportSize4000Desc = L10nKey(rawValue: "export.size.4000.desc")
    static let exportSize6000 = L10nKey(rawValue: "export.size.6000")
    static let exportSize6000Desc = L10nKey(rawValue: "export.size.6000.desc")
    static let exportDegraded = L10nKey(rawValue: "export.degraded")
    static let exportProgressTitle = L10nKey(rawValue: "export.progress.title")
    static let exportProgressHint = L10nKey(rawValue: "export.progress.hint")
    static let exportInterrupted = L10nKey(rawValue: "export.interrupted")
    static let exportRetry = L10nKey(rawValue: "export.retry")
    static let saveSuccessTitle = L10nKey(rawValue: "save.success.title")
    static let saveSuccessBody = L10nKey(rawValue: "save.success.body")
    static let saveSuccessDone = L10nKey(rawValue: "save.success.done")
    static let saveSuccessShare = L10nKey(rawValue: "save.success.share")
    static let shareSheetTitle = L10nKey(rawValue: "share.sheet_title")
    static let shareSuggestSave = L10nKey(rawValue: "share.suggest_save")
    static let saveDiskFullTitle = L10nKey(rawValue: "save.disk_full.title")
    static let saveDiskFullBody = L10nKey(rawValue: "save.disk_full.body")
    static let saveDiskFullOK = L10nKey(rawValue: "save.disk_full.ok")
    static let saveAddDeniedTitle = L10nKey(rawValue: "save.add_denied.title")
    static let saveAddDeniedBody = L10nKey(rawValue: "save.add_denied.body")
    static let saveAddDeniedSettings = L10nKey(rawValue: "save.add_denied.settings")
    static let saveAddDeniedShare = L10nKey(rawValue: "save.add_denied.share")
    static let saveFailed = L10nKey(rawValue: "save.failed")
    static let saveFailedRetry = L10nKey(rawValue: "save.failed.retry")
    // 空状态
    static let emptyNoPhotosTitle = L10nKey(rawValue: "empty.no_photos.title")
    static let emptyNoPhotosBody = L10nKey(rawValue: "empty.no_photos.body")
    static let emptyNoPhotosOK = L10nKey(rawValue: "empty.no_photos.ok")
    static let emptyNotDownloadedTitle = L10nKey(rawValue: "empty.not_downloaded.title")
    static let emptyNotDownloadedBody = L10nKey(rawValue: "empty.not_downloaded.body")
    static let emptyNotDownloadedRetry = L10nKey(rawValue: "empty.not_downloaded.retry")
    // 设置 / 关于
    static let settingsTitle = L10nKey(rawValue: "settings.title")
    static let settingsPerformance = L10nKey(rawValue: "settings.performance")
    static let settingsAbout = L10nKey(rawValue: "settings.about")
    static let aboutTitle = L10nKey(rawValue: "about.title")
    static let aboutBody = L10nKey(rawValue: "about.body")
    static let appDisplayName = L10nKey(rawValue: "app.display_name")
    static let commonCancel = L10nKey(rawValue: "common.cancel")
    static let commonDone = L10nKey(rawValue: "common.done")
    static let commonBack = L10nKey(rawValue: "common.back")
    static let commonOK = L10nKey(rawValue: "common.ok")
    static let commonClose = L10nKey(rawValue: "common.close")
    static let commonRetry = L10nKey(rawValue: "common.retry")

    /// 本包用到的全部 key（测试用）。
    static let allUsed: [L10nKey] = [
        onboarding1Title, onboarding1Body, onboarding1Next, onboarding2Title, onboarding2Body, onboarding2Next,
        onboarding3Title, onboarding3Body, onboarding3Start, onboarding3Allow,
        permissionUndeterminedTitle, permissionUndeterminedBody, permissionUndeterminedPrimary, permissionUndeterminedSecondary,
        limitedTitle, limitedBody, limitedPrimary, limitedSecondary, limitedAllowAllLink,
        permissionDeniedTitle, permissionDeniedBody, permissionDeniedPrimary, permissionDeniedSecondary,
        targetNavTitle, targetPrompt, targetChoose, targetReplace, targetNext, targetUnreadable,
        sourceNavTitle, sourceListAll, sourceListAllowed, sourceListCount, sourceListCountPending, sourceListTitleFormat,
        sourceAlbumOption, sourceAlbumOptionDesc, sourceAlbumListTitle, sourceAlbumItemCount, sourceAlbumUnreadable,
        sourceAddPhotos, sourceNext, sourceExcludedLowRes,
        densitySection, densityCoarse, densityCoarseDesc, densityMedium, densityMediumDesc, densityFine, densityFineDesc,
        overlaySection, overlayLeft, overlayRight, overlayHint,
        generateCTA, generatePrivacyHint, shortagePregenerate, shortagePregenerateContinue, shortagePregenerateBack,
        scanTitle, scanResume, scanProgress, scanFirstTimeHint, scanProgressiveReady, scanProgressiveHint, scanProgressiveCTA,
        scanCancel, scanCancelConfirmTitle, scanCancelConfirmBody, scanCancelConfirmStop, scanCancelConfirmContinue,
        scanSkippedUndownloaded, miscScanStopped,
        generateProgressTitle, generateProgressBody, generateProgressCancel, generateProgressChecking, generateCancelConfirmTitle,
        generateCancelConfirmConfirm, generateCancelConfirmContinue, generateAutoRetryFailed, generateAutoRetryFailedRetry,
        generateFailedTitle, generateFailedBody, generateFailedRetry, generateFailedBack,
        previewNavTitle, previewHint, previewSave, previewShare, previewAdjust, previewReshuffle, shortageResult,
        emptyNoPhotosTitle, emptyNoPhotosBody, emptyNoPhotosOK, emptyNotDownloadedTitle, emptyNotDownloadedBody, emptyNotDownloadedRetry,
        settingsTitle, settingsPerformance, settingsAbout, aboutTitle, aboutBody, appDisplayName,
        commonCancel, commonDone, commonBack, commonOK, commonClose, commonRetry,
        exportSizeSection, exportSize4000, exportSize4000Desc, exportSize6000, exportSize6000Desc, exportDegraded, exportProgressTitle, exportProgressHint, exportInterrupted, exportRetry, saveSuccessTitle, saveSuccessBody, saveSuccessDone, saveSuccessShare, shareSheetTitle, shareSuggestSave, saveDiskFullTitle, saveDiskFullBody, saveDiskFullOK, saveAddDeniedTitle, saveAddDeniedBody, saveAddDeniedSettings, saveAddDeniedShare, saveFailed, saveFailedRetry,
    ]
}

/// 带参数的文案（`%1$@` 占位符）：视图层用 `String(format: NSLocalizedString(key), args…)` 显示。
public struct LocalizedLine: Hashable, Sendable {
    public var key: L10nKey
    public var arguments: [String]
    public init(_ key: L10nKey, _ arguments: [String] = []) {
        self.key = key
        self.arguments = arguments
    }
}

/// 张数格式：千分位（「1,234 张」，见文案 §4.2 示例）。不依赖 Locale，Linux / iOS 结果一致。
public enum CountFormat {
    public static func grouped(_ n: Int) -> String {
        let digits = String(abs(n))
        var out = ""
        for (i, ch) in digits.reversed().enumerated() {
            if i > 0, i % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return (n < 0 ? "-" : "") + String(out.reversed())
    }
}
