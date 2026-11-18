import Foundation
import MosaicCore

/// 显式布局：导出与「我的作品」共用的输入（design/works-storage-v0.1.md：**不靠种子重算**）。
///
/// - 每格存照片 `localIdentifier` + 裁剪框，打开作品 / 导出时不再跑匹配。
/// - 导出入口只收 `MosaicLayout`（而不是现算的 `GenerationProduct`），作品页也能导出。
/// - 不含任何像素数据；目标图（叠加层用）由调用方另给。
/// - 复用 MosaicCore 已有的 `CropRect`（`Hashable, Sendable`）；它不是 `Codable`，这里手写编码，避免对外部类型做追溯一致性。
public struct MosaicLayout: Sendable, Codable, Equatable {
    /// 当前格式版本。改字段含义时 +1，解码端按版本迁移。
    public static let currentFormatVersion = 1

    /// 一格的分配。
    public struct CellAssignment: Sendable, Codable, Equatable {
        /// PhotoKit `localIdentifier`；空串 = 该格没有分到照片（渲染时画目标图区域的平均色）。
        public var localIdentifier: String
        /// 归一化裁剪框（0…1），相对于照片**居中最大正方形**；当前生成器都是 (0, 0, 1, 1)，照样显式存下来。
        public var crop: CropRect
        /// 「我的作品」预览兜底格（`localIdentifier` 为空、找不到合格相近照片）：渲染 / 导出时用作品目录里存的旧预览裁切放大填充
        /// （`WorkMeta.fallbackFile`）。可选字段：只在为 true 时写出 `"fb": true`，旧版布局、普通格子的 JSON 与指纹都不变。
        public var fallback: Bool
        /// 「我的作品」纯色格（需求 4.8 第 5e 条）：原照片被隐藏（或拿不准）、又找不到相近照片的格子，填目标图这一格的平均色。
        /// 不用旧预览（旧预览里就是隐藏照片的像素），也不进 `WorkFallbackImages`。预览重画和高清导出都按这个颜色填，两边一致。
        /// 可选字段：只在有值时写出 `"fc": [r, g, b]`，旧版布局、普通格子的 JSON 与指纹都不变。
        public var fill: CellColor?

        public static let fullSquare = CropRect(x: 0, y: 0, width: 1, height: 1)

        public init(localIdentifier: String, crop: CropRect = CellAssignment.fullSquare, fallback: Bool = false,
                    fill: CellColor? = nil) {
            self.localIdentifier = localIdentifier
            self.crop = crop
            self.fallback = fallback
            self.fill = fill
        }

        private enum CodingKeys: String, CodingKey { case id, crop, fb, fc }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            localIdentifier = try c.decode(String.self, forKey: .id)
            crop = try MosaicLayout.decodeRect(c.decode([Double].self, forKey: .crop))
            fallback = try c.decodeIfPresent(Bool.self, forKey: .fb) ?? false
            fill = try c.decodeIfPresent([UInt8].self, forKey: .fc).flatMap(CellColor.init(components:))
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(localIdentifier, forKey: .id)
            try c.encode(MosaicLayout.encodeRect(crop), forKey: .crop)
            if fallback { try c.encode(true, forKey: .fb) }
            if let fill { try c.encode([fill.r, fill.g, fill.b], forKey: .fc) }
        }
    }

    /// 生成参数快照（追溯 / 作品页显示用，导出不依赖它重算）。
    public struct Params: Sendable, Codable, Equatable {
        /// 叠加强度（0…0.3）。
        public var overlayAlpha: Double
        /// 密度名（coarse / medium / fine），只作记录。
        public var density: String
        /// 生成种子，只作追溯。
        public var seed: UInt64

        public init(overlayAlpha: Double, density: String, seed: UInt64) {
            self.overlayAlpha = overlayAlpha
            self.density = density
            self.seed = seed
        }
    }

    public var formatVersion: Int
    public var cols: Int
    public var rows: Int
    /// 行优先，`cols × rows` 个。
    public var cellAssignments: [CellAssignment]
    /// 目标图尺寸（生成时的像素）。
    public var targetSize: Size
    /// 网格在目标图里的区域（目标图像素；短边方向已居中裁掉余量）。
    public var targetCrop: CropRect
    public var params: Params

    public struct Size: Sendable, Codable, Equatable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) { self.width = width; self.height = height }
    }

    public init(cols: Int, rows: Int, cellAssignments: [CellAssignment], targetSize: Size, targetCrop: CropRect,
                params: Params, formatVersion: Int = MosaicLayout.currentFormatVersion) {
        self.formatVersion = formatVersion
        self.cols = cols
        self.rows = rows
        self.cellAssignments = cellAssignments
        self.targetSize = targetSize
        self.targetCrop = targetCrop
        self.params = params
    }

    public var cellCount: Int { cols * rows }
    /// 格数与列 × 行一致、尺寸为正。
    public var isValid: Bool {
        cols > 0 && rows > 0 && cellAssignments.count == cellCount && targetCrop.width > 0 && targetCrop.height > 0
    }

    /// 第 `row` 行第 `col` 列（0 起）的分配。
    public func cell(col: Int, row: Int) -> CellAssignment { cellAssignments[row * cols + col] }

    /// 去重后的照片 ID（导出前批量 fetch、统计缺失用），保持首次出现顺序。
    public var uniqueAssetIDs: [String] {
        var seen = Set<String>()
        return cellAssignments.compactMap { c in
            guard !c.localIdentifier.isEmpty, seen.insert(c.localIdentifier).inserted else { return nil }
            return c.localIdentifier
        }
    }

    // MARK: 编码

    private enum CodingKeys: String, CodingKey {
        case formatVersion, cols, rows, cells, targetSize, targetCrop, params
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        cols = try c.decode(Int.self, forKey: .cols)
        rows = try c.decode(Int.self, forKey: .rows)
        cellAssignments = try c.decode([CellAssignment].self, forKey: .cells)
        targetSize = try c.decode(Size.self, forKey: .targetSize)
        targetCrop = try Self.decodeRect(c.decode([Double].self, forKey: .targetCrop))
        params = try c.decode(Params.self, forKey: .params)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(cols, forKey: .cols)
        try c.encode(rows, forKey: .rows)
        try c.encode(cellAssignments, forKey: .cells)
        try c.encode(targetSize, forKey: .targetSize)
        try c.encode(Self.encodeRect(targetCrop), forKey: .targetCrop)
        try c.encode(params, forKey: .params)
    }

    static func encodeRect(_ r: CropRect) -> [Double] { [r.x, r.y, r.width, r.height] }

    static func decodeRect(_ a: [Double]) throws -> CropRect {
        guard a.count == 4 else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "CropRect needs 4 numbers"))
        }
        return CropRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }
}

extension MosaicLayout {
    /// 从一次生成结果固化布局（结果页「导出」/「存到我的作品」都走这里）。
    public init(product: GenerationProduct, overlayAlpha: Double) {
        let g = product.generation
        let ids = product.cellAssetIDs
        self.init(cols: g.layout.columns, rows: g.layout.rows,
                  cellAssignments: ids.map { CellAssignment(localIdentifier: $0 ?? "") },
                  targetSize: Size(width: g.layout.imageWidth, height: g.layout.imageHeight),
                  targetCrop: g.layout.cropRect,
                  params: Params(overlayAlpha: overlayAlpha, density: Self.name(g.density), seed: g.seed))
    }

    static func name(_ d: Density) -> String {
        switch d {
        case .coarse: "coarse"
        case .medium: "medium"
        case .fine: "fine"
        case .custom(let c): "custom-\(c)"
        }
    }
}

/// 一格的纯色（sRGB 8 位）。
public struct CellColor: Sendable, Hashable, Codable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public init(r: UInt8, g: UInt8, b: UInt8) { self.r = r; self.g = g; self.b = b }
    init?(components c: [UInt8]) {
        guard c.count == 3 else { return nil }
        self.init(r: c[0], g: c[1], b: c[2])
    }
}
