// 运维草稿 /workspace/pinyi/ios-release/InternalToolsMarker.swift 原样合入（仅改本行注释）。只在 INTERNAL_TOOLS（Debug / Internal）下编译，供 fastlane / CI 做二进制检查。
#if INTERNAL_TOOLS
enum InternalToolsMarker {
    // 内部工具根视图需要实际引用它（例如 .accessibilityIdentifier(InternalToolsMarker.id)），
    // 防止被编译器剥离；fastlane 用 strings 在产物里找这个字符串。
    static let id = "PINYI_INTERNAL_TOOLS_MARKER"
}
#endif
