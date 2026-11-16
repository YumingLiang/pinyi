import Foundation
import XCTest
import MosaicCore
@testable import MosaicAppCore

/// MF-1（压缩提交中途被杀不得错配）、MF-3（存储协议）、QA B-32（真实 v1 文件重建）。
final class IndexStoreTests: XCTestCase {
    var dirs: [URL] = []
    override func tearDown() { for d in dirs { try? FileManager.default.removeItem(at: d) }; dirs = [] }
    func tempDir() -> URL { let d = makeTempDir(); dirs.append(d); return d }

    struct Killed: Error {}

    /// 对每个资产：快照里该行的颜色必须等于该资产缩略图的颜色（行号 ↔ 资产 0 错配）。
    func mismatches(_ idx: PhotoIndex) async throws -> (usable: Int, mismatched: Int) {
        let snap = try await idx.snapshot(for: .allPhotos)
        let t = snap.library.table
        var usable = 0, bad = 0
        for (row, id) in snap.assetIDsByRow.enumerated() {
            guard let id, !t.flags[row].contains(.deleted) else { continue }
            usable += 1
            let c = color(for: id)
            let expected = try FeatureExtractor().extract(from: try PixelBuffer.solid(width: 8, height: 8, red: c.0, green: c.1, blue: c.2))
            if t.record(row).vector != expected.vector { bad += 1 }
        }
        return (usable, bad)
    }

    /// MF-1 探针（评审 §1 `ZZProbeCompactionCrash`）：30 张 → 删 10 张 → 压缩提交在每个步骤之后被杀 → 重新加载：
    /// 0 错配；被杀在清单 rename 之前 ⇒ 读到旧的一对（压缩前行号 + 旧文件），之后 ⇒ 新的一对。
    func testMF1CompactionCommitKilledAtEveryStepNeverMismatches() async throws {
        for step in IndexCommitStep.allCases {
            let dir = tempDir()
            let lib = FakePhotoLibrary(assetCount: 30)
            let thumbs = FakeThumbnails()
            let idx = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: NoBackupExclusion(),
                                 configuration: smallConfig())
            await idx.load()
            _ = try await idx.synchronize()
            let before = featureFiles(in: dir)
            XCTAssertEqual(before.count, 1)

            lib.delete(Set((0..<10).map { "a\($0 * 3)" }))
            lib.add(["z1"])   // 有待扫描项才会走到扫描尾部的压缩
            // 扫描期间的提交依次是：scanInProgress 标记、最后一批 flush、压缩后提交。只杀第 3 次（压缩后那次）。
            let armed = Locked(false)
            let commitNo = Locked(0)
            let killing = JSONIndexStore(directory: dir, backupExclusion: NoBackupExclusion(), faultAfter: { s in
                guard armed.get() else { return }
                if s == .featuresWritten { commitNo.update { $0 += 1 } }
                if commitNo.get() == 3, s == step { throw Killed() }
            })
            let idx2 = PhotoIndex(store: killing, library: lib, thumbnails: thumbs, configuration: smallConfig())
            await idx2.load()
            // 只让"压缩后的那次提交"被杀：先 diff（tombstone 提交正常），再在扫描尾部压缩提交时被杀
            _ = await idx2.applyFullDiff()
            armed.set(true)
            do {
                _ = try await idx2.scanPending()
                XCTFail("\(step): 应在压缩提交时被杀")
            } catch is Killed {}

            // "重启"
            let idx3 = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: NoBackupExclusion(),
                                  configuration: smallConfig())
            let outcome = await idx3.load()
            let (usable, bad) = try await mismatches(idx3)
            XCTAssertEqual(bad, 0, "\(step): 行号与资产错配 \(bad)/\(usable)")
            XCTAssertEqual(featureFiles(in: dir).count, 1, "\(step): 孤儿 features 文件应在加载时删除 \(featureFiles(in: dir))")
            let loaded = await idx3.table
            if step == .featuresWritten {
                XCTAssertEqual(outcome, .intact, "清单未换：旧的一对完好")
                XCTAssertGreaterThan(loaded.tombstoneCount, 0, "旧的一对是压缩前的（有 tombstone）")
            } else {
                XCTAssertEqual(loaded.tombstoneCount, 0, "\(step): 新的一对是压缩后的")
                XCTAssertEqual(loaded.count, 21)
            }
            // 再同步一轮后状态完全正确
            _ = try await idx3.synchronize()
            let st = await idx3.status()
            XCTAssertEqual(st.available, 21, "\(step)")
            let after = try await mismatches(idx3)
            XCTAssertEqual(after.mismatched, 0)
            XCTAssertEqual(after.usable, 21)
        }
    }

    /// MF-1：评审探针的原样复现——用压缩前的 index.json 覆盖回去。新布局下它指向的旧 features 文件已删，
    /// 结果是"全部回到待扫描"（0 错配），而不是旧布局的 11/11 错配。
    func testMF1StaleManifestNeverPairsWithNewFeatures() async throws {
        let dir = tempDir()
        let lib = FakePhotoLibrary(assetCount: 30)
        let thumbs = FakeThumbnails()
        let idx = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: NoBackupExclusion(),
                             configuration: smallConfig())
        await idx.load()
        _ = try await idx.synchronize()
        let staleManifest = try Data(contentsOf: dir.appendingPathComponent("index.json"))
        lib.delete(Set((0..<10).map { "a\($0 * 3)" }))
        lib.add(["z1"])
        let s = try await idx.synchronize()
        XCTAssertTrue(s.compacted)
        try staleManifest.write(to: dir.appendingPathComponent("index.json"))

        let idx2 = PhotoIndex(directory: dir, library: lib, thumbnails: thumbs, backupExclusion: NoBackupExclusion(),
                              configuration: smallConfig())
        let o = await idx2.load()
        guard case .recoveredPrefix = o else { return XCTFail("\(o)") }
        let (_, bad) = try await mismatches(idx2)
        XCTAssertEqual(bad, 0)
        _ = try await idx2.synchronize()
        let after = try await mismatches(idx2)
        XCTAssertEqual(after.usable, 21)
        XCTAssertEqual(after.mismatched, 0)
    }

    /// MF-1：每次提交写新 epoch，清单 rename 成功后才删旧文件；清单记录文件名，formatVersion 2。
    func testMF1CommitWritesNewEpochAndManifestRecordsFilename() async throws {
        let dir = tempDir()
        let store = JSONIndexStore(directory: dir, backupExclusion: NoBackupExclusion())
        let spec = FeatureExtractor().spec
        try store.prepare()
        var m = IndexManifest(featureVersion: spec.featureVersion)
        m.entries["x"] = IndexEntry(modificationDate: Date(timeIntervalSinceReferenceDate: 12.345678), status: .ok, row: 0)
        let rec = try FeatureExtractor().extract(from: try PixelBuffer.solid(width: 8, height: 8, red: 10, green: 20, blue: 30))
        try store.commit(table: FeatureTable(records: [rec], spec: spec), manifest: m)
        XCTAssertEqual(featureFiles(in: dir), ["features-1.bin"])
        try store.commit(table: FeatureTable(records: [rec, rec], spec: spec), manifest: m)
        XCTAssertEqual(featureFiles(in: dir), ["features-2.bin"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("index.json"))) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 2)
        XCTAssertEqual(json["featuresFile"] as? String, "features-2.bin")
        XCTAssertNotNil(json["entries"] as? [Any], "数组行格式")

        guard case .loaded(let stored) = store.load(spec: spec) else { return XCTFail() }
        XCTAssertEqual(stored.table.count, 2)
        XCTAssertEqual(stored.manifest.entries["x"]?.modificationDate, Date(timeIntervalSinceReferenceDate: 12.345678),
                       "小数秒日期精确往返（R19）")
    }

    /// 清单 rename 之前被杀：新文件是孤儿，旧的一对仍可读；下次加载删掉孤儿。
    func testMF1KilledBeforeManifestKeepsOldPairAndRemovesOrphan() throws {
        let dir = tempDir()
        let spec = FeatureExtractor().spec
        let ok = JSONIndexStore(directory: dir, backupExclusion: NoBackupExclusion())
        try ok.prepare()
        let rec = try FeatureExtractor().extract(from: try PixelBuffer.solid(width: 8, height: 8, red: 1, green: 2, blue: 3))
        var m = IndexManifest(featureVersion: spec.featureVersion)
        m.entries["a"] = IndexEntry(modificationDate: nil, status: .ok, row: 0)
        try ok.commit(table: FeatureTable(records: [rec], spec: spec), manifest: m)
        let killing = JSONIndexStore(directory: dir, backupExclusion: NoBackupExclusion(), faultAfter: { s in
            if s == .featuresWritten { throw Killed() }
        })
        var m2 = m
        m2.entries["b"] = IndexEntry(modificationDate: nil, status: .ok, row: 1)
        XCTAssertThrowsError(try killing.commit(table: FeatureTable(records: [rec, rec], spec: spec), manifest: m2))
        XCTAssertEqual(featureFiles(in: dir), ["features-1.bin", "features-2.bin"])
        guard case .loaded(let stored) = ok.load(spec: spec) else { return XCTFail() }
        XCTAssertEqual(stored.table.count, 1)
        XCTAssertEqual(Set(stored.manifest.entries.keys), ["a"])
        XCTAssertEqual(featureFiles(in: dir), ["features-1.bin"])
    }

    /// B-32（QA 要求）：植入**真实 v1 `features.bin` 夹具**（MosaicCore `ArchitectRecheckTests.v1FixtureBase64`，
    /// featureVersion = 1）。两种升级场景都必须丢弃重建、不能用旧特征：
    /// 1. d6fa750 布局：`features.bin` + formatVersion 1 的 index.json；
    /// 2. 清单是新格式但指向的 features 文件头是 v1（例如清单被手工 / 旧构建改过）。
    func testB32RealV1FeaturesFileDiscardsAndRebuilds() async throws {
        let fixture = try XCTUnwrap(Data(base64Encoded: Self.v1FixtureBase64))
        XCTAssertEqual(fixture.count, 64 + 3 * 60 + 4)
        let lib = FakePhotoLibrary(assetCount: 12)

        // 场景 1：旧布局
        let dir1 = tempDir()
        try fixture.write(to: dir1.appendingPathComponent("features.bin"))
        let v1Manifest = #"{"formatVersion":1,"featureVersion":1,"entries":{"a0":{"status":"ok","row":0}},"scanInProgress":false}"#
        try Data(v1Manifest.utf8).write(to: dir1.appendingPathComponent("index.json"))
        let idx1 = PhotoIndex(directory: dir1, library: lib, thumbnails: FakeThumbnails(), backupExclusion: NoBackupExclusion(),
                              configuration: smallConfig())
        let o1 = await idx1.load()
        guard case .rebuilt = o1 else { return XCTFail("旧布局应重建，实际 \(o1)") }
        XCTAssertEqual(featureFiles(in: dir1), [], "v1 features.bin 被删除")
        let s1 = try await idx1.synchronize()
        XCTAssertEqual(s1.added, 12)
        let st1 = await idx1.status()
        XCTAssertEqual(st1.available, 12)
        let (u1, bad1) = try await mismatches(idx1)
        XCTAssertEqual(u1, 12); XCTAssertEqual(bad1, 0)

        // 场景 2：新清单 + v1 文件头
        let dir2 = tempDir()
        try fixture.write(to: dir2.appendingPathComponent("features-7.bin"))
        let spec = FeatureExtractor().spec
        let v2Manifest = #"{"formatVersion":2,"featureVersion":\#(spec.featureVersion),"featuresFile":"features-7.bin","scanInProgress":false,"entries":[{"i":"a0","s":"o","r":0},{"i":"a1","s":"o","r":1},{"i":"a2","s":"o","r":2}]}"#
        try Data(v2Manifest.utf8).write(to: dir2.appendingPathComponent("index.json"))
        let idx2 = PhotoIndex(directory: dir2, library: lib, thumbnails: FakeThumbnails(), backupExclusion: NoBackupExclusion(),
                              configuration: smallConfig())
        let o2 = await idx2.load()
        guard case .rebuilt = o2 else { return XCTFail("v1 文件头应重建，实际 \(o2)") }
        let st2a = await idx2.status()
        XCTAssertEqual(st2a.available, 0, "不得沿用旧特征")
        _ = try await idx2.synchronize()
        let (u2, bad2) = try await mismatches(idx2)
        XCTAssertEqual(u2, 12); XCTAssertEqual(bad2, 0)
    }

    /// MF-3：`PhotoIndex` 只依赖协议——换一个内存实现也能跑完整流程（以后 SQLite 实现复用同一套断言）。
    func testMF3PhotoIndexWorksAgainstAnyIndexStore() async throws {
        let store = InMemoryIndexStore()
        let lib = FakePhotoLibrary(assetCount: 25)
        let thumbs = FakeThumbnails()
        let idx = PhotoIndex(store: store, library: lib, thumbnails: thumbs, configuration: smallConfig())
        let o = await idx.load()
        XCTAssertEqual(o, .fresh)
        _ = try await idx.synchronize()
        XCTAssertGreaterThan(store.commits, 0)
        let idx2 = PhotoIndex(store: store, library: lib, thumbnails: thumbs, configuration: smallConfig())
        let o2 = await idx2.load()
        XCTAssertEqual(o2, .intact)
        let st = await idx2.status()
        XCTAssertEqual(st.available, 25)
        XCTAssertEqual(store.prepares, 2, "每次启动 prepare 一次（MF-2）")
    }

    static let v1FixtureBase64 = "UE1GRUFUAAABAEAAAQAAAAwAAAADAAAAABAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAgxwEIAAAAAM3MzD0zM7M+mpkZPwAAAAAK1yM8CtejPArXo7wK16O8CtejvM3MzD0zM7M+mpkZPwAAAAAK1yM8CtejPArXo7wK16O8CtejvM3MzD0zM7M+mpkZPwAAAAAK1yM8CtejPArXo7wK16O8CtejvM3MzD0zM7M+mpkZPwAAAAAK1yM8CtejPArXo7wK16O8CtejvG8SAzpvEoM6ppvEOgAAgD8AAIA/AACAPwAAAAAAAAAAAAAAAApkyLw="
}

/// 内存实现（MF-3 协议的第二个实现，测试用）。
final class InMemoryIndexStore: IndexStore, Sendable {
    private struct State: Sendable {
        var stored: StoredIndex?
        var commits = 0
        var prepares = 0
    }
    private let state = LockedState(State())
    var commits: Int { state.withLock { $0.commits } }
    var prepares: Int { state.withLock { $0.prepares } }

    func prepare() throws { state.withLock { $0.prepares += 1 } }
    func load(spec: FeatureSpec) -> IndexStoreLoad {
        state.withLock { s in s.stored.map { .loaded($0) } ?? .fresh }
    }
    func commit(table: FeatureTable, manifest: IndexManifest) throws {
        state.withLock { s in
            s.stored = StoredIndex(table: table, manifest: manifest)
            s.commits += 1
        }
    }
    func discardAll() { state.withLock { $0.stored = nil } }
}
