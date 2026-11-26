import Foundation

/// Thin edge mask for seams, topstitching, and buttons. A soft wrinkle has a
/// small gradient and is smoothed; a stitch is a steep step and is kept.
public struct StructureParameters: Equatable, Sendable {
    public var edgeLow: Float
    public var edgeHigh: Float
    public var dilatePixels: Float
    public var featherPixels: Float

    public init(edgeLow: Float, edgeHigh: Float, dilatePixels: Float, featherPixels: Float) {
        self.edgeLow = edgeLow
        self.edgeHigh = edgeHigh
        self.dilatePixels = dilatePixels
        self.featherPixels = featherPixels
    }

    public static func resolved(fullShortSide: Int, pixelScale: Float) -> StructureParameters {
        let side = Float(max(fullShortSide, 1))
        let scale = max(pixelScale, 0.0001)
        return StructureParameters(
            edgeLow: 0.06,
            edgeHigh: 0.22,
            dilatePixels: 0.0008 * side * scale,
            featherPixels: 0.00045 * side * scale
        )
    }
}

public enum StructureMask {
    /// Normalized Sobel magnitude of luminance. A 1.0 step over one pixel is about 1.
    public static func gradientMagnitude(of image: RGBImage) -> [Float] {
        let luma = image.luminancePlane()
        let width = image.width
        let height = image.height
        var magnitude = [Float](repeating: 0, count: width * height)

        func at(_ x: Int, _ y: Int) -> Float {
            let xx = min(max(x, 0), width - 1)
            let yy = min(max(y, 0), height - 1)
            return luma[yy * width + xx]
        }

        for y in 0..<height {
            for x in 0..<width {
                let topLeft = at(x - 1, y - 1)
                let top = at(x, y - 1)
                let topRight = at(x + 1, y - 1)
                let left = at(x - 1, y)
                let right = at(x + 1, y)
                let bottomLeft = at(x - 1, y + 1)
                let bottom = at(x, y + 1)
                let bottomRight = at(x + 1, y + 1)
                let gx = ((topRight + 2 * right + bottomRight) - (topLeft + 2 * left + bottomLeft)) / 4
                let gy = ((bottomLeft + 2 * bottom + bottomRight) - (topLeft + 2 * top + topRight)) / 4
                magnitude[y * width + x] = hypot(gx, gy)
            }
        }
        return magnitude
    }

    public static func make(image: RGBImage, parameters: StructureParameters) -> MaskBuffer {
        let magnitude = gradientMagnitude(of: image)
        var mask = MaskBuffer(width: image.width, height: image.height, fill: 0)
        let span = max(parameters.edgeHigh - parameters.edgeLow, 0.0001)
        for index in magnitude.indices {
            mask.values[index] = clamp01((magnitude[index] - parameters.edgeLow) / span)
        }
        if parameters.dilatePixels >= 0.5 {
            mask = dilate(mask, radius: Int(parameters.dilatePixels.rounded()))
        }
        if parameters.featherPixels >= 0.25 {
            mask = GaussianBlur.mask(mask, sigma: parameters.featherPixels)
        }
        return mask
    }

    public static func dilate(_ mask: MaskBuffer, radius: Int) -> MaskBuffer {
        if radius <= 0 { return mask }
        var output = mask
        let width = mask.width
        let height = mask.height
        for y in 0..<height {
            let y0 = max(0, y - radius)
            let y1 = min(height - 1, y + radius)
            for x in 0..<width {
                let x0 = max(0, x - radius)
                let x1 = min(width - 1, x + radius)
                var peak: Float = 0
                for yy in y0...y1 {
                    let row = yy * width
                    for xx in x0...x1 {
                        peak = max(peak, mask.values[row + xx])
                    }
                }
                output.values[y * width + x] = peak
            }
        }
        return output
    }
}
