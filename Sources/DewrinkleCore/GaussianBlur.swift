import Foundation

/// Separable Gaussian with edge clamping. Weights are normalized, so a flat
/// field is unchanged. This is the reference blur: the Mac path uses
/// `CIGaussianBlur` with the same sigma and must not switch to a bilateral
/// or edge-preserving blur, which would keep the crease edges we want to lose.
public enum GaussianBlur {
    public static func kernel(sigma: Float) -> [Float] {
        if sigma < 0.18 {
            return [1]
        }
        let radius = max(1, Int((sigma * 3).rounded(.up)))
        var weights = [Float](repeating: 0, count: radius * 2 + 1)
        let twoSigmaSquared = 2 * sigma * sigma
        var sum: Float = 0
        for offset in -radius...radius {
            let weight = exp(-Float(offset * offset) / twoSigmaSquared)
            weights[offset + radius] = weight
            sum += weight
        }
        let inverse = 1 / sum
        for index in weights.indices {
            weights[index] *= inverse
        }
        return weights
    }

    public static func plane(_ source: [Float], width: Int, height: Int, sigma: Float) -> [Float] {
        precondition(source.count == width * height)
        let weights = kernel(sigma: sigma)
        if weights.count == 1 {
            return source
        }
        let radius = weights.count / 2
        var horizontal = [Float](repeating: 0, count: source.count)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                var accumulator: Float = 0
                for offset in -radius...radius {
                    let sampleX = min(max(x + offset, 0), width - 1)
                    accumulator += source[row + sampleX] * weights[offset + radius]
                }
                horizontal[row + x] = accumulator
            }
        }
        var vertical = [Float](repeating: 0, count: source.count)
        for y in 0..<height {
            for x in 0..<width {
                var accumulator: Float = 0
                for offset in -radius...radius {
                    let sampleY = min(max(y + offset, 0), height - 1)
                    accumulator += horizontal[sampleY * width + x] * weights[offset + radius]
                }
                vertical[y * width + x] = accumulator
            }
        }
        return vertical
    }

    public static func rgb(_ image: RGBImage, sigma: Float) -> RGBImage {
        let count = image.pixelCount
        var red = [Float](repeating: 0, count: count)
        var green = [Float](repeating: 0, count: count)
        var blue = [Float](repeating: 0, count: count)
        var source = 0
        for index in 0..<count {
            red[index] = image.pixels[source]
            green[index] = image.pixels[source + 1]
            blue[index] = image.pixels[source + 2]
            source += 3
        }
        red = plane(red, width: image.width, height: image.height, sigma: sigma)
        green = plane(green, width: image.width, height: image.height, sigma: sigma)
        blue = plane(blue, width: image.width, height: image.height, sigma: sigma)
        var pixels = [Float](repeating: 0, count: count * 3)
        var destination = 0
        for index in 0..<count {
            pixels[destination] = red[index]
            pixels[destination + 1] = green[index]
            pixels[destination + 2] = blue[index]
            destination += 3
        }
        return RGBImage(width: image.width, height: image.height, pixels: pixels)
    }

    public static func mask(_ mask: MaskBuffer, sigma: Float) -> MaskBuffer {
        var blurred = mask
        blurred.values = plane(mask.values, width: mask.width, height: mask.height, sigma: sigma)
        for index in blurred.values.indices {
            blurred.values[index] = clamp01(blurred.values[index])
        }
        return blurred
    }
}
