import Foundation

/// Interleaved RGB, 32-bit float, row 0 at the top. Components are the file's
/// encoded values (0...1), not a separately linearized space, so an 8-bit JPEG
/// and a 16-bit TIFF follow the same path without a profile conversion.
public struct RGBImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, fill: Float = 0) {
        precondition(width > 0 && height > 0, "image size must be positive")
        self.width = width
        self.height = height
        let value = min(max(fill, 0), 1)
        self.pixels = [Float](repeating: value, count: width * height * 3)
    }

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(width > 0 && height > 0, "image size must be positive")
        precondition(pixels.count == width * height * 3, "RGB buffer has the wrong length")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var shortSide: Int { min(width, height) }
    public var longSide: Int { max(width, height) }
    public var pixelCount: Int { width * height }

    @inline(__always)
    public func offset(_ x: Int, _ y: Int) -> Int {
        (y * width + x) * 3
    }

    public mutating func setPixel(_ x: Int, _ y: Int, r: Float, g: Float, b: Float) {
        let index = offset(x, y)
        pixels[index] = r
        pixels[index + 1] = g
        pixels[index + 2] = b
    }

    public init(lumaOf image: RGBImage) {
        self.width = image.width
        self.height = image.height
        let plane = image.luminancePlane()
        var pixels = [Float](repeating: 0, count: plane.count * 3)
        for index in plane.indices {
            pixels[index * 3] = plane[index]
            pixels[index * 3 + 1] = plane[index]
            pixels[index * 3 + 2] = plane[index]
        }
        self.pixels = pixels
    }

    public func luminancePlane() -> [Float] {
        var plane = [Float](repeating: 0, count: pixelCount)
        var source = 0
        for index in 0..<plane.count {
            plane[index] = 0.299 * pixels[source] + 0.587 * pixels[source + 1] + 0.114 * pixels[source + 2]
            source += 3
        }
        return plane
    }

    public static func maxAbsoluteDifference(_ a: RGBImage, _ b: RGBImage) -> Float {
        precondition(a.pixels.count == b.pixels.count)
        var peak: Float = 0
        for index in a.pixels.indices {
            peak = max(peak, abs(a.pixels[index] - b.pixels[index]))
        }
        return peak
    }

    public static func meanAbsoluteDifference(_ a: RGBImage, _ b: RGBImage) -> Float {
        precondition(a.pixels.count == b.pixels.count)
        var sum: Float = 0
        for index in a.pixels.indices {
            sum += abs(a.pixels[index] - b.pixels[index])
        }
        return sum / Float(a.pixels.count)
    }
}

public enum PixelDepth {
    /// 8-bit file code to the float the engine actually filters.
    public static func expand8(_ value: UInt8) -> Float {
        Float(value) / 255
    }

    /// 16-bit file code to float. Export quantizes back with `quantize16`.
    public static func expand16(_ value: UInt16) -> Float {
        Float(value) / 65535
    }

    public static func quantize8(_ value: Float) -> UInt8 {
        let clamped = min(max(value, 0), 1)
        return UInt8(min(255, Int((clamped * 255).rounded())))
    }

    public static func quantize16(_ value: Float) -> UInt16 {
        let clamped = min(max(value, 0), 1)
        return UInt16(min(65535, Int((clamped * 65535).rounded())))
    }
}

/// EXIF orientation. The raw value matches the TIFF tag. `up` is already upright.
public enum ImageOrientation: Int, Equatable, Sendable, CaseIterable {
    case up = 1
    case upMirrored = 2
    case down = 3
    case downMirrored = 4
    case leftMirrored = 5
    case right = 6
    case rightMirrored = 7
    case left = 8

    public init(exif: Int) {
        self = ImageOrientation(rawValue: exif) ?? .up
    }

    public var swapsAxes: Bool {
        switch self {
        case .leftMirrored, .right, .rightMirrored, .left:
            return true
        default:
            return false
        }
    }

    public func orientedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        swapsAxes ? (height, width) : (width, height)
    }

    /// Stored-pixel coordinate (top-left origin) to the upright coordinate.
    public func map(x: Int, y: Int, width: Int, height: Int) -> (x: Int, y: Int) {
        switch self {
        case .up:
            return (x, y)
        case .upMirrored:
            return (width - 1 - x, y)
        case .down:
            return (width - 1 - x, height - 1 - y)
        case .downMirrored:
            return (x, height - 1 - y)
        case .leftMirrored:
            return (y, x)
        case .right:
            return (height - 1 - y, x)
        case .rightMirrored:
            return (height - 1 - y, width - 1 - x)
        case .left:
            return (y, width - 1 - x)
        }
    }

    public func applying(to image: RGBImage) -> RGBImage {
        if self == .up { return image }
        let size = orientedSize(width: image.width, height: image.height)
        var upright = RGBImage(width: size.width, height: size.height, fill: 0)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let mapped = map(x: x, y: y, width: image.width, height: image.height)
                let source = image.offset(x, y)
                upright.setPixel(
                    mapped.x,
                    mapped.y,
                    r: image.pixels[source],
                    g: image.pixels[source + 1],
                    b: image.pixels[source + 2]
                )
            }
        }
        return upright
    }
}

/// Top-left origin, matching `MaskBuffer` row 0 and an upright CGImage.
/// The canvas is a flipped AppKit view; this is the mapping it must use so a
/// stroke at the top-left of the window lands on the top-left of the photo.
public enum UprightPoint {
    public static func unit(
        viewX: Float,
        viewY: Float,
        originX: Float,
        originY: Float,
        scale: Float,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> SIMD2<Float>? {
        guard pixelWidth > 0, pixelHeight > 0, scale > 0 else { return nil }
        let imageX = originX + viewX / scale
        let imageY = originY + viewY / scale
        let u = imageX / Float(pixelWidth)
        let v = imageY / Float(pixelHeight)
        guard u >= 0, v >= 0, u <= 1, v <= 1 else { return nil }
        return SIMD2(u, v)
    }
}

func clamp01(_ value: Float) -> Float {
    min(max(value, 0), 1)
}

func smoothstep(_ edge0: Float, _ edge1: Float, _ value: Float) -> Float {
    let span = edge1 - edge0
    if span == 0 { return value < edge0 ? 0 : 1 }
    let t = clamp01((value - edge0) / span)
    return t * t * (3 - 2 * t)
}
