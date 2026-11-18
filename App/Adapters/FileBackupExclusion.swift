import Foundation
import MosaicAppCore

/// `isExcludedFromBackup` 的 Apple 实现（评审 d6fa750 MF-2、QA B-12）。
/// 只在索引**目录**上设：原子写会替换文件、文件级属性会丢，目录级不会；目录被排除时内容一并排除。
struct FileBackupExclusion: BackupExclusionApplying {
    func excludeFromBackup(_ url: URL) throws {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try u.setResourceValues(values)
    }
}
