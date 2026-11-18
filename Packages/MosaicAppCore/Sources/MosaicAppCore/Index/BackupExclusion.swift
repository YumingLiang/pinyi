import Foundation

/// 「不进 iCloud / iTunes 备份」的抽象（技术方案 §5.1、QA B-12、TF1 必须项）。
///
/// Apple 侧实现是 `URLResourceValues.isExcludedFromBackup = true`（App/Adapters/BackupExclusion.swift）。
/// 这个资源属性挂在 inode 上：**原子重写（写临时文件再 rename）会生成新文件、丢掉属性**，
/// 所以 `PhotoIndex` 在以下时机都会重新设置：
/// 1. 目录创建 / 加载时：设置目录本身，已存在的 features.bin、index.json 也补设（老版本升级、属性丢失的自愈）；
/// 2. 每次提交：features.bin 写完后设它，index.json 原子写完后设它，目录再设一次。
///
/// 设置失败不阻断索引（索引本身仍然正确），但会记在 `PhotoIndex.backupExclusionFailures`，下次提交再试。
public protocol BackupExclusionApplying: Sendable {
    func excludeFromBackup(_ url: URL) throws
}
