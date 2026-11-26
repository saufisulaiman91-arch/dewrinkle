import CoreImage
import CoreGraphics
import Foundation
import DewrinkleCore

enum RenderError: LocalizedError {
    case kernel(String)
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .kernel(let message):
            return message
        case .renderFailed:
            return "The full-resolution render failed."
        }
    }
}

/// Core Image's bitmap origin is the bottom-left. `MaskBuffer`, the canvas, and
/// export all use a top-left first row. The probe measures which row
/// `render(toBitmap:)` actually writes first on this OS, so a portrait JPEG
/// is not stored upside down.
enum BitmapLayout {
    static let rowsAreTopFirst: Bool = probe()

    /// A 1×2 image whose first stored row is red and whose second row is blue.
    /// If `render(toBitmap:)` returns red first, that API is already top-left.
    private static func probe() -> Bool {
        var bytes: [UInt8] = [
            255, 0, 0, 255,
            0, 0, 255, 255
        ]
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let cgImage = CGImage(
                width: 1,
                height: 2,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return true
        }
        let context = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull()
        ])
        var pixels = [Float](repeating: 0, count: 8)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(
                CIImage(cgImage: cgImage),
                toBitmap: base,
                rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 2),
                format: .RGBAf,
                colorSpace: nil
            )
        }
        return pixels[0] > 0.5 && pixels[0] > pixels[2]
    }
}

enum ImageGeometry {
    /// Applies turns in order. Coordinates match `PictureTurn` (top-left, y down)
    /// once the bitmap is read back with the pipeline's row order.
    static func apply(_ turns: [PictureTurn], to image: CIImage) -> CIImage {
        var result = image
        for turn in turns {
            result = apply(turn, to: result)
        }
        return result
    }

    static func apply(_ turn: PictureTurn, to image: CIImage) -> CIImage {
        let extent = image.extent
        let width = extent.width
        let height = extent.height
        let moved = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
        let turned: CIImage
        switch turn {
        case .flipHorizontal:
            turned = moved.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
        case .flipVertical:
            turned = moved.transformed(by: CGAffineTransform(scaleX: 1, y: -1))
        case .clockwise:
            // Clockwise in a y-up plane: (x, y) -> (y, width - x).
            turned = moved.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2).translatedBy(x: 0, y: width))
        case .counterClockwise:
            turned = moved.transformed(by: CGAffineTransform(rotationAngle: .pi / 2).translatedBy(x: height, y: 0))
        }
        let origin = turned.extent.origin
        return turned.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }
}

struct RenderPass: Sendable {
    var mask: MaskBuffer
    var edits: EditParameters
    var opacity: Float
}

enum CIGraph {
    static func process(
        image: CIImage,
        mask: CIImage,
        edits: EditParameters,
        fullShortSide: Int,
        pixelScale: Float
    ) throws -> CIImage {
        let denoised = try denoise(
            image: image,
            parameters: edits.noise,
            mask: edits.noise.limitToMask ? mask : nil,
            pixelScale: pixelScale
        )
        return try dewrinkle(
            image: denoised,
            mask: mask,
            parameters: edits.dewrinkle,
            fullShortSide: fullShortSide,
            pixelScale: pixelScale
        )
    }

    static func denoise(
        image: CIImage,
        parameters: NoiseReductionParameters,
        mask: CIImage?,
        pixelScale: Float
    ) throws -> CIImage {
        guard parameters.isActive else { return image }
        let kernels = KernelLibrary.shared
        guard let assemble = kernels.denoiseAssemble, let blend = kernels.blendMask else {
            throw RenderError.kernel("The denoise kernel failed to compile.")
        }
        let resolved = parameters.resolved(pixelScale: pixelScale)
        let extent = image.extent
        let lumaSource = lumaImage(image)
        let lumaDenoised: CIImage
        if resolved.lumaMix > 0.0005, CIFilter(name: "CINoiseReduction") != nil {
            lumaDenoised = lumaSource.applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": resolved.ciNoiseLevel,
                "inputSharpness": resolved.ciSharpness
            ]).cropped(to: extent)
        } else {
            lumaDenoised = lumaSource
        }

        let chromaSoft: CIImage
        if resolved.chromaMix > 0.0005 {
            chromaSoft = blurredChroma(image, sigma: CGFloat(resolved.chromaSigmaLowRes), extent: extent)
        } else {
            chromaSoft = image
        }

        guard let assembled = assemble.apply(extent: extent, arguments: [
            image,
            lumaDenoised,
            chromaSoft,
            NSNumber(value: resolved.lumaMix),
            NSNumber(value: resolved.chromaMix)
        ]) else {
            throw RenderError.renderFailed
        }
        let finite = assembled.cropped(to: extent)
        guard parameters.limitToMask, let mask else { return finite }
        let fitted = scale(mask, to: extent)
        guard let blended = blend.apply(extent: extent, arguments: [image, finite, fitted]) else {
            throw RenderError.renderFailed
        }
        return blended.cropped(to: extent)
    }

    static func dewrinkle(
        image: CIImage,
        mask: CIImage,
        parameters: DewrinkleParameters,
        fullShortSide: Int,
        pixelScale: Float
    ) throws -> CIImage {
        if parameters.clampedStrength <= 0.00001 {
            return image
        }
        let kernels = KernelLibrary.shared
        guard let recombine = kernels.recombine, let effect = kernels.effectMask else {
            throw RenderError.kernel("The de-wrinkle kernel failed to compile.")
        }
        let extent = image.extent
        let sigmas = parameters.resolvedSigmas(fullShortSide: fullShortSide, pixelScale: pixelScale)
        let detail = blur(image, sigma: CGFloat(sigmas.detail), extent: extent)
        let fine = blur(image, sigma: CGFloat(sigmas.fine), extent: extent)
        let coarse = blur(image, sigma: CGFloat(sigmas.coarse), extent: extent)
        let structureParameters = StructureParameters.resolved(fullShortSide: fullShortSide, pixelScale: pixelScale)
        let protect = structure(of: image, parameters: structureParameters, extent: extent)
        let garment = scale(mask, to: extent)
        guard let effectMask = effect.apply(extent: extent, arguments: [
            garment,
            protect,
            NSNumber(value: parameters.clampedStrength)
        ]) else {
            throw RenderError.renderFailed
        }
        guard let output = recombine.apply(extent: extent, arguments: [
            image,
            detail,
            fine,
            coarse,
            effectMask,
            NSNumber(value: parameters.fineKeep),
            NSNumber(value: parameters.coarseKeep)
        ]) else {
            throw RenderError.renderFailed
        }
        return output.cropped(to: extent)
    }

    static func blur(_ image: CIImage, sigma: CGFloat, extent: CGRect) -> CIImage {
        if sigma < 0.15 { return image }
        return image
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: sigma])
            .cropped(to: extent)
    }

    static func structure(of image: CIImage, parameters: StructureParameters, extent: CGRect) -> CIImage {
        guard let kernel = KernelLibrary.shared.structure else {
            return black(extent)
        }
        let edges = kernel.apply(
            extent: extent,
            roiCallback: { _, rect in rect.insetBy(dx: -2, dy: -2) },
            arguments: [
                image,
                NSNumber(value: parameters.edgeLow),
                NSNumber(value: parameters.edgeHigh)
            ]
        )?.cropped(to: extent) ?? black(extent)
        var result = edges
        if parameters.dilatePixels >= 0.5, CIFilter(name: "CIMorphologyMaximum") != nil {
            result = edges
                .clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": parameters.dilatePixels])
                .cropped(to: extent)
        }
        if parameters.featherPixels >= 0.25 {
            result = result
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: parameters.featherPixels])
                .cropped(to: extent)
        }
        return result
    }

    static func lumaImage(_ image: CIImage) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
            "inputGVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
            "inputBVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)
        ])
    }

    /// Quarter-res (or half, on a small preview) Gaussian on the color, then back up.
    /// Luminance is restored later by `denoiseAssemble`.
    static func blurredChroma(_ image: CIImage, sigma: CGFloat, extent: CGRect) -> CIImage {
        let factor: CGFloat = min(extent.width, extent.height) >= 900 ? 0.25 : 0.5
        let small = scale(image, by: factor)
        let blurred = blur(small, sigma: max(sigma, 0.15), extent: small.extent)
        return scale(blurred, to: extent)
    }

    static func scale(_ image: CIImage, by factor: CGFloat) -> CIImage {
        guard let filter = CIFilter(name: "CILanczosScaleTransform") else {
            return image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
        }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(factor, forKey: kCIInputScaleKey)
        filter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        return filter.outputImage ?? image
    }

    static func scale(_ image: CIImage, to extent: CGRect) -> CIImage {
        let source = image.extent
        guard source.width > 1, source.height > 1, extent.width > 1, extent.height > 1 else {
            return black(extent)
        }
        let normalized = image.transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
        let scaled = normalized.transformed(by: CGAffineTransform(
            scaleX: extent.width / source.width,
            y: extent.height / source.height
        ))
        let placed = scaled.transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return placed.cropped(to: extent)
    }

    static func black(_ extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: extent)
    }

    static func maskImage(_ mask: MaskBuffer) -> CIImage {
        guard let cg = CGBridge.grayImage(mask) else { return black(CGRect(x: 0, y: 0, width: 1, height: 1)) }
        return CIImage(cgImage: cg)
    }
}

final class RenderPipeline: @unchecked Sendable {
    private let context: CIContext
    private let lock = NSLock()

    init() {
        context = CIContext(options: [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
            .useSoftwareRenderer: false
        ])
    }

    func renderPreview(
        source: CIImage,
        mask: MaskBuffer,
        edits: EditParameters,
        fullShortSide: Int,
        pixelScale: Float
    ) throws -> CGImage {
        let extent = source.extent.integral
        let width = max(Int(extent.width), 1)
        let height = max(Int(extent.height), 1)
        let rgba = try renderRGBA(
            source: source,
            mask: mask,
            edits: edits,
            fullShortSide: fullShortSide,
            pixelScale: pixelScale,
            width: width,
            height: height
        )
        guard let image = CGBridge.displayImage(rgba: rgba, width: width, height: height) else {
            throw RenderError.renderFailed
        }
        return image
    }

    func renderStackedPreview(
        source: CIImage,
        passes: [RenderPass],
        fullShortSide: Int,
        pixelScale: Float
    ) throws -> CGImage {
        let extent = source.extent.integral
        let width = max(Int(extent.width), 1)
        let height = max(Int(extent.height), 1)
        let rgba = try renderStacked(
            source: source,
            passes: passes,
            fullShortSide: fullShortSide,
            pixelScale: pixelScale,
            width: width,
            height: height
        )
        guard let image = CGBridge.displayImage(rgba: rgba, width: width, height: height) else {
            throw RenderError.renderFailed
        }
        return image
    }

    func renderStackedExport(
        source: CIImage,
        passes: [RenderPass],
        fullShortSide: Int,
        width: Int,
        height: Int
    ) throws -> [Float] {
        try renderStacked(
            source: source,
            passes: passes,
            fullShortSide: fullShortSide,
            pixelScale: 1,
            width: width,
            height: height
        )
    }

    func renderExport(
        source: CIImage,
        mask: MaskBuffer,
        edits: EditParameters,
        fullShortSide: Int,
        width: Int,
        height: Int
    ) throws -> [Float] {
        try renderRGBA(
            source: source,
            mask: mask,
            edits: edits,
            fullShortSide: fullShortSide,
            pixelScale: 1,
            width: width,
            height: height
        )
    }

    /// Classical graph, or `DenoiseSlot`'s Core ML model when one is installed.
    /// The model runs before de-wrinkle. Do not call this from the main thread when a
    /// model is installed: the wait below would deadlock if the model needs main.
    private func renderRGBA(
        source: CIImage,
        mask: MaskBuffer,
        edits: EditParameters,
        fullShortSide: Int,
        pixelScale: Float,
        width: Int,
        height: Int
    ) throws -> [Float] {
        let maskImage = CIGraph.maskImage(mask)
        var working = prepared(source, width: width, height: height)
        if edits.noise.isActive, let model = DenoiseSlot.shared.model {
            let rgb = try rgbImage(from: working, width: width, height: height)
            let denoised = try Self.awaitModel(model, image: rgb, parameters: edits.noise)
            var replaced = CIGraph.scale(ciImage(from: denoised), to: working.extent)
            if edits.noise.limitToMask, let blend = KernelLibrary.shared.blendMask {
                replaced = blend.apply(extent: working.extent, arguments: [working, replaced, maskImage])?.cropped(to: working.extent) ?? replaced
            }
            var withoutNoise = edits
            withoutNoise.noise = .off
            working = try CIGraph.process(
                image: replaced,
                mask: maskImage,
                edits: withoutNoise,
                fullShortSide: fullShortSide,
                pixelScale: pixelScale
            )
        } else {
            working = try CIGraph.process(
                image: working,
                mask: maskImage,
                edits: edits,
                fullShortSide: fullShortSide,
                pixelScale: pixelScale
            )
        }
        return try bitmap(working, width: width, height: height)
    }

    /// Layers are applied from the bottom of the stack to the top. Opacity scales the mask,
    /// which is already the mix amount for de-wrinkle and for mask-limited noise.
    private func renderStacked(
        source: CIImage,
        passes: [RenderPass],
        fullShortSide: Int,
        pixelScale: Float,
        width: Int,
        height: Int
    ) throws -> [Float] {
        var working = prepared(source, width: width, height: height)
        for pass in passes where pass.opacity > 0.001 {
            var mask = pass.mask.resized(toWidth: width, height: height)
            if pass.opacity < 0.999 {
                for index in mask.values.indices {
                    mask.values[index] *= pass.opacity
                }
            }
            guard mask.maximum() > 0.001 else { continue }
            var edits = pass.edits
            edits.noise.limitToMask = true
            let dewrinkleActive = edits.dewrinkle.clampedStrength > 0.0001
            if !dewrinkleActive && !edits.noise.isActive { continue }
            if !dewrinkleActive {
                edits.dewrinkle.strength = 0
            }
            working = try CIGraph.process(
                image: working,
                mask: CIGraph.maskImage(mask),
                edits: edits,
                fullShortSide: fullShortSide,
                pixelScale: pixelScale
            )
        }
        return try bitmap(working, width: width, height: height)
    }

    private func prepared(_ image: CIImage, width: Int, height: Int) -> CIImage {
        let extent = image.extent
        let moved = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
        return moved.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func bitmap(_ image: CIImage, width: Int, height: Int) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        var buffer = [Float](repeating: 0, count: width * height * 4)
        let rowBytes = width * MemoryLayout<Float>.stride * 4
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(
                image,
                toBitmap: base,
                rowBytes: rowBytes,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBAf,
                colorSpace: nil
            )
        }
        if BitmapLayout.rowsAreTopFirst {
            return buffer
        }
        return Self.flipVertically(buffer, width: width, height: height)
    }

    private func rgbImage(from image: CIImage, width: Int, height: Int) throws -> RGBImage {
        let rgba = try bitmap(image, width: width, height: height)
        var pixels = [Float](repeating: 0, count: width * height * 3)
        for index in 0..<(width * height) {
            pixels[index * 3] = rgba[index * 4]
            pixels[index * 3 + 1] = rgba[index * 4 + 1]
            pixels[index * 3 + 2] = rgba[index * 4 + 2]
        }
        return RGBImage(width: width, height: height, pixels: pixels)
    }

    private func ciImage(from image: RGBImage) -> CIImage {
        var rgba = [Float](repeating: 1, count: image.pixelCount * 4)
        for index in 0..<image.pixelCount {
            rgba[index * 4] = image.pixels[index * 3]
            rgba[index * 4 + 1] = image.pixels[index * 3 + 1]
            rgba[index * 4 + 2] = image.pixels[index * 3 + 2]
        }
        let data = rgba.withUnsafeBytes { Data($0) }
        return CIImage(
            bitmapData: data,
            bytesPerRow: image.width * MemoryLayout<Float>.stride * 4,
            size: CGSize(width: image.width, height: image.height),
            format: .RGBAf,
            colorSpace: nil
        )
    }

    private static func flipVertically(_ buffer: [Float], width: Int, height: Int) -> [Float] {
        var flipped = buffer
        let row = width * 4
        for y in 0..<(height / 2) {
            let top = y * row
            let bottom = (height - 1 - y) * row
            for offset in 0..<row {
                let swap = flipped[top + offset]
                flipped[top + offset] = flipped[bottom + offset]
                flipped[bottom + offset] = swap
            }
        }
        return flipped
    }

    /// The model must not require the main thread. Render runs off main, and this waits.
    private static func awaitModel(
        _ model: MLDenoiseModel,
        image: RGBImage,
        parameters: NoiseReductionParameters
    ) throws -> RGBImage {
        let box = ModelResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                box.result = .success(try await model.denoise(image, parameters: parameters))
            } catch {
                box.result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.result else {
            throw RenderError.renderFailed
        }
        return try result.get()
    }
}

private final class ModelResultBox: @unchecked Sendable {
    var result: Result<RGBImage, Error>?
}
