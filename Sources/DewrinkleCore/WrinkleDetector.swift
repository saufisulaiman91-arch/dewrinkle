import Foundation

/// Finds crease shading on cloth. A ridge/valley filter runs on the mid-frequency
/// luminance band, then embroidery, beading, seams, and hems are gated out.
public enum WrinkleDetector {
    public struct Settings: Equatable, Sendable {
        /// 0 marks only the strongest creases. 1 marks faint ones too.
        public var sensitivity: Float

        public init(sensitivity: Float = 0.58) {
            self.sensitivity = clamp01(sensitivity)
        }
    }

    /// `clothing` is the cloth that may be smoothed: person minus skin, face, and
    /// hands, and minus the hijab unless the caller already included it.
    public static func mask(image: RGBImage, clothing: MaskBuffer, settings: Settings = Settings()) -> MaskBuffer {
        let working = fitted(image)
        let cloth = clothing.resized(toWidth: working.width, height: working.height)
        let detected = ridges(in: working, clothing: cloth, settings: settings)
        return detected.resized(toWidth: image.width, height: image.height)
    }

    /// Mean absolute mid-band luminance inside `region`. This is the crease energy
    /// the skirt should lose and the embroidered panel should barely have.
    public static func creaseEnergy(of image: RGBImage, region: MaskBuffer) -> Float {
        let working = fitted(image)
        let gate = region.resized(toWidth: working.width, height: working.height)
        let luma = working.luminancePlane()
        let side = Float(working.shortSide)
        let detail = GaussianBlur.plane(luma, width: working.width, height: working.height, sigma: max(0.8, 0.0016 * side))
        let wide = GaussianBlur.plane(luma, width: working.width, height: working.height, sigma: max(6, 0.040 * side))
        var energy: Float = 0
        var weight: Float = 0
        for index in luma.indices where gate.values[index] > 0.5 {
            energy += abs(detail[index] - wide[index])
            weight += 1
        }
        guard weight > 0 else { return 0 }
        return energy / weight
    }

    private static func ridges(in image: RGBImage, clothing: MaskBuffer, settings: Settings) -> MaskBuffer {
        let width = image.width
        let height = image.height
        let luma = image.luminancePlane()
        let side = Float(image.shortSide)
        let detailSigma = max(0.8, 0.0016 * side)
        let midSigma = max(2.4, 0.012 * side)
        let wideSigma = max(midSigma * 2.4, 0.040 * side)
        let detail = GaussianBlur.plane(luma, width: width, height: height, sigma: detailSigma)
        let wide = GaussianBlur.plane(luma, width: width, height: height, sigma: wideSigma)
        var band = [Float](repeating: 0, count: luma.count)
        var grain = [Float](repeating: 0, count: luma.count)
        for index in luma.indices {
            band[index] = detail[index] - wide[index]
            grain[index] = abs(luma[index] - detail[index])
        }
        let score = hessianLineStrength(band, width: width, height: height)
        let density = GaussianBlur.plane(grain, width: width, height: height, sigma: max(2.8, midSigma * 0.75))
        let sharp = gradientMagnitude(detail, width: width, height: height)
        let slope = gradientMagnitude(band, width: width, height: height)
        let cloth = clothing.values

        let texRef = max(0.01, percentile(density, mask: cloth, fraction: 0.60))
        let slopePeak = max(percentile(slope, mask: cloth, fraction: 0.98), 1e-4)
        var exclusion = MaskBuffer(width: width, height: height, fill: 0)
        // A seam or hem is a steep step. A crease center is curved but not steep.
        let sharpCut: Float = 0.09
        for index in sharp.indices where cloth[index] > 0.4 && sharp[index] > sharpCut {
            exclusion.values[index] = 1
        }
        exclusion = StructureMask.dilate(exclusion, radius: max(2, Int((midSigma * 0.45).rounded())))

        var gated = [Float](repeating: 0, count: score.count)
        for index in score.indices {
            let texture = 1 - smoothstep(texRef * 2.8, texRef * 4.6, density[index])
            let edge = 1 - exclusion.values[index]
            let alongTheLine = 1 - smoothstep(slopePeak * 0.18, slopePeak * 0.5, slope[index])
            gated[index] = score[index] * texture * edge * alongTheLine * cloth[index]
        }
        let peak = percentile(gated, mask: cloth, fraction: 0.995)
        guard peak > 1e-5 else {
            return MaskBuffer(width: width, height: height, fill: 0)
        }
        let threshold = peak * (0.62 - 0.48 * settings.sensitivity)
        let knee = peak * 0.08
        var ridge = MaskBuffer(width: width, height: height, fill: 0)
        for index in gated.indices {
            ridge.values[index] = smoothstep(threshold - knee, threshold + knee, gated[index])
        }
        ridge = StructureMask.dilate(ridge, radius: max(1, Int((midSigma * 0.45).rounded())))
        ridge = GaussianBlur.mask(ridge, sigma: max(0.8, midSigma * 0.28))
        for index in ridge.values.indices {
            let texture = 1 - smoothstep(texRef * 2.8, texRef * 4.6, density[index])
            ridge.values[index] *= texture * (1 - exclusion.values[index]) * cloth[index]
        }
        return ridge
    }

    /// Larger absolute Hessian eigenvalue, suppressed when both eigenvalues are
    /// similar (a blob or a broad fold) so a line-like crease scores higher.
    private static func hessianLineStrength(_ plane: [Float], width: Int, height: Int) -> [Float] {
        var output = [Float](repeating: 0, count: plane.count)
        func at(_ x: Int, _ y: Int) -> Float {
            plane[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }
        for y in 0..<height {
            for x in 0..<width {
                let center = at(x, y)
                let ixx = at(x + 1, y) - 2 * center + at(x - 1, y)
                let iyy = at(x, y + 1) - 2 * center + at(x, y - 1)
                let ixy = (at(x + 1, y + 1) - at(x - 1, y + 1) - at(x + 1, y - 1) + at(x - 1, y - 1)) * 0.25
                let half = (ixx + iyy) * 0.5
                let root = sqrt(max(0, half * half - (ixx * iyy - ixy * ixy)))
                let first = abs(half + root)
                let second = abs(half - root)
                let major = max(first, second)
                let minor = min(first, second)
                output[y * width + x] = major * major / (major + minor + 1e-6)
            }
        }
        return output
    }

    private static func gradientMagnitude(_ plane: [Float], width: Int, height: Int) -> [Float] {
        var magnitude = [Float](repeating: 0, count: plane.count)
        func at(_ x: Int, _ y: Int) -> Float {
            plane[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }
        for y in 0..<height {
            for x in 0..<width {
                let gx = at(x + 1, y) - at(x - 1, y)
                let gy = at(x, y + 1) - at(x, y - 1)
                magnitude[y * width + x] = hypot(gx, gy) * 0.5
            }
        }
        return magnitude
    }

    private static func percentile(_ values: [Float], mask: [Float], fraction: Float) -> Float {
        var samples: [Float] = []
        samples.reserveCapacity(values.count / 3)
        for index in values.indices where mask[index] > 0.5 {
            samples.append(values[index])
        }
        guard !samples.isEmpty else { return 0 }
        samples.sort()
        let index = min(samples.count - 1, max(0, Int((Float(samples.count - 1) * clamp01(fraction)).rounded())))
        return samples[index]
    }

    private static func fitted(_ image: RGBImage) -> RGBImage {
        let longSide = max(image.width, image.height)
        guard longSide > 960 else { return image }
        let scale = 960 / Float(longSide)
        let width = max(1, Int((Float(image.width) * scale).rounded()))
        let height = max(1, Int((Float(image.height) * scale).rounded()))
        var output = RGBImage(width: width, height: height, fill: 0)
        for y in 0..<height {
            let v = (Float(y) + 0.5) / Float(height)
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width)
                let sample = bilinear(image, u: u, v: v)
                output.setPixel(x, y, r: sample.0, g: sample.1, b: sample.2)
            }
        }
        return output
    }

    private static func bilinear(_ image: RGBImage, u: Float, v: Float) -> (Float, Float, Float) {
        let x = min(max(u * Float(image.width) - 0.5, 0), Float(image.width - 1))
        let y = min(max(v * Float(image.height) - 0.5, 0), Float(image.height - 1))
        let x0 = Int(x)
        let y0 = Int(y)
        let x1 = min(x0 + 1, image.width - 1)
        let y1 = min(y0 + 1, image.height - 1)
        let tx = x - Float(x0)
        let ty = y - Float(y0)
        func pixel(_ px: Int, _ py: Int) -> (Float, Float, Float) {
            let index = image.offset(px, py)
            return (image.pixels[index], image.pixels[index + 1], image.pixels[index + 2])
        }
        let a = pixel(x0, y0)
        let b = pixel(x1, y0)
        let c = pixel(x0, y1)
        let d = pixel(x1, y1)
        func mix(_ p: Float, _ q: Float, _ r: Float, _ s: Float) -> Float {
            let top = p + (q - p) * tx
            let bottom = r + (s - r) * tx
            return top + (bottom - top) * ty
        }
        return (mix(a.0, b.0, c.0, d.0), mix(a.1, b.1, c.1, d.1), mix(a.2, b.2, c.2, d.2))
    }
}
