import Foundation
import Photos
import MosaicAppCore

/// **唯一的取照片入口**（photo-picker-v0.1 §5.1；需求 v0.4 §4.8 第 4 条）。
///
/// 硬约束：隐藏照片任何地方都不出现。所以：
/// - 所有 `PHAsset.fetchAssets(with:)` / `fetchAssets(in:)` / `fetchAssets(withLocalIdentifiers:)` 以及
///   `fetchKeyAssets(in:)` 都必须用 `PhotoFetch.options(...)` 生成的选项，或直接调用下面的包装；**不允许 `options: nil`**。
/// - `includeHiddenAssets = false` 显式写死，不依赖系统默认值；调用方拿到选项后不得改它。
///   唯一例外：`classifyMissing`（只读元数据分隐藏 / 删除，不请求图像、不返回 PHAsset；脚本规则 2 / 2b 精确放行）。
/// - `includeAssetSourceTypes` 按场景显式传（见 `Sources`），不留默认。
/// - 调用方只可以再改 `fetchLimit`（例如判断空相簿用 1）。
///
/// T0 加入口；T3 已把现有调用点改走这里，并加了 CI 检查：`scripts/check-photo-fetch.sh`（`App/` 下除本文件和
/// InternalTools 外出现 `fetchAssets(` / `fetchKeyAssets(` 就失败）和 `AppTests/PhotoFetchTests.swift`
/// （断言 `includeHiddenAssets == false`，含 keyAssets 所用选项）。
/// ⚠️ 盲写（Linux 上无法编译验证，只做 `swiftc -parse`）。
enum PhotoFetch {
    /// 资产来源类型的场景预设。
    enum Sources {
        /// 「全部照片」、用户相簿、智能相簿、素材扫描：本机图库 + iTunes 同步，不混入共享相簿的照片（§1）。
        static let library: PHAssetSourceType = [.typeUserLibrary, .typeiTunesSynced]
        /// iCloud 共享相簿里取照片。
        static let cloudShared: PHAssetSourceType = [.typeCloudShared]
        /// 按 localIdentifier 取回已知照片（作品 / 缩略图 / 探测器）：来源都允许，因为 ID 可能来自共享相簿。
        static let any: PHAssetSourceType = [.typeUserLibrary, .typeiTunesSynced, .typeCloudShared]
    }

    /// 排序。
    enum Order {
        /// 不设 `sortDescriptors`（按 ID 取、只数个数时用）。
        case unspecified
        /// 创建时间升序（素材扫描：顺序稳定，diff / 断点续扫依赖它）。
        case oldestFirst
        /// 创建时间倒序（选图页 / 来源页网格，需求 4e）。
        case newestFirst
    }

    /// 生成取照片的选项。
    /// - Parameters:
    ///   - imagesOnly: true 时加 `mediaType == image` 谓词（本 App 所有场景都应为 true；false 只留给以后的视频需求）。
    ///   - sources: 资产来源，见 `Sources`，必须显式传。
    ///   - order: 排序。
    static func options(imagesOnly: Bool, sources: PHAssetSourceType, order: Order = .unspecified) -> PHFetchOptions {
        let o = PHFetchOptions()
        o.includeHiddenAssets = false          // 硬约束：写死，不靠默认值
        o.includeAllBurstAssets = false        // 连拍只要代表张（与「照片」App 一致）
        o.includeAssetSourceTypes = sources
        if imagesOnly {
            o.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        }
        switch order {
        case .unspecified: break
        case .oldestFirst: o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        case .newestFirst: o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        }
        return o
    }

    // MARK: 包装（CI 检查以后只允许 `fetchAssets(` / `fetchKeyAssets(` 出现在本文件）

    /// 「全部照片」。
    static func allImages(order: Order) -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(with: options(imagesOnly: true, sources: Sources.library, order: order))
    }

    /// 某个集合里的图片。共享相簿要传 `Sources.cloudShared`。
    static func images(in collection: PHAssetCollection, sources: PHAssetSourceType,
                       order: Order) -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(in: collection, options: options(imagesOnly: true, sources: sources, order: order))
    }

    /// 选图页 / 相簿列表里，某个集合取照片该用的来源：iCloud 共享相簿用 `Sources.cloudShared`，其余用 `Sources.library`
    /// （T3）。共享相簿里的照片来源类型是 `.typeCloudShared`，用 `.library` 去取会是 0 张。
    static func pickerSources(forSubtype subtype: PHAssetCollectionSubtype) -> PHAssetSourceType {
        subtype == .albumCloudShared ? Sources.cloudShared : Sources.library
    }

    /// 按 localIdentifier 取回图片。被隐藏 / 删除 / 受限访问移出的照片取不到（调用方当缺图处理）。
    /// 取回后请再用 `visibleImages(withLocalIdentifiers:)`，不要直接使用本结果里的 PHAsset：
    /// `fetchAssets(withLocalIdentifiers:)` 对 `includeHiddenAssets` 的行为不完全一致。
    static func images(withLocalIdentifiers ids: [String]) -> PHFetchResult<PHAsset> {
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: options(imagesOnly: true, sources: Sources.any))
    }

    /// 按 ID 取回后再滤掉 `isHidden`（双保险）。不用 `enumerateObjects` 闭包。
    /// 隐藏 / 删除 / 受限访问移出的照片不在结果里，调用方当缺图处理。
    static func visibleImages(withLocalIdentifiers ids: [String]) -> [PHAsset] {
        let result = images(withLocalIdentifiers: ids)
        guard result.count > 0 else { return [] }
        return VisibleAssetFilter.accepting(
            result.objects(at: IndexSet(integersIn: 0..<result.count)),
            isHidden: { $0.isHidden }
        )
    }

    /// 系统 PhotosPicker 选完后的兜底（#18 P1-a）：按 `itemIdentifier` 再取一次。取不到（隐藏 / 删除 / 受限未授权）
    /// 或 `isHidden` 都不能当目标图（`PickedTargetGate`）。
    /// 只回答可用 / 不可用，不区分原因（copy v1.6）。
    /// 走 `visibleImages`（#15 的 isHidden 双保险），不单独再滤一遍。
    static func isPickedAssetAvailable(_ id: String) -> Bool {
        !visibleImages(withLocalIdentifiers: [id]).isEmpty
    }

    /// 缺图分类（架构师 11-17 最终方案）：取不到的原照片是 hidden / deleted / unknown。
    ///
    /// ⚠️ **这是全 App 唯一一处 metadata-only 例外 `includeHiddenAssets = true`**（`scripts/check-photo-fetch.sh` 规则 2 只对这一行放行）：
    /// - 一次 `fetchAssets(withLocalIdentifiers:)`，只读「查不查得到」和 `isHidden`；**不请求任何图像**
    ///   （不碰 PHImageManager / 缩略图 / 资源），结果也不返回 `PHAsset`，隐藏照片不可能经这里流到任何界面或匹配；
    /// - 规则（`MissingPhotoClassifier`）：查得到且 isHidden → hidden；受限访问且查不到 → unknown；
    ///   完整权限且查不到 → deleted；其他 → unknown。
    /// 「不请求图像」的保证：规则 2b 要求放行行在本函数体内、且函数体里不出现任何取图 API（脚本自测有正反例）；
    /// 调用链上的计数测试在 MosaicAppCore（`MissingCellFillTests`：分类时取图 0 次）。
    static func classifyMissing(_ ids: Set<String>) -> [String: MissingReason] {
        let access: LibraryAccess
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: access = .full
        case .limited: access = .limited
        default: access = .none
        }
        return MissingPhotoClassifier.classify(ids, access: access) { identifiers in
            let o = PHFetchOptions()
            o.includeHiddenAssets = true   // photo-fetch: hidden-metadata-only 只读元数据分类隐藏/删除，不请求图像（唯一例外）
            o.includeAssetSourceTypes = Sources.any
            let r = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: o)
            var found: [String: Bool] = [:]
            r.enumerateObjects { a, _, _ in found[a.localIdentifier] = a.isHidden }
            return found
        }
    }

    /// 集合的代表照片（封面）。选项同样走 `options`（写死 `includeHiddenAssets = false`），不允许 `options: nil`。
    /// 代表张若被隐藏，结果可能为空；PhotoKit 本身返回可选（取不到时为 nil），调用方按无封面处理。共享相簿要传 `Sources.cloudShared`。
    static func keyAssets(in collection: PHAssetCollection,
                          sources: PHAssetSourceType) -> PHFetchResult<PHAsset>? {
        PHAsset.fetchKeyAssets(in: collection,
                               options: options(imagesOnly: true, sources: sources, order: .unspecified))
    }

    /// 选图页 / 相簿列表取封面：来源按 `pickerSources(forSubtype:)` 自动选。
    static func keyAssets(in collection: PHAssetCollection) -> PHFetchResult<PHAsset>? {
        keyAssets(in: collection, sources: pickerSources(forSubtype: collection.assetCollectionSubtype))
    }

    // MARK: isHidden 后置过滤（相簿多选 PR 的合并条件；quick-start v1.0 §0 硬规则 1、§4.8）
    //
    // `includeHiddenAssets = false` 是第一道；按集合取回后再按 `isHidden` 滤一遍是第二道（`VisibleAssetFilter`，
    // 与 #15 按 ID 取图同一个入口）。App 里按集合取图 / 封面一律用下面这些；直接用上面的 `allImages` /
    // `images(in:)` / `keyAssets` 的只允许本文件和 `PhotoKitAssetGrid.swift`（网格用 `VisibleIndexMap` 跳过隐藏项），
    // 由 scripts/check-photo-fetch.sh 检查。

    /// 一批 PHAsset 里滤掉 `isHidden`，保持顺序。
    static func visible(_ assets: [PHAsset]) -> [PHAsset] {
        VisibleAssetFilter.accepting(assets, isHidden: { $0.isHidden })
    }

    /// fetch result 的一段（素材扫描分批取元数据用），滤掉 `isHidden`。
    static func visibleObjects(_ result: PHFetchResult<PHAsset>, in range: Range<Int>) -> [PHAsset] {
        let lo = max(0, range.lowerBound), hi = min(result.count, range.upperBound)
        guard lo < hi else { return [] }
        return visible(result.objects(at: IndexSet(integersIn: lo..<hi)))
    }

    /// 「全部照片」的可见张数（逐个看 `isHidden`）。
    static func visibleAllImagesCount() -> Int {
        let r = allImages(order: .unspecified)
        return visibleObjects(r, in: 0..<r.count).count
    }

    /// 某个集合里的可见图片（已滤 `isHidden`），按 `order`。
    static func visibleImages(in collection: PHAssetCollection, sources: PHAssetSourceType,
                              order: Order = .unspecified) -> [PHAsset] {
        let r = images(in: collection, sources: sources, order: order)
        return visibleObjects(r, in: 0..<r.count)
    }

    /// 集合的代表照片（封面），滤掉 `isHidden`；一张都不剩时调用方按无封面处理。
    static func visibleKeyAssets(in collection: PHAssetCollection) -> [PHAsset] {
        guard let r = keyAssets(in: collection), r.count > 0 else { return [] }
        return visibleObjects(r, in: 0..<r.count)
    }
}

extension SmartAlbumKind {
    /// 白名单 → PhotoKit 子类型。反过来映射时，白名单外的子类型（含 `.smartAlbumAllHidden`）一律丢弃。
    var photoKitSubtype: PHAssetCollectionSubtype {
        switch self {
        case .favorites: return .smartAlbumFavorites
        case .recentlyAdded: return .smartAlbumRecentlyAdded
        case .selfPortraits: return .smartAlbumSelfPortraits
        case .depthEffect: return .smartAlbumDepthEffect
        case .livePhotos: return .smartAlbumLivePhotos
        case .panoramas: return .smartAlbumPanoramas
        case .screenshots: return .smartAlbumScreenshots
        case .bursts: return .smartAlbumBursts
        }
    }

    /// PhotoKit 子类型 → 白名单；不在白名单里（例如 `.smartAlbumAllHidden`）返回 nil。
    init?(photoKitSubtype: PHAssetCollectionSubtype) {
        guard let k = SmartAlbumKind.allCases.first(where: { $0.photoKitSubtype == photoKitSubtype }) else { return nil }
        self = k
    }
}
