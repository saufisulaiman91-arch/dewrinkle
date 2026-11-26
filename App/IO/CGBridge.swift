import CoreGraphics
import Foundation
import DewrinkleCore

enum CGBridge {
    static func rgbImage(from cgImage: CGImage) -> RGBImage {
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let sourceSpace = cgImage.colorSpace
        let colorSpace: CGColorSpace
        if let sourceSpace, sourceSpace.model == .rgb {
            colorSpace = sourceSpace
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        }
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            return RGBImage(width: max(width, 1), height: max(height, 1), fill: 0)
        }
        var pixels = [Float](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            pixels[index * 3] = PixelDepth.expand8(bytes[index * 4])
            pixels[index * 3 + 1] = PixelDepth.expand8(bytes[index * 4 + 1])
            pixels[index * 3 + 2] = PixelDepth.expand8(bytes[index * 4 + 2])
        }
        return RGBImage(width: width, height: height, pixels: pixels)
    }

    static func cgImage(from image: RGBImage) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: image.pixelCount * 4)
        for index in 0..<image.pixelCount {
            bytes[index * 4] = PixelDepth.quantize8(image.pixels[index * 3])
            bytes[index * 4 + 1] = PixelDepth.quantize8(image.pixels[index * 3 + 1])
            bytes[index * 4 + 2] = PixelDepth.quantize8(image.pixels[index * 3 + 2])
        }
        return rgba8Image(bytes: bytes, width: image.width, height: image.height, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    static func grayImage(_ mask: MaskBuffer) -> CGImage? {
        let rowBytes = (mask.width + 15) & ~15
        var bytes = [UInt8](repeating: 0, count: rowBytes * mask.height)
        for y in 0..<mask.height {
            for x in 0..<mask.width {
                let value = mask.values[y * mask.width + x]
                let code = Int((min(max(value, 0), 1) * 255).rounded())
                bytes[y * rowBytes + x] = UInt8(min(255, max(0, code)))
            }
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: mask.width,
            height: mask.height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func overlayImage(_ mask: MaskBuffer) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: mask.values.count * 4)
        for index in 0..<mask.values.count {
            let alpha = UInt8(min(255, max(0, Int((mask.values[index] * 150).rounded()))))
            bytes[index * 4] = 196
            bytes[index * 4 + 1] = 64
            bytes[index * 4 + 2] = 54
            bytes[index * 4 + 3] = alpha
        }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: mask.width,
            height: mask.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: mask.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    static func displayImage(rgba: [Float], width: Int, height: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let count = min(width * height, rgba.count / 4)
        for index in 0..<count {
            bytes[index * 4] = PixelDepth.quantize8(rgba[index * 4])
            bytes[index * 4 + 1] = PixelDepth.quantize8(rgba[index * 4 + 1])
            bytes[index * 4 + 2] = PixelDepth.quantize8(rgba[index * 4 + 2])
        }
        return rgba8Image(bytes: bytes, width: width, height: height, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    static func rgba8Image(bytes: [UInt8], width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
