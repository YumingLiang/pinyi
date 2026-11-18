import Foundation
import MosaicCore
@testable import MosaicAppCore

/// 记录调用的假实现（只在测试 target；App 二进制里不读文件时间戳，免 PrivacyInfo C617.1）。
final class RecordingBackupExclusion: BackupExclusionApplying, Sendable {
    struct Call: Sendable, Hashable {
        let name: String
        /// 调用那一刻目录 / 文件是否已存在
        let existed: Bool
    }
    private struct State: Sendable {
        var calls: [Call] = []
        var failing: Set<String> = []
    }
    private let state = LockedState(State())

    init() {}

    var calls: [Call] { state.withLock { $0.calls } }
    var failing: Set<String> {
        get { state.withLock { $0.failing } }
        set { state.withLock { $0.failing = newValue } }
    }
    func names() -> [String] { calls.map(\.name) }
    func reset() { state.withLock { $0.calls = [] } }

    func excludeFromBackup(_ url: URL) throws {
        let call = Call(name: url.lastPathComponent, existed: FileManager.default.fileExists(atPath: url.path))
        let shouldFail = state.withLock { s -> Bool in
            s.calls.append(call)
            return s.failing.contains(url.lastPathComponent)
        }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
    }
}
