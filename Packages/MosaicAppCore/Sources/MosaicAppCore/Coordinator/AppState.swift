import Foundation
import MosaicCore

/// 保存失败的分支（文案 §5.3，判断优先级：权限 > 空间 > 其他）。
public enum SaveFailure: Sendable, Hashable {
    case addDenied
    case diskFull
    case other

    public var titleKey: L10nKey {
        switch self {
        case .addDenied: return .saveAddDeniedTitle
        case .diskFull: return .saveDiskFullTitle
        case .other: return .saveFailed
        }
    }
    public var bodyKey: L10nKey? {
        switch self {
        case .addDenied: return .saveAddDeniedBody
        case .diskFull: return .saveDiskFullBody
        case .other: return nil
        }
    }
    public var primaryKey: L10nKey {
        switch self {
        case .addDenied: return .saveAddDeniedSettings
        case .diskFull: return .saveDiskFullOK
        case .other: return .saveFailedRetry
        }
    }
    /// 次按钮（只有权限被拒时有「分享」）。
    public var secondaryKey: L10nKey? { self == .addDenied ? .saveAddDeniedShare : nil }

    /// 写入相册失败后的分类：此刻 add-only 授权已不可用 → 权限；磁盘不足 → 空间；其余 → 其他。
    public static func classify(_ error: any Error, addOnlyAuthorization: PhotoAuthorization) -> SaveFailure {
        if addOnlyAuthorization == .denied || addOnlyAuthorization == .restricted { return .addDenied }
        if let e = error as? ExportError, e == .insufficientStorage { return .diskFull }
        if let e = error as? CocoaError, e.code == .fileWriteOutOfSpace { return .diskFull }
        return .other
    }
}

/// 导出用途。
public enum ExportPurpose: Sendable, Hashable {
    case save, share
}

/// 导出 / 保存 / 分享的状态（T8，文案 §4.9–4.10、§5.3）。
public enum ExportPhase: Sendable, Hashable {
    case idle
    case exporting(ExportPurpose, fraction: Double)
    /// 已写入系统相册（`save.success.*`）。
    case saved
    /// 文件已就绪，平台层弹分享面板；结束后调 `shareFinished()`。
    case sharing(URL)
    case failed(SaveFailure)
    /// 导出被后台宽限打断（`export.interrupted` + `export.retry`）。
    case interrupted

    public var isBusy: Bool {
        if case .exporting = self { return true }
        return false
    }
}

/// 需要平台层执行的系统动作（打开设置、受限选择器）。
public enum SystemAction: Sendable, Hashable {
    case openSettings
    case presentLimitedPicker
}

/// AppCoordinator 对外暴露的全部可观察状态（值类型；App 的 ObservableObject 只是转发它）。
public struct AppState: Sendable, Hashable {
    public var route: AppRoute = .onboarding
    public var onboarding = OnboardingFlow()
    public var authorization: PhotoAuthorization = .notDetermined
    /// 索引已从磁盘加载（加载在启动关键路径之外，评审 §3 / MF-4）。
    public var indexLoaded = false
    public var indexStatus = IndexStatus(assetTotal: nil, available: 0, pending: 0, unavailableLocal: 0, failed: 0,
                                         isScanning: false, wasInterrupted: false, hasCompletedInitialScan: false)
    public var scan = ScanFlow()
    public var albumRows: [SourceRow] = []
    public var flow: MainFlow
    /// 全库空状态（来源页内联显示）。
    public var emptyState: LibraryEmptyState?
    /// 点「开始拼图」被空状态拦下时弹出的页面。
    public var presentedEmptyState: LibraryEmptyState?
    public var transientNotice: L10nKey?
    public var showScanSheet = false
    public var export: ExportPhase = .idle
    /// 导出档位（默认超清）。
    public var exportTier: ExportTier = .default
    /// 每出一个新结果 +1（平台层据此重画预览）。
    public var resultRevision = 0
    /// 生成进度页的阶段（匹配 / 检查清晰度），决定正文文案。
    public var generationStage: GenerationStage = .matching
    /// 最近一次生成（含「换一种拼法」）在哪个来源里排除了多少张不够清楚的照片。
    public var lowResExclusion: LowResExclusion?
    /// 结果页提示「照片比较少…」（`shortage.pregenerate`）：生成前按已知数没到 200 的门槛、筛选后才不足 200 时，
    /// 生成前没机会提示，在结果页补一次。
    public var postFilterShortageNotice = false

    public init(initialSeed: UInt64) { flow = MainFlow(initialSeed: initialSeed) }

    public var access: SourceAccess {
        if case .main(let a) = route { return a }
        return .full
    }

    /// 来源页首项（可用张数已减去清晰度筛选排除的张数）。
    public var allPhotosRow: SourceRow { lowResAdjusted(SourceListLogic.allPhotosRow(access: access, status: indexStatus)) }
    /// 来源页相簿行（同上）。
    public var displayedAlbumRows: [SourceRow] { albumRows.map(lowResAdjusted) }

    /// 某来源已知不够清楚的张数（最近一次在该来源生成时得到；没生成过为 0）。
    public func knownLowResCount(for selection: SourceSelection) -> Int {
        guard let e = lowResExclusion, e.selection == selection else { return 0 }
        return e.count
    }

    private func lowResAdjusted(_ row: SourceRow) -> SourceRow {
        SourceListLogic.excludingLowRes(row, count: knownLowResCount(for: row.selection),
                                        scanComplete: SourceListLogic.isScanComplete(indexStatus))
    }

    /// 来源页提示「有 N 张照片手机上的版本不够清楚，没有用上」：只对当前所选来源、N > 0 时显示。
    public var sourceLowResLine: LocalizedLine? {
        guard let e = lowResExclusion, e.selection == flow.source.selection, e.count > 0 else { return nil }
        return LocalizedLine(.sourceExcludedLowRes, [CountFormat.grouped(e.count)])
    }

    /// 生成进度页正文。
    public var generationProgressBodyKey: L10nKey { generationStage.bodyKey }

    /// 生成进行中（含确认取消弹窗）。
    public var isGenerating: Bool { flow.generation.showsProgress }
}

/// 某个来源里因手机上版本不够清楚（< 256 px）而没用上的照片数（去重）。
public struct LowResExclusion: Sendable, Hashable {
    public var selection: SourceSelection
    public var count: Int
    public init(selection: SourceSelection, count: Int) {
        self.selection = selection
        self.count = count
    }
}
