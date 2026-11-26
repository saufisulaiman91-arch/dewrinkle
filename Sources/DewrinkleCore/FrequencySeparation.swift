import Foundation

/// Radii as a fraction of the oriented short side, so a downscaled preview and
/// the 45 MP export agree in cycles-per-picture.
///
/// On a Nikon Z8 frame (short side 5504) the standard fractions are about
/// 8 px of weave, 66 px of fine wrinkles, and 165 px of coarse wrinkles.
/// Anything broader than the coarse radius — the fall of a hijab, an abaya's
/// drape, a bridal train — stays in the base layer and is not flattened.
public struct FrequencyScales: Equatable, Sendable {
    public var detailFraction: Float
    public var fineFraction: Float
    public var coarseFraction: Float

    public init(detailFraction: Float, fineFraction: Float, coarseFraction: Float) {
        self.detailFraction = detailFraction
        self.fineFraction = fineFraction
        self.coarseFraction = coarseFraction
    }

    public static let standard = FrequencyScales(
        detailFraction: 0.0014,
        fineFraction: 0.012,
        coarseFraction: 0.030
    )

    public func fullResolutionSigmas(shortSide: Int) -> FrequencySigmas {
        let side = Float(max(shortSide, 1))
        return FrequencySigmas(
            detail: max(0.35, detailFraction * side),
            fine: fineFraction * side,
            coarse: coarseFraction * side
        )
    }
}

public struct FrequencySigmas: Equatable, Sendable {
    public var detail: Float
    public var fine: Float
    public var coarse: Float

    public init(detail: Float, fine: Float, coarse: Float) {
        let detailRadius = max(0, detail)
        let fineRadius = max(detailRadius, fine)
        let coarseRadius = max(fineRadius, coarse)
        self.detail = detailRadius
        self.fine = fineRadius
        self.coarse = coarseRadius
    }
}

public struct DewrinkleParameters: Equatable, Sendable {
    /// How far crease shading moves toward the smooth cloth. 0.50 is the natural default.
    public var strength: Float
    /// How much of the fine-wrinkle band to remove. 0 keeps it, 1 removes it.
    public var fine: Float
    /// How much of the coarse-wrinkle band to remove.
    public var coarse: Float
    public var scales: FrequencyScales
    /// Full-resolution pixel overrides. Nil uses `scales`.
    public var detailRadiusOverride: Float?
    public var fineRadiusOverride: Float?
    public var coarseRadiusOverride: Float?
    /// 0 flattens broad folds. 1 keeps highlight and shadow that are wider than the coarse radius.
    public var preserveFolds: Float

    public init(
        strength: Float,
        fine: Float,
        coarse: Float,
        scales: FrequencyScales = .standard,
        detailRadiusOverride: Float? = nil,
        fineRadiusOverride: Float? = nil,
        coarseRadiusOverride: Float? = nil,
        preserveFolds: Float = 0
    ) {
        self.strength = strength
        self.fine = fine
        self.coarse = coarse
        self.scales = scales
        self.detailRadiusOverride = detailRadiusOverride
        self.fineRadiusOverride = fineRadiusOverride
        self.coarseRadiusOverride = coarseRadiusOverride
        self.preserveFolds = preserveFolds
    }

    /// Evoto-style default. 50 on clothing, fine lines, and deep folds.
    public static let standard = DewrinkleParameters(strength: 0.50, fine: 0.50, coarse: 0.50, preserveFolds: 0.75)
    public static let strong = DewrinkleParameters(strength: 1, fine: 1, coarse: 1, preserveFolds: 0.45)
    /// Same as the natural default. Opening a photo uses this.
    public static let detected = DewrinkleParameters(strength: 0.50, fine: 0.50, coarse: 0.50, preserveFolds: 0.75)

    public var fineKeep: Float { 1 - clamp01(fine) }
    public var coarseKeep: Float { 1 - clamp01(coarse) }
    /// How much of the broad fold band to keep. Preserve-folds pulls this back toward 1.
    public var foldKeep: Float { 1 - clamp01(coarse) * (1 - clamp01(preserveFolds)) }
    public var clampedStrength: Float { clamp01(strength) }

    /// `pixelScale` is workingShortSide / fullShortSide. Preview passes a
    /// fraction; export passes 1.
    public func resolvedSigmas(fullShortSide: Int, pixelScale: Float) -> FrequencySigmas {
        let automatic = scales.fullResolutionSigmas(shortSide: fullShortSide)
        let full = FrequencySigmas(
            detail: detailRadiusOverride ?? automatic.detail,
            fine: fineRadiusOverride ?? automatic.fine,
            coarse: coarseRadiusOverride ?? automatic.coarse
        )
        let scale = max(pixelScale, 0.0001)
        return FrequencySigmas(
            detail: full.detail * scale,
            fine: full.fine * scale,
            coarse: full.coarse * scale
        )
    }
}

public struct FrequencyBands: Sendable {
    public var high: RGBImage
    public var fine: RGBImage
    public var coarse: RGBImage
    public var base: RGBImage
}

public enum FrequencySeparation {
    /// Three Gaussians of the original. Bands sum back to the image:
    /// high + fine + coarse + base = original, including the high layer that
    /// holds weave and thread and is never edited on its own.
    public static func bands(of image: RGBImage, sigmas: FrequencySigmas) -> FrequencyBands {
        let detail = GaussianBlur.rgb(image, sigma: sigmas.detail)
        let fine = GaussianBlur.rgb(image, sigma: sigmas.fine)
        let coarse = GaussianBlur.rgb(image, sigma: sigmas.coarse)
        return FrequencyBands(
            high: subtract(image, detail),
            fine: subtract(detail, fine),
            coarse: subtract(fine, coarse),
            base: coarse
        )
    }

    public static func recombine(_ bands: FrequencyBands, fineKeep: Float, coarseKeep: Float) -> RGBImage {
        var output = bands.base
        for index in output.pixels.indices {
            output.pixels[index] = bands.base.pixels[index]
                + bands.coarse.pixels[index] * coarseKeep
                + bands.fine.pixels[index] * fineKeep
                + bands.high.pixels[index]
        }
        return output
    }

    public static func apply(
        _ image: RGBImage,
        mask: MaskBuffer,
        parameters: DewrinkleParameters,
        fullShortSide: Int? = nil,
        pixelScale: Float = 1,
        structure: StructureParameters? = nil
    ) -> RGBImage {
        let strength = parameters.clampedStrength
        if strength <= 0.00001 {
            return image
        }
        let aligned = mask.resized(toWidth: image.width, height: image.height)
        if aligned.maximum() <= 0.00001 {
            return image
        }

        let shortSide = fullShortSide ?? image.shortSide
        let sigmas = parameters.resolvedSigmas(fullShortSide: shortSide, pixelScale: pixelScale)
        let feather = GuidedMask.refine(
            aligned,
            guide: image.luminancePlane(),
            radius: max(1.25, Float(shortSide) * pixelScale * 0.004)
        )
        let luma = image.luminancePlane()
        let width = image.width
        let height = image.height
        let detail = GaussianBlur.plane(luma, width: width, height: height, sigma: sigmas.detail)
        let fine = GaussianBlur.plane(luma, width: width, height: height, sigma: sigmas.fine)
        let deep = GaussianBlur.plane(luma, width: width, height: height, sigma: sigmas.coarse)
        let baseSigma = max(sigmas.coarse * 2.8, sigmas.coarse + 1)
        let base = GaussianBlur.plane(luma, width: width, height: height, sigma: baseSigma)
        var lines = [Float](repeating: 0, count: luma.count)
        var grain = [Float](repeating: 0, count: luma.count)
        for index in luma.indices {
            lines[index] = detail[index] - fine[index]
            grain[index] = luma[index] - detail[index]
        }
        let ridge = lineStrength(lines, width: width, height: height)
        let peak = robustPeak(ridge, mask: feather.values)
        let grainLevel = GaussianBlur.plane(grain.map { abs($0) }, width: width, height: height, sigma: max(0.8, sigmas.fine * 0.35))
        let edges = StructureMask.gradientMagnitude(of: image)
        let fineAmount = clamp01(parameters.fine)
        let deepAmount = clamp01(parameters.coarse)
        let structureSoften = (1 - clamp01(parameters.preserveFolds)) * 0.55
        let protection = structure.map {
            StructureMask.make(image: image, parameters: $0)
        }

        var output = image
        for y in 0..<height {
            for x in 0..<width {
                let index = y * width + x
                var coverage = feather.values[index]
                if let protection {
                    coverage *= 1 - protection.values[index]
                }
                if coverage <= 0 { continue }
                let lineGate = smoothstep(peak * 0.22, peak * 0.55 + 1e-5, ridge[index])
                let contrast = smoothstep(grainLevel[index] * 1.4 + 0.008, grainLevel[index] * 2.6 + 0.028, abs(lines[index]))
                let fineGate = lineGate * contrast
                let folds = fine[index] - deep[index]
                let drape = deep[index] - base[index]
                let edgeWeight = 1 - smoothstep(0.035, 0.12, edges[index])
                let delta = (
                    -(lines[index] * fineGate + grain[index] * fineGate * 0.35) * fineAmount
                    - (folds * 0.9 + drape * structureSoften) * deepAmount
                ) * edgeWeight
                let pixel = image.offset(x, y)
                for channel in 0..<3 {
                    let shaded = image.pixels[pixel + channel] + delta
                    output.pixels[pixel + channel] = image.pixels[pixel + channel] * (1 - coverage) + clamp01(shaded) * coverage
                }
            }
        }
        return output
    }

    /// Line-like curvature. A crease scores high. Grain and a checker do not, because both Hessian eigenvalues are similar.
    static func lineStrength(_ plane: [Float], width: Int, height: Int) -> [Float] {
        var output = [Float](repeating: 0, count: plane.count)
        func at(_ x: Int, _ y: Int) -> Float {
            plane[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }
        for y in 0..<height {
            for x in 0..<width {
                let center = at(x, y)
                let ixx = at(x - 1, y) - 2 * center + at(x + 1, y)
                let iyy = at(x, y - 1) - 2 * center + at(x, y + 1)
                let ixy = (at(x + 1, y + 1) - at(x - 1, y + 1) - at(x + 1, y - 1) + at(x - 1, y - 1)) * 0.25
                let half = (ixx + iyy) * 0.5
                let root = sqrt(max(0, half * half - (ixx * iyy - ixy * ixy)))
                let major = max(abs(half + root), abs(half - root))
                let minor = min(abs(half + root), abs(half - root))
                output[y * width + x] = major * major / (major + minor + 1e-6)
            }
        }
        return output
    }

    private static func robustPeak(_ values: [Float], mask: [Float]) -> Float {
        var samples: [Float] = []
        samples.reserveCapacity(values.count / 4)
        for index in values.indices where mask[index] > 0.35 {
            samples.append(values[index])
        }
        if samples.isEmpty {
            samples = values
        }
        samples.sort()
        let index = min(samples.count - 1, max(0, Int((Float(samples.count - 1) * 0.97).rounded())))
        return max(samples[index], 1e-4)
    }

    static func subtract(_ a: RGBImage, _ b: RGBImage) -> RGBImage {
        var output = a
        for index in output.pixels.indices {
            output.pixels[index] = a.pixels[index] - b.pixels[index]
        }
        return output
    }
}
