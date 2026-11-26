import Foundation

public struct EditParameters: Equatable, Sendable {
    public var dewrinkle: DewrinkleParameters
    public var noise: NoiseReductionParameters

    public init(dewrinkle: DewrinkleParameters, noise: NoiseReductionParameters) {
        self.dewrinkle = dewrinkle
        self.noise = noise
    }

    public static let standard = EditParameters(dewrinkle: .standard, noise: .off)
}

/// Denoise runs first so frequency separation is not asked to protect grain,
/// and so the high layer it puts back is weave rather than noise.
public enum ProcessingOrder {
    public static let stages = ["dewrinkle"]
}

public enum ImagePipeline {
    public static func apply(
        _ image: RGBImage,
        mask: MaskBuffer,
        parameters: EditParameters,
        fullShortSide: Int? = nil,
        pixelScale: Float = 1
    ) -> RGBImage {
        let denoised = NoiseReduction.apply(
            image,
            parameters: parameters.noise,
            mask: parameters.noise.limitToMask ? mask : nil,
            pixelScale: pixelScale
        )
        return FrequencySeparation.apply(
            denoised,
            mask: mask,
            parameters: parameters.dewrinkle,
            fullShortSide: fullShortSide,
            pixelScale: pixelScale
        )
    }
}
