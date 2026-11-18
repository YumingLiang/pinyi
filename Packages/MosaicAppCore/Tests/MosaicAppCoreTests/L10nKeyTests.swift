import Foundation
import XCTest
@testable import MosaicAppCore

/// 逻辑层引用的每个文案 key 都必须真实存在于 `App/Resources/zh-Hans.lproj/Localizable.strings`（稳定 key，防拼错）。
final class L10nKeyTests: XCTestCase {
    static func stringsKeys() throws -> Set<String> {
        // Tests/MosaicAppCoreTests/L10nKeyTests.swift → 仓库根
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("App/Resources/zh-Hans.lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var keys = Set<String>()
        for line in text.split(separator: "\n") where line.hasPrefix("\"") {
            let rest = line.dropFirst()
            if let end = rest.firstIndex(of: "\"") { keys.insert(String(rest[..<end])) }
        }
        return keys
    }

    func testAllUsedKeysExistInStringsFile() throws {
        let keys = try Self.stringsKeys()
        XCTAssertGreaterThan(keys.count, 100)
        let missing = L10nKey.allUsed.map(\.rawValue).filter { !keys.contains($0) }
        XCTAssertEqual(missing, [], "Localizable.strings 缺少 key")
        XCTAssertEqual(Set(L10nKey.allUsed).count, L10nKey.allUsed.count, "allUsed 有重复")
    }

    func testFormatKeysHavePositionalPlaceholders() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("App/Resources/zh-Hans.lproj/Localizable.strings"), encoding: .utf8)
        for (key, n) in [("source.list.count", 1), ("source.list.count_pending", 1), ("scan.progress", 2), ("scan.progressive.ready", 1), ("source.excluded_low_res", 1)] {
            let line = text.split(separator: "\n").first { $0.hasPrefix("\"\(key)\"") }.map(String.init) ?? ""
            for i in 1...n { XCTAssertTrue(line.contains("%\(i)$@"), "\(key) 缺少 %\(i)$@") }
        }
    }

    func testGroupedCount() {
        XCTAssertEqual(CountFormat.grouped(0), "0")
        XCTAssertEqual(CountFormat.grouped(999), "999")
        XCTAssertEqual(CountFormat.grouped(1234), "1,234")
        XCTAssertEqual(CountFormat.grouped(100000), "100,000")
        XCTAssertEqual(CountFormat.grouped(-2000), "-2,000")
    }
}
