import Foundation

/// Classical denoise, separate from de-wrinkle and off until an amount is raised.
/// Luminance uses an edge-aware bilateral so grain goes and seams stay.
/// Chroma is blurred on a quarter-resolution plane, the way color noise actually sits.
/// The 45 MP path is Core Image (`CINoiseReduction` on Y, Gaussian on downscaled chroma).
/// This type is the tested reference and the numbers the GPU mapping follows.
public struct NoiseReductionParameters: Equatable, Sendable {
    public var luminance: Float
    public var chroma: Float
    /// 0 lets edges melt into the denoise, 1 keeps weave and seams.
    public var detail: Float
    /// When true, only the garment/brush mask is denoised. Default is global.
    public var limitToMask: Bool

    public init(luminance: Float, chroma: Float, detail: Float, limitToMask: Bool) {
        self.luminance = luminance
        self.chroma = chroma
        self.detail = detail
        self.limitToMask = limitToMask
    }

    public static let off = NoiseReductionParameters(luminance: 0, chroma: 0, detail: 0.5, limitToMask: false)

    public var isActive: Bool {
        luminance > 0.0005 || chroma > 0.0005
    }

    public func resolved(pixelScale: Float = 1) -> ResolvedNoise {
        let luma = clamp01(luminance)
        let color = clamp01(chroma)
        let preserve = clamp01(detail)
        let scale = max(pixelScale, 0.02)
        let spatialFull = 0.55 + 1.35 * luma
        let range = 0.40 - 0.37 * preserve
        let chromaFull = 0.45 + 2.4 * color
        return ResolvedNoise(
            spatialSigma: max(0.2, spatialFull * scale),
            rangeSigma: max(0.008, range),
            chromaSigmaLowRes: max(0.15, chromaFull * scale),
            lumaMix: luma,
            chromaMix: color,
            ciNoiseLevel: 0.012 + 0.058 * luma,
            ciSharpness: 0.05 + 1.15 * preserve
        )
    }
}

public struct ResolvedNoise: Equatable, Sendable {
    public var spatialSigma: Float
    public var rangeSigma: Float
    public var chromaSigmaLowRes: Float
    public var lumaMix: Float
    public var chromaMix: Float
    /// `CINoiseReduction` inputNoiseLevel for the luminance plane.
    public var ciNoiseLevel: Float
    /// `CINoiseReduction` inputSharpness. Higher detail preserves more.
    public var ciSharpness: Float
}

public enum YCbCr {
    public static func fromRGB(r: Float, g: Float, b: Float) -> (y: Float, cb: Float, cr: Float) {
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        let cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 0.5
        let cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 0.5
        return (y, cb, cr)
    }

    public static func toRGB(y: Float, cb: Float, cr: Float) -> (r: Float, g: Float, b: Float) {
        let cbShift = cb - 0.5
        let crShift = cr - 0.5
        let r = y + 1.402 * crShift
        let g = y - 0.344136 * cbShift - 0.714136 * crShift
        let b = y + 1.772 * cbShift
        return (r, g, b)
    }
}

/// Future Core ML denoiser. Assign `DenoiseSlot.shared.model`.
/// The model should denoise the whole frame. When "limit to mask" is on, the
/// pipeline blends the model output back with the original outside the mask,
/// so the model itself can stay global.
public protocol MLDenoiseModel: AnyObject {
    var displayName: String { get }
    func denoise(_ image: RGBImage, parameters: NoiseReductionParameters) async throws -> RGBImage
}

public final class DenoiseSlot: @unchecked Sendable {
    public static let shared = DenoiseSlot()
    private let lock = NSLock()
    private var installed: MLDenoiseModel?

    public var model: MLDenoiseModel? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return installed
        }
        set {
            lock.lock()
            installed = newValue
            lock.unlock()
        }
    }

    public var usesCoreML: Bool { model != nil }

    private init() {}
}

public enum NoiseReduction {
    public static func apply(
        _ image: RGBImage,
        parameters: NoiseReductionParameters,
        mask: MaskBuffer?,
        pixelScale: Float = 1
    ) -> RGBImage {
        guard parameters.isActive else { return image }
        let resolved = parameters.resolved(pixelScale: pixelScale)
        let count = image.pixelCount
        var luma = [Float](repeating: 0, count: count)
        var cb = [Float](repeating: 0, count: count)
        var cr = [Float](repeating: 0, count: count)
        var source = 0
        for index in 0..<count {
            let converted = YCbCr.fromRGB(
                r: image.pixels[source],
                g: image.pixels[source + 1],
                b: image.pixels[source + 2]
            )
            luma[index] = converted.y
            cb[index] = converted.cb
            cr[index] = converted.cr
            source += 3
        }

        if resolved.lumaMix > 0 {
            let smoothed = bilateral(
                luma,
                width: image.width,
                height: image.height,
                spatialSigma: resolved.spatialSigma,
                rangeSigma: resolved.rangeSigma
            )
            let mix = resolved.lumaMix
            for index in 0..<count {
                luma[index] = luma[index] * (1 - mix) + smoothed[index] * mix
            }
        }

        if resolved.chromaMix > 0 {
            cb = blurChroma(cb, width: image.width, height: image.height, sigma: resolved.chromaSigmaLowRes, mix: resolved.chromaMix)
            cr = blurChroma(cr, width: image.width, height: image.height, sigma: resolved.chromaSigmaLowRes, mix: resolved.chromaMix)
        }

        var output = image
        var destination = 0
        for index in 0..<count {
            let rgb = YCbCr.toRGB(y: luma[index], cb: cb[index], cr: cr[index])
            output.pixels[destination] = clamp01(rgb.r)
            output.pixels[destination + 1] = clamp01(rgb.g)
            output.pixels[destination + 2] = clamp01(rgb.b)
            destination += 3
        }

        guard parameters.limitToMask else { return output }
        let coverage = (mask ?? MaskBuffer(width: image.width, height: image.height, fill: 0))
            .resized(toWidth: image.width, height: image.height)
        return mix(original: image, processed: output, mask: coverage)
    }

    static func mix(original: RGBImage, processed: RGBImage, mask: MaskBuffer) -> RGBImage {
        var output = original
        let width = original.width
        for y in 0..<original.height {
            for x in 0..<width {
                let coverage = mask.values[y * width + x]
                if coverage <= 0 { continue }
                if coverage >= 1 {
                    let index = original.offset(x, y)
                    output.pixels[index] = processed.pixels[index]
                    output.pixels[index + 1] = processed.pixels[index + 1]
                    output.pixels[index + 2] = processed.pixels[index + 2]
                    continue
                }
                let index = original.offset(x, y)
                for channel in 0..<3 {
                    output.pixels[index + channel] = original.pixels[index + channel] * (1 - coverage)
                        + processed.pixels[index + channel] * coverage
                }
            }
        }
        return output
    }

    static func blurChroma(_ plane: [Float], width: Int, height: Int, sigma: Float, mix: Float) -> [Float] {
        let factor = width >= 96 ? 4 : 2
        let reduced = downsample(plane, width: width, height: height, factor: factor)
        let blurred = GaussianBlur.plane(reduced.data, width: reduced.width, height: reduced.height, sigma: sigma)
        let upsampled = upsample(
            blurred,
            width: reduced.width,
            height: reduced.height,
            toWidth: width,
            toHeight: height
        )
        var output = plane
        let amount = clamp01(mix)
        for index in output.indices {
            output[index] = plane[index] * (1 - amount) + upsampled[index] * amount
        }
        return output
    }

    static func bilateral(
        _ plane: [Float],
        width: Int,
        height: Int,
        spatialSigma: Float,
        rangeSigma: Float
    ) -> [Float] {
        let radius = max(1, Int((spatialSigma * 2).rounded(.up)))
        let spatialDenom = max(0.0001, 2 * spatialSigma * spatialSigma)
        let rangeDenom = max(0.000001, 2 * rangeSigma * rangeSigma)
        var output = [Float](repeating: 0, count: plane.count)
        for y in 0..<height {
            for x in 0..<width {
                let center = plane[y * width + x]
                var accumulator: Float = 0
                var weightSum: Float = 0
                for dy in -radius...radius {
                    let sampleY = min(max(y + dy, 0), height - 1)
                    for dx in -radius...radius {
                        let sampleX = min(max(x + dx, 0), width - 1)
                        let sample = plane[sampleY * width + sampleX]
                        let spatial = Float(dx * dx + dy * dy)
                        let delta = sample - center
                        let weight = exp(-spatial / spatialDenom - (delta * delta) / rangeDenom)
                        accumulator += sample * weight
                        weightSum += weight
                    }
                }
                output[y * width + x] = accumulator / weightSum
            }
        }
        return output
    }

    static func downsample(_ plane: [Float], width: Int, height: Int, factor: Int) -> (data: [Float], width: Int, height: Int) {
        let step = max(1, factor)
        let newWidth = max(1, width / step)
        let newHeight = max(1, height / step)
        var output = [Float](repeating: 0, count: newWidth * newHeight)
        for y in 0..<newHeight {
            for x in 0..<newWidth {
                var accumulator: Float = 0
                var count: Float = 0
                for dy in 0..<step {
                    let sampleY = min(y * step + dy, height - 1)
                    for dx in 0..<step {
                        let sampleX = min(x * step + dx, width - 1)
                        accumulator += plane[sampleY * width + sampleX]
                        count += 1
                    }
                }
                output[y * newWidth + x] = accumulator / count
            }
        }
        return (output, newWidth, newHeight)
    }

    static func upsample(_ plane: [Float], width: Int, height: Int, toWidth: Int, toHeight: Int) -> [Float] {
        if width == toWidth && height == toHeight { return plane }
        var output = [Float](repeating: 0, count: toWidth * toHeight)
        for y in 0..<toHeight {
            let gy = (Float(y) + 0.5) / Float(toHeight) * Float(height) - 0.5
            for x in 0..<toWidth {
                let gx = (Float(x) + 0.5) / Float(toWidth) * Float(width) - 0.5
                output[y * toWidth + x] = bilinear(plane, width: width, height: height, x: gx, y: gy)
            }
        }
        return output
    }

    static func bilinear(_ plane: [Float], width: Int, height: Int, x: Float, y: Float) -> Float {
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let tx = x - Float(x0)
        let ty = y - Float(y0)
        func at(_ sx: Int, _ sy: Int) -> Float {
            let xx = min(max(sx, 0), width - 1)
            let yy = min(max(sy, 0), height - 1)
            return plane[yy * width + xx]
        }
        let top = at(x0, y0) + (at(x0 + 1, y0) - at(x0, y0)) * tx
        let bottom = at(x0, y0 + 1) + (at(x0 + 1, y0 + 1) - at(x0, y0 + 1)) * tx
        return top + (bottom - top) * ty
    }
}
