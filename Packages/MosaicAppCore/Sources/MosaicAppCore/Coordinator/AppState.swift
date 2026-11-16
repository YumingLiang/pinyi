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
    public var exportSize: ExportSize = .standard
    /// 每出一个新结果 +1（平台层据此重画预览）。
    public var resultRevision = 0

    public init(initialSeed: UInt64) { flow = MainFlow(initialSeed: initialSeed) }

    public var access: SourceAccess {
        if case .main(let a) = route { return a }
        return .full
    }

    public var allPhotosRow: SourceRow { SourceListLogic.allPhotosRow(access: access, status: indexStatus) }

    /// 生成进行中（含确认取消弹窗）。
    public var isGenerating: Bool { flow.generation.showsProgress }
}
