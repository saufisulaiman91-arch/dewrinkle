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
    public static let stages = ["denoise", "dewrinkle"]
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

    /// Same order as `apply`, but luminance/chroma denoise is delegated to `model`
    /// when the noise panel is active. De-wrinkle stays classical.
    public static func apply(
        _ image: RGBImage,
        mask: MaskBuffer,
        parameters: EditParameters,
        model: MLDenoiseModel,
        fullShortSide: Int? = nil,
        pixelScale: Float = 1
    ) async throws -> RGBImage {
        let denoised: RGBImage
        if parameters.noise.isActive {
            let global = try await model.denoise(image, parameters: parameters.noise)
            if parameters.noise.limitToMask {
                denoised = NoiseReduction.mix(original: image, processed: global, mask: mask.resized(toWidth: image.width, height: image.height))
            } else {
                denoised = global
            }
        } else {
            denoised = image
        }
        return FrequencySeparation.apply(
            denoised,
            mask: mask,
            parameters: parameters.dewrinkle,
            fullShortSide: fullShortSide,
            pixelScale: pixelScale
        )
    }
}
