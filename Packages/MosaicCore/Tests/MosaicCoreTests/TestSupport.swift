import XCTest
@testable import MosaicCore

/// 生成可复现的随机特征（合成"伪照片"特征，不需要图片解码；技术方案 §7 测试策略）。
func syntheticVectors(count: Int, seed: UInt64) -> [FeatureVector] {
    var rng = SplitMix64(seed: seed)
    return (0..<count).map { _ in
        var comps = [Float](repeating: 0, count: 12)
        for b in 0..<4 {
            comps[b * 3] = rng.nextUnitFloat()                 // L 0…1
            comps[b * 3 + 1] = rng.nextUnitFloat() * 0.5 - 0.25 // a
            comps[b * 3 + 2] = rng.nextUnitFloat() * 0.5 - 0.25 // b
        }
        return FeatureVector(comps)
    }
}

/// 朴素 top‑k：全部算距离后按 (距离, 下标) 排序，作为对拍基准。
func naiveTopK(query: [Float], library: FeatureMatrix, k: Int, mask: BitMask? = nil) -> [Neighbor] {
    var all: [Neighbor] = []
    for i in 0..<library.count where mask?[i] ?? true {
        all.append(Neighbor(index: i, distance: squaredEuclideanDistance(query, library.row(i))))
    }
    all.sort { $0.distance < $1.distance || ($0.distance == $1.distance && $0.index < $1.index) }
    return Array(all.prefix(k))
}

func XCTAssertClose(_ a: Float, _ b: Double, accuracy: Double = 1e-4, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(Double(a), b, accuracy: accuracy, message, file: file, line: line)
}

/// 检查结果是否满足主邻域不重复。返回违反的格子对数。
func neighborhoodViolations(_ a: MosaicAssignment, _ nb: Neighborhood) -> Int {
    var v = 0
    for i in 0..<a.grid.cellCount {
        for j in a.grid.neighbors(of: i, in: nb) where j > i && a.tiles[i] == a.tiles[j] { v += 1 }
    }
    return v
}

func useCounts(_ a: MosaicAssignment, libraryCount: Int) -> [Int] {
    var u = [Int](repeating: 0, count: libraryCount)
    for t in a.tiles { u[t] += 1 }
    return u
}
