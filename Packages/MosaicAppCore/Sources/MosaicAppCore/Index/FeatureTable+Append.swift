import MosaicCore

extension FeatureTable {
    /// 追加记录（MosaicCore 只提供整表构造，这里按 SoA 布局拼接）。O(现有行数)，所以调用方应批量追加。
    func appending(_ records: [FeatureRecord]) -> FeatureTable {
        guard !records.isEmpty else { return self }
        let dim = matrix.dimension
        let old = count
        let n = old + records.count
        var soa = [Float](repeating: 0, count: dim * n)
        let added = FeatureMatrix(records: records)
        for d in 0..<dim {
            for i in 0..<old { soa[d * n + i] = matrix.storage[d * old + i] }
            for j in 0..<records.count { soa[d * n + old + j] = added.storage[d * records.count + j] }
        }
        // 维度 / 长度由构造保证一致。
        let m = try! FeatureMatrix(dimension: dim, count: n, soa: soa)
        return try! FeatureTable(matrix: m, lightnessVariance: lightnessVariance + records.map(\.lightnessVariance),
                                 aspectRatio: aspectRatio + records.map(\.aspectRatio), flags: flags + records.map(\.flags),
                                 spec: spec)
    }
}
