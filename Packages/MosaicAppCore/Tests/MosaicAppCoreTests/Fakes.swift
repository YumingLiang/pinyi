import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// 线程安全的小盒子（G-1：基于 `LockedState`，Sendable 由编译器检查）。
final class Locked<T: Sendable>: Sendable {
    private let state: LockedState<T>
    init(_ v: T) { state = LockedState(v) }
    func get() -> T { state.get() }
    func set(_ v: T) { state.set(v) }
    @discardableResult
    func update<R: Sendable>(_ f: (inout T) -> R) -> R { state.withLock(f) }
}

/// 稳定哈希（FNV-1a），不用 `hashValue`（每次进程随机）。
func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
    return h
}

/// 由 id 确定的颜色（让不同资产的特征可区分、可复查）。
func color(for id: String) -> (UInt8, UInt8, UInt8) {
    let h = stableHash(id)
    return (UInt8(truncatingIfNeeded: h), UInt8(truncatingIfNeeded: h >> 8), UInt8(truncatingIfNeeded: h >> 16))
}

/// 假相册。
final class FakePhotoLibrary: PhotoLibraryClient, Sendable {
    struct State: Sendable {
        var auth: PhotoAuthorization = .authorized
        var authAfterRequest: PhotoAuthorization = .authorized
        var assets: [AssetMetadata] = []
        var albums: [AlbumInfo] = []
        var albumMembers: [String: [String]] = [:]
        var metadataCalls = 0
        // PhotoLibraryClient（G-3）
        var addOnlyAuth: PhotoAuthorization = .authorized
        var addOnlyAfterRequest: PhotoAuthorization = .authorized
        var addOnlyRequests = 0
        var saveError: SaveErrorKind?
        var savedFiles: [String] = []
    }
    enum SaveErrorKind: Sendable { case generic, outOfSpace }
    let state = Locked(State())

    init(assetCount: Int = 0, prefix: String = "a") {
        state.update { s in
            s.assets = (0..<assetCount).map { AssetMetadata(id: "\(prefix)\($0)", modificationDate: Date(timeIntervalSince1970: 1000), pixelWidth: 4032, pixelHeight: 3024) }
        }
    }

    func authorizationStatus() -> PhotoAuthorization { state.get().auth }
    func requestAuthorization() async -> PhotoAuthorization {
        state.update { s in s.auth = s.authAfterRequest; return s.auth }
    }
    func assetCount() async -> Int { state.get().assets.count }
    func assetMetadata(in range: Range<Int>) async -> [AssetMetadata] {
        state.update { s in
            s.metadataCalls += 1
            let lo = max(0, range.lowerBound), hi = min(s.assets.count, range.upperBound)
            return lo < hi ? Array(s.assets[lo..<hi]) : []
        }
    }
    func albums() async -> [AlbumInfo] { state.get().albums }
    func assetIDs(inAlbum albumID: String) async throws -> [String] {
        guard let m = state.get().albumMembers[albumID] else { throw CocoaLikeError.notFound }
        return m
    }

    enum CocoaLikeError: Error { case notFound, saveFailed }

    func addOnlyAuthorizationStatus() -> PhotoAuthorization { state.get().addOnlyAuth }
    func requestAddOnlyAuthorization() async -> PhotoAuthorization {
        state.update { s in s.addOnlyRequests += 1; s.addOnlyAuth = s.addOnlyAfterRequest; return s.addOnlyAuth }
    }
    func saveImageToLibrary(fileURL: URL) async throws {
        let err = state.update { s -> SaveErrorKind? in
            if s.saveError == nil { s.savedFiles.append(fileURL.lastPathComponent) }
            return s.saveError
        }
        switch err {
        case .generic?: throw CocoaLikeError.saveFailed
        case .outOfSpace?: throw CocoaError(.fileWriteOutOfSpace)
        case nil: break
        }
    }
    func setAuth(_ a: PhotoAuthorization) { state.update { $0.auth = a } }

    // 便捷修改
    func delete(_ ids: Set<String>) { state.update { $0.assets.removeAll { ids.contains($0.id) } } }
    func modify(_ ids: Set<String>) {
        state.update { s in
            for i in s.assets.indices where ids.contains(s.assets[i].id) {
                s.assets[i].modificationDate = Date(timeIntervalSince1970: 5000)
            }
        }
    }
    func add(_ ids: [String]) {
        state.update { s in
            s.assets += ids.map { AssetMetadata(id: $0, modificationDate: Date(timeIntervalSince1970: 2000), pixelWidth: 3000, pixelHeight: 4000) }
        }
    }
    func setAlbum(_ id: String, title: String, members: [String]) {
        state.update { s in
            s.albums.removeAll { $0.id == id }
            s.albums.append(AlbumInfo(id: id, title: title, assetCount: members.count))
            s.albumMembers[id] = members
        }
    }
}

/// 假缩略图来源：纯色 8×8 图；可指定"未下载" / "失败"的 id；记录最大并发；可在第 N 次请求时执行钩子（例如取消）。
final class FakeThumbnails: ThumbnailProviding, Sendable {
    struct State: Sendable {
        var unavailable: Set<String> = []
        var failing: Set<String> = []
        var colorOverride: [String: (UInt8, UInt8, UInt8)] = [:]
        var inFlight = 0
        var maxInFlight = 0
        var requests = 0
        var requestedOptions: [ThumbnailRequest] = []
        var cachingStarted = 0
    }
    let state = Locked(State())
    let delayNanos: UInt64
    let onRequest: (@Sendable (Int) -> Void)?

    init(delayNanos: UInt64 = 0, onRequest: (@Sendable (Int) -> Void)? = nil) {
        self.delayNanos = delayNanos
        self.onRequest = onRequest
    }

    func thumbnail(for assetID: String, request: ThumbnailRequest) async -> ThumbnailResult {
        let n = state.update { s -> Int in
            s.inFlight += 1
            s.maxInFlight = max(s.maxInFlight, s.inFlight)
            s.requests += 1
            if s.requestedOptions.count < 4 { s.requestedOptions.append(request) }
            return s.requests
        }
        onRequest?(n)
        if delayNanos > 0 { try? await Task.sleep(nanoseconds: delayNanos) }
        defer { state.update { $0.inFlight -= 1 } }
        let s = state.get()
        if s.unavailable.contains(assetID) { return .unavailableLocal }
        if s.failing.contains(assetID) { return .failed }
        let c = s.colorOverride[assetID] ?? color(for: assetID)
        return .image(try! PixelBuffer.solid(width: 8, height: 8, red: c.0, green: c.1, blue: c.2))
    }

    func startCaching(_ assetIDs: [String], request: ThumbnailRequest) async {
        state.update { $0.cachingStarted += 1 }
    }
}

/// 可手动推进的时钟。
final class ManualClock: Sendable {
    let t = Locked(0.0)
    func advance(_ d: Double) { t.update { $0 += d } }
    var clock: MonotonicClock { MonotonicClock { [t] in t.get() } }
}

func makeTempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("mosaicappcore-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func smallConfig(batch: Int = 16, concurrency: Int = 8, minRows: Int = 1) -> PhotoIndex.Configuration {
    var c = PhotoIndex.Configuration()
    c.batchSize = batch
    c.maxConcurrentRequests = concurrency
    c.minRowsPerCommit = minRows
    c.minRowsForTimedCommit = minRows
    c.commitDutyFactor = 0   // 测试里每批都按行数规则判断，不受真实耗时影响
    return c
}

/// 清单当前指向的 features 文件（MF-1：文件名带 epoch）。
func currentFeaturesURL(_ dir: URL) throws -> URL {
    let name = try XCTUnwrap(JSONIndexStore(directory: dir, backupExclusion: NoBackupExclusion()).currentFeaturesFile())
    return dir.appendingPathComponent(name)
}

/// 目录里所有 features 文件名（排序）。
func featureFiles(in dir: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        .filter { $0 == "features.bin" || ($0.hasPrefix("features-") && $0.hasSuffix(".bin")) }.sorted()
}

/// 什么也不做的排除备份实现。
struct NoBackupExclusion: BackupExclusionApplying {
    func excludeFromBackup(_ url: URL) throws {}
}
