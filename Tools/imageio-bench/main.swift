// ImageIO 流式写 JPEG 内存基准：用顺序 CGDataProvider 逐行喂像素，不在进程里持有整张位图。
// 用法：imageio-bench <width> <height> <out.jpg>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 4, let w = Int(args[1]), let h = Int(args[2]) else {
    FileHandle.standardError.write("usage: imageio-bench <w> <h> <out.jpg>\n".data(using: .utf8)!); exit(2)
}
let out = URL(fileURLWithPath: args[3])
let bpr = w * 4
final class State { var offset = 0; var totalFed = 0; var rewinds = 0; let total: Int; let bpr: Int; let w: Int
    init(total: Int, bpr: Int, w: Int) { self.total = total; self.bpr = bpr; self.w = w } }
let state = State(total: bpr * h, bpr: bpr, w: w)
var callbacks = CGDataProviderSequentialCallbacks(
    version: 0,
    getBytes: { info, buffer, count in
        let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
        let n = min(count, s.total - s.offset)
        if n <= 0 { return 0 }
        let p = buffer.assumingMemoryBound(to: UInt8.self)
        for i in 0..<n {
            let o = s.offset + i
            let row = o / s.bpr, col = (o % s.bpr) / 4, ch = o & 3
            // 粗糙的伪图案，避免 JPEG 把纯色压得过小
            p[i] = ch == 3 ? 255 : UInt8(truncatingIfNeeded: (row &* 7) ^ (col &* 13) &+ ch &* 85)
        }
        s.offset += n; s.totalFed += n
        return n
    },
    skipForward: { info, count in
        let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
        let n = min(Int(count), s.total - s.offset); s.offset += n; return off_t(n)
    },
    rewind: { info in let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue(); s.offset = 0; s.rewinds += 1 },
    releaseInfo: nil)
let provider = CGDataProvider(sequentialInfo: Unmanaged.passUnretained(state).toOpaque(), callbacks: &callbacks)!
let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let t0 = Date()
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
let ok = CGImageDestinationFinalize(dest)
let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? -1
print("RESULT w=\(w) h=\(h) mp=\(String(format: "%.1f", Double(w*h)/1e6)) ok=\(ok) secs=\(String(format: "%.1f", Date().timeIntervalSince(t0))) bytes=\(size) fed=\(state.totalFed) expected=\(state.total) rewinds=\(state.rewinds)")
exit(ok ? 0 : 1)
