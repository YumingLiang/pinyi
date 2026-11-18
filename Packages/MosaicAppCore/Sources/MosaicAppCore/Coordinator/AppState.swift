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
    /// 相簿列表至少加载完一次（§2f 补充 3）。之前来源是相簿时，张数显示「加载中」，不显示旧数字。
    public var albumsLoaded = false
    /// 「开始拼图」在等相簿列表加载完（§2f 补充 3）：按钮短暂显示加载状态。
    public var isWaitingForAlbums = false
    /// 上次选的相簿名（偏好里记的），相簿列表加载完之前素材标签先显示它们（§2f 补充 3a）。
    public var rememberedAlbumNames: [String: String] = [:]
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
    /// 有没有结果（`AppCoordinator.product != nil`）。变成 false 时平台层释放预览位图（约 48 MB）。
    public var hasResult = false
    /// 未保存提示（`quick.unsaved.*`）是因为哪种离开方式弹的；nil = 没弹。当前结果没存进作品就弹（导出过不算存过，
    /// hd-export B10-4）；存过但只改了叠加强度还没存也弹，标题换成 `quick.unsaved.update_title`（B10-11）。
    public var unsavedPrompt: UnsavedResultPrompt?
    /// 弹着的提示是不是「存过但强度改了」那种（标题 `quick.unsaved.update_title`，「保存」= 更新原作品）。
    public var unsavedPromptIsUpdate = false
    /// 未保存提示标题 key。
    public var unsavedPromptTitle: L10nKey { unsavedPromptIsUpdate ? .quickUnsavedUpdateTitle : .quickUnsavedTitle }
    /// 未保存提示里点了「保存」，正在存。
    public var isSavingBeforeLeaving = false
    /// 系统选择器选的照片用不了（`picker.unavailable`，copy v1.6）：弹着提示。不记原因。
    public var showsPickerUnavailable = false
    /// 平台层：重新打开这张作品的查看页（「再拼一张」从作品查看页发起、在选图页取消时，回到发起页）。token 每次 +1。
    public var reopenWorkRequest: WorkReopenRequest?
    /// 「换一张」时 +1：平台层看到变化就重新打开系统选择器。
    public var targetPickerReopenRequest = 0
    /// 提示里是否显示「增加可用照片」：只看整个 App 的授权是不是受限访问，不看这张照片。
    public var pickerUnavailableShowsAddAccess: Bool { authorization == .limited }

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

    /// 确认页素材摘要「素材：{name} · {count} 张」（需求 v1.0 §2b）。`allPhotosTitle`：平台层把
    /// 「全部照片 / 已允许访问的照片」本地化后传进来（逻辑层不产出中文）。张数与来源页该行显示的一致。
    /// 相簿名：列表里有就用列表的，没有（还没加载完）用上次记下的。
    func albumName(_ id: String) -> String {
        albumRows.first { $0.albumID == id }?.albumTitle ?? rememberedAlbumNames[id] ?? ""
    }

    /// 来源是相簿、张数还没算出来（启动时相簿列表未加载完，或去重合计在算）：显示加载中，不显示旧数字 / 0（§2f 补充 3）。
    public var isMaterialCountLoading: Bool {
        switch flow.source.selection {
        case .allPhotos: return false
        case .album: return !albumsLoaded
        case .albums: return !albumsLoaded || flow.source.selectionUnion == nil
        }
    }

    public func materialSummary(allPhotosTitle: String) -> LocalizedLine {
        switch flow.source.selection {
        case .allPhotos:
            return LocalizedLine(.quickSourceSummary, [allPhotosTitle, CountFormat.grouped(allPhotosRow.count)])
        case .album(let id):
            // 相簿列表加载完之前（§2f 补充 3a）：先显示上次的相簿名，张数位置「正在统计…」，不显示旧数字。
            guard albumsLoaded, let row = displayedAlbumRows.first(where: { $0.selection == flow.source.selection }) else {
                return MultiAlbumText.materialSummary(names: [albumName(id)], count: nil)
            }
            return LocalizedLine(.quickSourceSummary, [row.albumTitle ?? albumName(id), CountFormat.grouped(row.count)])
        case .albums(let ids):
            // §2f / 验收 12：相簿名按勾选顺序；张数是去重合计（还没算出来 =「正在统计…」）。
            return MultiAlbumText.materialSummary(names: ids.map(albumName),
                                                  count: isMaterialCountLoading ? nil : flow.source.selectionUnion?.count)
        }
    }

    /// 预览页「再拼一张」能不能点：停在结果页、没在生成、没在导出、没在弹未保存提示 / 保存中。
    public var canStartNewMosaic: Bool {
        guard hasResult, flow.step == .result, !flow.isQuickAgain, !isGenerating, !export.isBusy,
              unsavedPrompt == nil, !isSavingBeforeLeaving else { return false }
        if case .result = flow.generation.phase { return true }
        return false
    }
}

/// 未保存提示是因为哪种离开方式弹出来的（需求 v1.0 §2e）。
public enum UnsavedResultPrompt: Sendable, Hashable {
    /// 预览页「再拼一张」。
    case startNew
    /// 预览页返回首页等会丢掉当前结果的离开方式。
    case leaveResult
    /// 「再调一调」途中（设置页）发起「再拼一张」（经作品查看页入口，验收 7a）：继续 = 直接去选目标图（没有可返回的预览页）。
    case startNewFromAdjust
}

/// 某个来源里因手机上版本不够清楚（< 256 px）而没用上的照片（去重）。
/// 存 ID 而不是只存张数：相册变化后可以丢掉已经不在该来源里的，及时重算来源页张数。
public struct LowResExclusion: Sendable, Hashable {
    public var selection: SourceSelection
    public var assetIDs: Set<String>
    public var count: Int { assetIDs.count }
    public init(selection: SourceSelection, assetIDs: Set<String>) {
        self.selection = selection
        self.assetIDs = assetIDs
    }

    /// 只保留仍在该来源里的 ID，重算张数。
    public func pruned(to sourceAssetIDs: Set<String>) -> LowResExclusion {
        LowResExclusion(selection: selection, assetIDs: assetIDs.intersection(sourceAssetIDs))
    }
}

/// 「再拼一张」从哪一页发起（选图提示「取消」时回到这一页，copy v1.6）。
public enum QuickStartOrigin: Sendable, Hashable {
    /// 预览页（结果页）的「再拼一张」。
    case preview
    /// 作品查看页的「再拼一张」。
    case work(id: WorkID)
    /// 「再调一调」设置页（没有作品 ID 的旧调用；从作品查看页发起的一律记 `.work(id:)`，产品 03:16 口径）。
    case adjust
}

/// 平台层重新打开作品查看页的请求。
public struct WorkReopenRequest: Sendable, Hashable {
    public var workID: WorkID
    public var token: Int
    public init(workID: WorkID, token: Int) { self.workID = workID; self.token = token }

    /// 压在主流程上的页（自下而上）：和平时一样「作品列表 → 查看页」（产品 03:25 第 3 条）。
    /// 从查看页返回到作品列表，再返回才回主流程（主流程停在发起前那一页，例如「再调一调」设置页，原目标图和「完成」都在）。
    public var routes: [WorksRoute] { [.list, .detail(workID)] }
}

/// 我的作品的导航页。
public enum WorksRoute: Sendable, Hashable {
    case list
    case detail(WorkID)
}
