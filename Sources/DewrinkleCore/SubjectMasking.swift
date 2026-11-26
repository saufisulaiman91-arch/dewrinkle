import Foundation

public struct NormalizedRect: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float

    public init(x: Float, y: Float, width: Float, height: Float) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func expanded(scaleX: Float, scaleY: Float) -> NormalizedRect {
        let newWidth = width * scaleX
        let newHeight = height * scaleY
        return NormalizedRect(
            x: x + (width - newWidth) / 2,
            y: y + (height - newHeight) / 2,
            width: newWidth,
            height: newHeight
        )
    }
}

public struct ClickPoint: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case include
        case exclude
    }

    public var x: Float
    public var y: Float
    public var kind: Kind

    public init(x: Float, y: Float, kind: Kind) {
        self.x = x
        self.y = y
        self.kind = kind
    }
}

public enum MaskingError: Error, Equatable, CustomStringConvertible {
    case modelNotInstalled(String)
    case failed(String)

    public var description: String {
        switch self {
        case .modelNotInstalled(let message), .failed(let message):
            return message
        }
    }
}

/// Person / product foreground. The app's Vision segmenter adopts this.
/// The returned mask is refined with `GarmentMaskRefinement` before it becomes paintable.
public protocol ForegroundSegmenting: AnyObject {
    func foregroundMask(for image: RGBImage) async throws -> MaskBuffer
}

/// Click-to-select extension point.
///
/// A commercially licensed SAM 2 model compiled to Core ML can adopt this
/// without changes to the brush or the frequency engine. Clothing parsers
/// trained on non-commercial data (SCHP, mattmdjaga/segformer_b2_clothes,
/// CRHD-3K) are not acceptable implementations.
public protocol ClickSelecting: AnyObject {
    func mask(for image: RGBImage, points: [ClickPoint]) async throws -> MaskBuffer
}

public final class UninstalledSAM2Selector: ClickSelecting {
    public init() {}

    public func mask(for image: RGBImage, points: [ClickPoint]) async throws -> MaskBuffer {
        throw MaskingError.modelNotInstalled(
            "No click-to-select model is installed. Add a SAM 2 Core ML model that adopts ClickSelecting."
        )
    }
}

public enum SkinTone {
    /// Soft YCbCr skin score in 0...1. Smooth skin scores; weave is rejected later by gradient.
    public static func likelihood(r: Float, g: Float, b: Float) -> Float {
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        let cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 0.5
        let cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 0.5
        let cbScore = band(cb, low: 77 / 255, high: 127 / 255, feather: 8 / 255)
        let crScore = band(cr, low: 133 / 255, high: 173 / 255, feather: 8 / 255)
        let lumaScore = band(luma, low: 0.18, high: 0.93, feather: 0.06)
        return cbScore * crScore * lumaScore
    }

    private static func band(_ value: Float, low: Float, high: Float, feather: Float) -> Float {
        let enter = smoothstep(low - feather, low + feather, value)
        let exit = 1 - smoothstep(high - feather, high + feather, value)
        return enter * exit
    }
}

public enum GarmentMaskRefinement {
    /// Subtracts smooth skin and a feathered face box from a person/foreground mask.
    /// Textured pixels (weave, gingham, embroidery) keep their mask even if the
    /// color is close to skin, which matters for beige abayas.
    /// `skinStrength` above zero removes smooth skin-colored pixels. Pink satin
    /// scores as skin, so the auto mask passes 0 and carves faces and hands by
    /// rectangle instead.
    public static func refine(
        person mask: MaskBuffer,
        image: RGBImage,
        faces: [NormalizedRect],
        skinStrength: Float = 0.9,
        hands: [NormalizedRect] = []
    ) -> MaskBuffer {
        let person = mask.resized(toWidth: image.width, height: image.height)
        var output = person
        if skinStrength > 0.001 {
            // Local contrast, not Sobel. A tight weave is a balanced checker and Sobel
            // cancels on it, which would let a beige abaya be read as skin.
            let contrast = localContrast(of: image)
            let width = image.width
            for y in 0..<image.height {
                for x in 0..<width {
                    let pixel = y * width + x
                    let source = image.offset(x, y)
                    let skin = SkinTone.likelihood(
                        r: image.pixels[source],
                        g: image.pixels[source + 1],
                        b: image.pixels[source + 2]
                    )
                    let texture = smoothstep(0.04, 0.12, contrast[pixel])
                    let smoothSkin = skin * (1 - texture)
                    output.values[pixel] = person.values[pixel] * (1 - clamp01(skinStrength) * smoothSkin)
                }
            }
        }
        for face in faces {
            let expanded = face.expanded(scaleX: 1.55, scaleY: 1.85)
            subtractFace(&output, rect: expanded)
        }
        for hand in hands {
            let expanded = hand.expanded(scaleX: 1.25, scaleY: 1.35)
            subtractFace(&output, rect: expanded)
        }
        return output
    }

    /// Max minus min luminance in a 3×3. Smooth skin is near 0; weave is not.
    public static func localContrast(of image: RGBImage) -> [Float] {
        let luma = image.luminancePlane()
        let width = image.width
        let height = image.height
        var contrast = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var low: Float = 1
                var high: Float = 0
                for dy in -1...1 {
                    let yy = min(max(y + dy, 0), height - 1)
                    for dx in -1...1 {
                        let xx = min(max(x + dx, 0), width - 1)
                        let value = luma[yy * width + xx]
                        low = min(low, value)
                        high = max(high, value)
                    }
                }
                contrast[y * width + x] = high - low
            }
        }
        return contrast
    }

    static func subtractFace(_ mask: inout MaskBuffer, rect: NormalizedRect) {
        let feather = max(rect.width, rect.height) * 0.18
        let width = mask.width
        let height = mask.height
        for y in 0..<height {
            let v = (Float(y) + 0.5) / Float(height)
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width)
                let weight = faceCoverage(u: u, v: v, rect: rect, feather: feather)
                if weight <= 0 { continue }
                let index = y * width + x
                mask.values[index] *= (1 - weight)
            }
        }
    }

    static func faceCoverage(u: Float, v: Float, rect: NormalizedRect, feather: Float) -> Float {
        let dx = max(rect.x - u, u - (rect.x + rect.width), 0)
        let dy = max(rect.y - v, v - (rect.y + rect.height), 0)
        let distance = hypot(dx, dy)
        if distance <= 0 { return 1 }
        if feather <= 0 || distance >= feather { return distance <= 0 ? 1 : 0 }
        return 1 - smoothstep(0, feather, distance)
    }
}
