import Dispatch

/// 把目标图按网格切分，计算每个格子的特征（作为匹配的查询）。
public struct TargetSampler: Sendable {
    /// 使用的特征提取器（颜色空间、平均方式须与素材特征一致）。
    public var extractor: FeatureExtractor

    /// 创建取样器。
    public init(extractor: FeatureExtractor = FeatureExtractor()) {
        self.extractor = extractor
    }

    /// 计算所有格子的特征（行优先），格子区域取自 `layout`（正方形格、短边居中裁切）。
    /// - Throws: `layout` 与缓冲区尺寸不符时抛 `MosaicError.invalidGrid`；区域非法时抛 `MosaicError.invalidRegion`。
    public func cellFeatures(of buffer: PixelBuffer, layout: GridLayout) throws -> [FeatureRecord] {
        guard layout.imageWidth == buffer.width, layout.imageHeight == buffer.height else {
            throw MosaicError.invalidGrid("layout was computed for \(layout.imageWidth)×\(layout.imageHeight), buffer is \(buffer.width)×\(buffer.height)")
        }
        // 评审 S2：按行并行，每个任务只写自己那一行的输出区间，结果与串行逐位一致。
        let cols = layout.grid.columns, rows = layout.grid.rows
        let n = layout.grid.cellCount
        for i in 0..<n {   // 先在调用线程校验全部区域，工作线程内不再抛错。
            guard layout.cellPixelRegion(i).isValid(in: buffer) else { throw MosaicError.invalidRegion }
        }
        let out = UnsafeMutableBufferPointer<FeatureRecord>.allocate(capacity: n)
        defer { out.deallocate() }
        let box = SamplerOutput(base: out.baseAddress!)
        let extractor = self.extractor
        let work: @Sendable (Int) -> Void = { row in
            for c in 0..<cols {
                let i = row * cols + c
                // 区域已校验，extract 不会抛错。
                let rec = (try? extractor.extract(from: buffer, region: layout.cellPixelRegion(i))) ?? FeatureRecord(vector: FeatureVector())
                (box.base + i).initialize(to: rec)
            }
        }
        if rows > 1 {
            DispatchQueue.concurrentPerform(iterations: rows, execute: work)
        } else {
            work(0)
        }
        let result = Array(out)
        out.baseAddress!.deinitialize(count: n)
        return result
    }
}

/// 取样输出指针。安全性：每个任务只初始化自己行的 `[row·cols, (row+1)·cols)`，互不重叠；
/// `concurrentPerform` 返回后才读取。
private struct SamplerOutput: @unchecked Sendable {
    let base: UnsafeMutablePointer<FeatureRecord>
}
