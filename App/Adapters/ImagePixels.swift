import CoreGraphics
import Foundation
import ImageIO
import MosaicCore
import MosaicAppCore

/// CGImage / 图像数据 → `MosaicCore.PixelBuffer`（RGBA8、sRGB、不透明白底）。
enum ImagePixels {
    /// 画到白底 sRGB 上下文：P3 → sRGB 由 CoreGraphics 转换，透明区域合成到白色（评审 O2）。
    static func opaqueSRGB(_ image: CGImage, maxEdge: Int? = nil) -> PixelBuffer? {
        var w = image.width, h = image.height
        if let m = maxEdge, max(w, h) > m {
            let s = Double(m) / Double(max(w, h))
            w = max(1, Int((Double(w) * s).rounded()))
            h = max(1, Int((Double(h) * s).rounded()))
        }
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        let ok: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return try? PixelBuffer(width: w, height: h, bytes: bytes)
    }

    /// 按短边居中裁成正方形，再画到不透明白底 sRGB。
    /// 边长大于 `maxEdge` 时缩小到 `maxEdge×maxEdge`；短边不足时保持原生正方形（由绘制端等比放大），绝不非等比拉伸。
    static func opaqueSRGBCenteredSquare(_ image: CGImage, maxEdge: Int) -> PixelBuffer? {
        let crop = CenterSquareCrop.rect(width: image.width, height: image.height)
        guard crop.size > 0,
              let square = image.cropping(to: CGRect(x: crop.x, y: crop.y, width: crop.size, height: crop.size))
        else { return nil }
        return opaqueSRGB(square, maxEdge: maxEdge)
    }

    /// 目标图：ImageIO 降采样（长边 ≤ 2048，应用 EXIF 方向），不把整张原图解码进内存。
    static func downsampledTarget(from data: Data, maxLongEdge: Int = 2048) -> PixelBuffer? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        return opaqueSRGB(cg)
    }

    /// PixelBuffer → CGImage（预览显示用）。
    static func cgImage(_ p: PixelBuffer) -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(p.bytes) as CFData) else { return nil }
        return CGImage(width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: p.bytesPerRow,
                       space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
