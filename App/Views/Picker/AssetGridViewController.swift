import SwiftUI
import UIKit
import MosaicAppCore

// MARK: - 共用照片网格（photo-picker-v0.1 §2、§3；T4）
//
// UICollectionView + 流式布局，SwiftUI 里用 `AssetGridView`（UIViewControllerRepresentable）包一层。
// 只依赖 MosaicAppCore 的协议 `AssetGridDataSource` / `GridThumbnailLoading`，不引用 PhotoKit 适配层（T3）。
// 几何、缓存窗口、锚点换算、变化判定都是 MosaicAppCore 的纯逻辑（`AssetGridLayout` / `ThumbnailCacheWindow` /
// `AssetGridUpdatePlan`，Linux 单测），这里只做 UIKit 调用。⚠️ 盲写：Linux 只能 `swiftc -parse`。

/// 点选模式（§3）。
enum AssetGridSelectionMode: Sendable, Hashable {
    /// 只浏览，点了没反应。
    case none
    /// 点一张就回调给调用方（选图页进大图预览；来源页的模式由 T6 再定）。
    case single
}

/// 点选结果。
struct AssetGridSelection: Sendable, Hashable {
    var assetID: String
    var index: Int
}

/// 报给调用方的当前位置：顶部可见行的第一张照片 + 该格上边缘距可见区上边缘的偏移（pt，被遮住时为负）。
/// T5 直接存成 `BrowsePosition(album:anchorAssetID:anchorOffset:)`。
struct AssetGridAnchor: Sendable, Hashable {
    var album: SourceSelection
    var assetID: String
    var offset: Double
}

/// 让网格滚到某个位置（`BrowseRestoreResult.anchor` 的 index / offset）。`token` 变了才重新应用，
/// 同一个目标不会在每次 SwiftUI 更新时把用户拉回去。
struct AssetGridScrollTarget: Sendable, Hashable {
    var index: Int
    var offset: Double
    var token: Int

    init(index: Int, offset: Double, token: Int = 0) {
        self.index = index
        self.offset = offset
        self.token = token
    }
}

@MainActor
final class AssetGridViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate,
    UICollectionViewDataSourcePrefetching {
    typealias Loader = any GridThumbnailLoading<UIImage>

    private(set) var dataSource: any AssetGridDataSource
    let loader: Loader
    var selectionMode: AssetGridSelectionMode
    var onSelect: (@MainActor (AssetGridSelection) -> Void)?
    /// 滑动停下时报一次（位置没变不重复报）。
    var onAnchorChange: (@MainActor (AssetGridAnchor) -> Void)?

    private(set) var collectionView: UICollectionView?
    private let flow = UICollectionViewFlowLayout()
    private(set) var gridLayout: AssetGridLayout?

    /// 网格当前显示的格数。数据源先换结果再发通知（T0 约定），所以批量更新前后的数量要自己记。
    private var displayedCount: Int
    private var cacheWindow = ThumbnailCacheWindow()
    /// 缓存窗口里已 `startCaching` 的照片 ID（数据源变化后旧下标对不上 ID，靠它 stop）。
    private var cachedIDs = Set<String>()
    /// 预取回调额外 start 的照片 ID（不在缓存窗口里的）。
    private var prefetchedIDs = Set<String>()
    private var cachingPixelSize = 0
    private var speed = GridScrollSpeedMeter()
    private var pendingScroll: GridAnchor?
    /// 最近一次看到的锚点（带照片 ID，相册变化时用它保持位置）。
    private var visibleAnchor: (anchor: AssetGridAnchor, index: Int)?
    private var lastReportedAnchor: AssetGridAnchor?

    init(dataSource: any AssetGridDataSource, loader: Loader, selectionMode: AssetGridSelectionMode = .single) {
        self.dataSource = dataSource
        self.loader = loader
        self.selectionMode = selectionMode
        self.displayedCount = dataSource.count
        super.init(nibName: nil, bundle: nil)
        subscribe(dataSource)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持")
    }

    // MARK: 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        flow.scrollDirection = .vertical
        flow.minimumInteritemSpacing = CGFloat(AssetGridLayout.defaultSpacing)
        flow.minimumLineSpacing = CGFloat(AssetGridLayout.defaultSpacing)
        flow.sectionInset = .zero

        let cv = UICollectionView(frame: view.bounds, collectionViewLayout: flow)
        cv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cv.backgroundColor = .systemBackground
        cv.alwaysBounceVertical = true
        cv.register(AssetGridCell.self, forCellWithReuseIdentifier: AssetGridCell.reuseID)
        cv.dataSource = self
        cv.delegate = self
        cv.prefetchDataSource = self
        cv.isPrefetchingEnabled = true
        view.addSubview(cv)
        collectionView = cv

        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let cv = collectionView else { return }
        let inset = cv.adjustedContentInset
        let width = Double(cv.bounds.width - inset.left - inset.right)
        guard width > 0 else { return }
        let displayScale = Double(traitCollection.displayScale)
        let next = AssetGridLayout(containerWidth: width, scale: displayScale > 0 ? displayScale : 2)
        if next != gridLayout {
            // 列数 / 尺寸变了：按变化前的锚点恢复（§3：锚点不会因列数变化错位）。
            let keep = pendingScroll ?? currentGridAnchor()
            resetCaching()
            gridLayout = next
            cachingPixelSize = next.targetPixelSize
            flow.itemSize = CGSize(width: next.cellSide, height: next.cellSide)
            flow.invalidateLayout()
            pendingScroll = keep
        }
        if let target = pendingScroll {
            pendingScroll = nil
            apply(target)
        }
        updateCacheWindow()
        trackAnchor()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateCacheWindow()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        speed.stop()
        resetCaching()
    }

    @objc private func didEnterBackground() {
        speed.stop()
        resetCaching()
    }

    // MARK: 调用方接口

    /// 换数据源（切相簿）。不给 `anchor` 就回到顶部。
    func setDataSource(_ newSource: any AssetGridDataSource, scrollTo anchor: GridAnchor? = nil) {
        if newSource !== dataSource {
            dataSource.setChangeHandler(nil)
            resetCaching()
            speed.stop()
            dataSource = newSource
            displayedCount = newSource.count
            visibleAnchor = nil
            lastReportedAnchor = nil
            subscribe(newSource)
            collectionView?.reloadData()
        }
        scroll(to: anchor ?? GridAnchor(index: 0, offset: 0))
    }

    /// 按锚点精确设置 contentOffset：锚点格子上边缘距可见区上边缘 `offset` pt（`BrowsePosition` 语义）。
    /// 布局还没好（宽度为 0）时先记下，布局好了再滚。
    func scroll(to anchor: GridAnchor) {
        guard isViewLoaded, gridLayout != nil else {
            pendingScroll = anchor
            return
        }
        apply(anchor)
        updateCacheWindow()
    }

    /// 当前锚点（顶部可见行的第一张）。空相簿或还没布局时为 nil。
    func currentAnchor() -> AssetGridAnchor? {
        guard let a = currentGridAnchor(), a.index < dataSource.count else { return nil }
        return AssetGridAnchor(album: dataSource.album, assetID: dataSource.assetID(at: a.index), offset: a.offset)
    }

    // MARK: 位置

    private func currentGridAnchor() -> GridAnchor? {
        guard let cv = collectionView, let layout = gridLayout else { return nil }
        let top = Double(cv.contentOffset.y + cv.adjustedContentInset.top)
        return layout.anchor(visibleTop: top, count: displayedCount)
    }

    private func apply(_ anchor: GridAnchor) {
        guard let cv = collectionView, let layout = gridLayout else {
            pendingScroll = anchor
            return
        }
        cv.layoutIfNeeded()   // reloadData / invalidateLayout 之后先让 contentSize 就位
        let inset = cv.adjustedContentInset
        let y = layout.contentOffsetY(for: anchor, count: displayedCount, topInset: Double(inset.top),
                                      bottomInset: Double(inset.bottom), viewportHeight: Double(cv.bounds.height))
        cv.setContentOffset(CGPoint(x: -inset.left, y: CGFloat(y)), animated: false)
        trackAnchor()
    }

    private func trackAnchor() {
        guard let a = currentGridAnchor(), a.index < dataSource.count else {
            visibleAnchor = nil
            return
        }
        visibleAnchor = (AssetGridAnchor(album: dataSource.album, assetID: dataSource.assetID(at: a.index), offset: a.offset),
                         a.index)
    }

    private func reportAnchor() {
        guard let a = visibleAnchor?.anchor, a != lastReportedAnchor else { return }
        lastReportedAnchor = a
        onAnchorChange?(a)
    }

    // MARK: 相册变化

    private func subscribe(_ source: any AssetGridDataSource) {
        source.setChangeHandler { [weak self] change in
            self?.handle(change)
        }
    }

    private func handle(_ change: AssetGridChange) {
        let newCount = dataSource.count
        let onScreen = isViewLoaded && view.window != nil
        let plan = AssetGridUpdatePlan.plan(for: change, oldCount: displayedCount, newCount: newCount, isOnScreen: onScreen)
        // 变化前顶部那张照片（带 ID）。用户停在最顶上时不保持：新拍的照片应该直接露出来。
        let keep = visibleAnchor.flatMap { $0.index == 0 && $0.anchor.offset >= 0 ? nil : $0.anchor }
        // 下标已经变了，缓存窗口按 ID 整体 stop 再重算。
        resetCaching()

        switch plan {
        case .nothing:
            displayedCount = newCount
        case .reloadData:
            displayedCount = newCount
            collectionView?.reloadData()
        case let .batch(deletes, inserts, moves, reloads):
            guard let cv = collectionView else {
                displayedCount = newCount
                break
            }
            cv.performBatchUpdates({
                self.displayedCount = newCount
                cv.deleteItems(at: deletes.map { IndexPath(item: $0, section: 0) })
                cv.insertItems(at: inserts.map { IndexPath(item: $0, section: 0) })
                for m in moves {
                    cv.moveItem(at: IndexPath(item: m.from, section: 0), to: IndexPath(item: m.to, section: 0))
                }
            }, completion: { [weak self] _ in
                self?.reloadChanged(reloads)
            })
        }

        if let keep, keep.album == dataSource.album, let index = dataSource.index(ofAssetID: keep.assetID) {
            apply(GridAnchor(index: index, offset: keep.offset))
        } else {
            trackAnchor()
        }
        updateCacheWindow()
    }

    /// `changed` 在批量更新之后单独 reload（PhotoKit 的约定）。只重配可见的，不可见的下次出现时自然重配。
    private func reloadChanged(_ indices: [Int]) {
        guard let cv = collectionView else { return }
        let paths = indices.filter { $0 < displayedCount }.map { IndexPath(item: $0, section: 0) }
        let visible = Set(cv.indexPathsForVisibleItems)
        let toReload = paths.filter { visible.contains($0) }
        if !toReload.isEmpty { cv.reloadItems(at: toReload) }
    }

    // MARK: 缓存窗口（§2：可见区上下各一屏 start，两屏外 stop，快速滑动不扩大）

    private func updateCacheWindow() {
        guard let cv = collectionView, let layout = gridLayout else { return }
        let viewport = Double(cv.bounds.height)
        let visible = layout.visibleRange(visibleTop: Double(cv.contentOffset.y), viewportHeight: viewport,
                                          count: displayedCount)
        let u = cacheWindow.update(visible: visible, itemsPerScreen: layout.itemsPerScreen(viewportHeight: viewport),
                                   count: displayedCount, isFastScrolling: speed.isFast)
        let stopIDs = ids(in: u.stop).filter { cachedIDs.contains($0) }
        if !stopIDs.isEmpty {
            loader.stopCaching(assetIDs: stopIDs, targetPixelSize: cachingPixelSize)
            cachedIDs.subtract(stopIDs)
        }
        var startIDs: [String] = []
        for id in ids(in: u.start) where !cachedIDs.contains(id) {
            cachedIDs.insert(id)
            // 预取已经 start 过的不再重复 start，改记到窗口名下。
            if prefetchedIDs.remove(id) == nil { startIDs.append(id) }
        }
        if !startIDs.isEmpty {
            loader.startCaching(assetIDs: startIDs, targetPixelSize: cachingPixelSize)
        }
    }

    private func resetCaching() {
        _ = cacheWindow.reset()
        let all = Array(cachedIDs.union(prefetchedIDs))
        if !all.isEmpty { loader.stopCaching(assetIDs: all, targetPixelSize: cachingPixelSize) }
        cachedIDs.removeAll()
        prefetchedIDs.removeAll()
    }

    private func ids(in ranges: [Range<Int>]) -> [String] {
        let n = min(displayedCount, dataSource.count)
        return ranges.flatMap { r in r.clamped(to: 0..<n).map { dataSource.assetID(at: $0) } }
    }

    // MARK: UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let dequeued = collectionView.dequeueReusableCell(withReuseIdentifier: AssetGridCell.reuseID, for: indexPath)
        guard let cell = dequeued as? AssetGridCell else { return dequeued }
        guard indexPath.item < dataSource.count else {
            cell.showPlaceholder()
            return cell
        }
        cell.configure(assetID: dataSource.assetID(at: indexPath.item), isLive: dataSource.isLivePhoto(at: indexPath.item))
        requestThumbnail(for: cell)
        return cell
    }

    private func requestThumbnail(for cell: AssetGridCell) {
        guard let id = cell.assetID, let layout = gridLayout else { return }
        let requestID = loader.requestThumbnail(assetID: id, targetPixelSize: layout.targetPixelSize) { [weak cell] thumb in
            guard let cell, cell.assetID == id else { return }
            cell.show(thumb)
        }
        cell.track(requestID) { [weak self] in self?.loader.cancel($0) }
    }

    // MARK: UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        // 开了 cell 预取时，UIKit 可能不经 cellForItem 就把移出过的 cell 再显示：之前被取消的请求补发。
        guard let cell = cell as? AssetGridCell, cell.needsRequest else { return }
        requestThumbnail(for: cell)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        (cell as? AssetGridCell)?.cancelPendingRequest()
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        selectionMode != .none
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard selectionMode == .single, indexPath.item < dataSource.count else { return }
        onSelect?(AssetGridSelection(assetID: dataSource.assetID(at: indexPath.item), index: indexPath.item))
    }

    // MARK: UICollectionViewDataSourcePrefetching

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard !speed.isFast else { return }   // 快速滑动不扩大缓存
        let n = min(displayedCount, dataSource.count)
        var ids: [String] = []
        for p in indexPaths where p.item < n && !cacheWindow.cached.contains(p.item) {
            let id = dataSource.assetID(at: p.item)
            if !cachedIDs.contains(id), prefetchedIDs.insert(id).inserted { ids.append(id) }
        }
        if !ids.isEmpty { loader.startCaching(assetIDs: ids, targetPixelSize: cachingPixelSize) }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        let n = min(displayedCount, dataSource.count)
        var ids: [String] = []
        for p in indexPaths where p.item < n {
            let id = dataSource.assetID(at: p.item)
            if prefetchedIDs.remove(id) != nil { ids.append(id) }
        }
        if !ids.isEmpty { loader.stopCaching(assetIDs: ids, targetPixelSize: cachingPixelSize) }
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        _ = speed.sample(offsetY: Double(scrollView.contentOffset.y), time: CACurrentMediaTime(),
                         viewportHeight: Double(scrollView.bounds.height))
        updateCacheWindow()
        trackAnchor()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scrollSettled() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scrollSettled()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollSettled()
    }

    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
        scrollSettled()
    }

    private func scrollSettled() {
        speed.stop()
        updateCacheWindow()   // 停下来后窗口扩回 ±1 屏
        trackAnchor()
        reportAnchor()
    }
}

// MARK: - Cell

@MainActor
final class AssetGridCell: UICollectionViewCell {
    static let reuseID = "AssetGridCell"

    private let imageView = UIImageView()
    private let liveBadge = UIImageView(image: UIImage(systemName: "livephoto"))
    private(set) var assetID: String?
    private var requestID: GridThumbnailRequestID?
    private var cancelHandler: (@MainActor (GridThumbnailRequestID) -> Void)?
    private var hasFinalImage = false
    private var wasCancelled = false

    /// 移出时请求被取消、还没拿到正式图：再显示时要补发。
    var needsRequest: Bool { assetID != nil && wasCancelled && !hasFinalImage }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemFill   // 本机没有缩略图时就是这个占位（不提示，§5.2）
        contentView.clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        liveBadge.tintColor = .white
        liveBadge.contentMode = .scaleAspectFit
        liveBadge.layer.shadowColor = UIColor.black.cgColor
        liveBadge.layer.shadowOpacity = 0.4
        liveBadge.layer.shadowRadius = 1
        liveBadge.layer.shadowOffset = .zero
        liveBadge.isHidden = true
        liveBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(liveBadge)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            liveBadge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            liveBadge.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            liveBadge.widthAnchor.constraint(equalToConstant: 18),
            liveBadge.heightAnchor.constraint(equalToConstant: 18),
        ])
        isAccessibilityElement = true
        accessibilityTraits = [.image, .button]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) 不支持")
    }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.6 : 1 }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelPendingRequest()
        requestID = nil
        cancelHandler = nil
        assetID = nil
        imageView.image = nil
        liveBadge.isHidden = true
        hasFinalImage = false
        wasCancelled = false
    }

    func configure(assetID: String, isLive: Bool) {
        if self.assetID != assetID {
            cancelPendingRequest()
            imageView.image = nil
            hasFinalImage = false
        }
        self.assetID = assetID
        wasCancelled = false
        liveBadge.isHidden = !isLive
    }

    func showPlaceholder() {
        cancelPendingRequest()
        assetID = nil
        imageView.image = nil
        liveBadge.isHidden = true
    }

    /// 记下请求 id。加载器可能在 `requestThumbnail` 返回前就同步回调过（`.opportunistic` 的低清图），无妨。
    func track(_ id: GridThumbnailRequestID?, cancel: @escaping @MainActor (GridThumbnailRequestID) -> Void) {
        requestID = hasFinalImage ? nil : id
        cancelHandler = cancel
        wasCancelled = false
    }

    func show(_ thumb: GridThumbnail<UIImage>) {
        // nil = 本机没有：保留已有的图（低清也比空格子好），没有就是占位色。
        if let image = thumb.image { imageView.image = image }
        if !thumb.isDegraded {
            hasFinalImage = true
            requestID = nil
        }
    }

    func cancelPendingRequest() {
        guard let id = requestID, !hasFinalImage else { return }
        cancelHandler?(id)
        requestID = nil
        wasCancelled = true
    }
}

// MARK: - SwiftUI 包装

/// SwiftUI 里用的网格。数据源换了（`!==`）就整体切换；`loader` 只在创建时用一次。
struct AssetGridView: UIViewControllerRepresentable {
    var dataSource: any AssetGridDataSource
    var loader: any GridThumbnailLoading<UIImage>
    var selectionMode: AssetGridSelectionMode = .single
    /// 要滚到的位置；`token` 变了才应用。
    var scrollTarget: AssetGridScrollTarget?
    var onSelect: @MainActor (AssetGridSelection) -> Void = { _ in }
    var onAnchorChange: @MainActor (AssetGridAnchor) -> Void = { _ in }

    @MainActor
    final class Coordinator {
        var appliedTarget: AssetGridScrollTarget?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AssetGridViewController {
        let vc = AssetGridViewController(dataSource: dataSource, loader: loader, selectionMode: selectionMode)
        configure(vc, context: context)
        return vc
    }

    func updateUIViewController(_ vc: AssetGridViewController, context: Context) {
        if vc.dataSource !== dataSource {
            let target = scrollTarget.map { GridAnchor(index: $0.index, offset: $0.offset) }
            vc.setDataSource(dataSource, scrollTo: target)
            context.coordinator.appliedTarget = scrollTarget
        }
        configure(vc, context: context)
    }

    private func configure(_ vc: AssetGridViewController, context: Context) {
        vc.selectionMode = selectionMode
        vc.onSelect = onSelect
        vc.onAnchorChange = onAnchorChange
        if let t = scrollTarget, t != context.coordinator.appliedTarget {
            context.coordinator.appliedTarget = t
            vc.scroll(to: GridAnchor(index: t.index, offset: t.offset))
        }
    }
}
