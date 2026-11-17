import Foundation
import SwiftUI
import MosaicAppCore

/// 文案 key → 显示文本。逻辑层只给 key（稳定 key，见 copy_v1.1.md），这里统一查表。
extension Text {
    init(_ key: L10nKey) { self.init(LocalizedStringKey(key.rawValue)) }
    init(_ line: LocalizedLine) { self.init(verbatim: line.localized) }
}

extension L10nKey {
    var localized: String { NSLocalizedString(rawValue, comment: "") }
}

extension LocalizedLine {
    /// `%1$@` 位置占位符；参数已是格式化好的字符串（千分位）。
    var localized: String {
        let format = key.localized
        let args: [CVarArg] = arguments.map { $0 as NSString }
        // 「正在统计…」（§2f 补充 3a）：摘要张数位置的占位连同「张」一起换掉
        return MultiAlbumText.resolveCounting(in: String(format: format, arguments: args),
                                              counting: L10nKey.sourceCounting.localized)
    }
}
