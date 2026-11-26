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

    /// Natural: ease crease shading, keep satin sheen and the drape.
    public static let standard = DewrinkleParameters(strength: 0.50, fine: 0.62, coarse: 0.18, preserveFolds: 0.75)
    public static let strong = DewrinkleParameters(strength: 0.72, fine: 0.85, coarse: 0.48, preserveFolds: 0.15)
    /// Automatic creases. The mid band is lifted inside the detected mask. Body shading, wider than the coarse radius, stays.
    public static let detected = DewrinkleParameters(
        strength: 0.96,
        fine: 1,
        coarse: 0.7,
        scales: FrequencyScales(detailFraction: 0.0014, fineFraction: 0.020, coarseFraction: 0.062),
        preserveFolds: 0.58
    )

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
        let gray = RGBImage(lumaOf: image)
        let corrected = recombine(
            bands(of: gray, sigmas: sigmas),
            fineKeep: parameters.fineKeep,
            coarseKeep: parameters.foldKeep
        )
        let protection = StructureMask.make(
            image: image,
            parameters: structure ?? .resolved(fullShortSide: shortSide, pixelScale: pixelScale)
        )

        var output = image
        let width = image.width
        for y in 0..<image.height {
            for x in 0..<width {
                let coverage = feather.values[y * width + x] * (1 - protection.values[y * width + x])
                if coverage <= 0 { continue }
                let index = image.offset(x, y)
                let originalY = 0.299 * image.pixels[index] + 0.587 * image.pixels[index + 1] + 0.114 * image.pixels[index + 2]
                let delta = (corrected.pixels[index] - originalY) * strength
                for channel in 0..<3 {
                    let shaded = image.pixels[index + channel] + delta
                    let blended = image.pixels[index + channel] * (1 - coverage) + clamp01(shaded) * coverage
                    output.pixels[index + channel] = blended
                }
            }
        }
        return output
    }

    static func subtract(_ a: RGBImage, _ b: RGBImage) -> RGBImage {
        var output = a
        for index in output.pixels.indices {
            output.pixels[index] = a.pixels[index] - b.pixels[index]
        }
        return output
    }
}
