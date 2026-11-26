import XCTest
@testable import DewrinkleCore

final class EngineTests: XCTestCase {
    func testPixelDepthRoundTrip() {
        for code in [UInt8(0), 1, 127, 200, 255] {
            XCTAssertEqual(PixelDepth.quantize8(PixelDepth.expand8(code)), code)
        }
        for code in [UInt16(0), 1, 32768, 40000, 65535] {
            XCTAssertEqual(PixelDepth.quantize16(PixelDepth.expand16(code)), code)
        }
        XCTAssertGreaterThan(PixelDepth.expand8(255), 0.999)
        XCTAssertLessThan(PixelDepth.expand16(1), 0.00002)
    }

    func testOrientationSixSwapsAxesAndMovesTheCorner() {
        var stored = RGBImage(width: 4, height: 2, fill: 0)
        stored.setPixel(0, 0, r: 1, g: 0, b: 0)
        stored.setPixel(3, 1, r: 0, g: 0, b: 1)
        let upright = ImageOrientation.right.applying(to: stored)
        XCTAssertEqual(upright.width, 2)
        XCTAssertEqual(upright.height, 4)
        let mapped = ImageOrientation.right.map(x: 0, y: 0, width: 4, height: 2)
        XCTAssertEqual(mapped.x, 1)
        XCTAssertEqual(mapped.y, 0)
        XCTAssertEqual(upright.pixels[upright.offset(mapped.x, mapped.y)], 1, accuracy: 0.0001)
        XCTAssertEqual(ImageOrientation(exif: 1).applying(to: stored), stored)
        XCTAssertEqual(ImageOrientation(exif: 6).orientedSize(width: 8256, height: 5504).width, 5504)
    }

    func testGaussianPreservesAFlatFieldAndSpreadsAnImpulse() {
        let flat = RGBImage(width: 24, height: 18, fill: 0.4)
        let blurred = GaussianBlur.rgb(flat, sigma: 3.2)
        XCTAssertLessThan(RGBImage.maxAbsoluteDifference(flat, blurred), 0.00001)

        let weights = GaussianBlur.kernel(sigma: 2.5)
        XCTAssertEqual(weights.reduce(0, +), 1, accuracy: 0.00001)

        var impulse = [Float](repeating: 0, count: 31 * 31)
        impulse[15 * 31 + 15] = 1
        let spread = GaussianBlur.plane(impulse, width: 31, height: 31, sigma: 2)
        XCTAssertEqual(spread.reduce(0, +), 1, accuracy: 0.002)
        XCTAssertGreaterThan(spread[15 * 31 + 15], spread[15 * 31 + 18])
        XCTAssertEqual(spread[15 * 31 + 17], spread[15 * 31 + 13], accuracy: 0.00001)
        XCTAssertEqual(spread[13 * 31 + 15], spread[17 * 31 + 15], accuracy: 0.00001)
    }

    func testBandsRecombineToTheOriginal() {
        let image = sine(width: 96, height: 20, period: 17, amplitude: 0.18)
        let bands = FrequencySeparation.bands(
            of: image,
            sigmas: FrequencySigmas(detail: 1.1, fine: 4, coarse: 11)
        )
        let rebuilt = FrequencySeparation.recombine(bands, fineKeep: 1, coarseKeep: 1)
        XCTAssertLessThan(RGBImage.maxAbsoluteDifference(image, rebuilt), 0.0001)
    }

    func testWeaveSurvivesAndFineWrinklesDoNot() {
        let checker = checkerboard(width: 80, height: 48, low: 0.22, high: 0.78)
        var wrinkleSettings = DewrinkleParameters(strength: 1, fine: 1, coarse: 1)
        wrinkleSettings.detailRadiusOverride = 1.2
        wrinkleSettings.fineRadiusOverride = 6
        wrinkleSettings.coarseRadiusOverride = 16
        let mask = MaskBuffer(width: checker.width, height: checker.height, fill: 1)
        let kept = FrequencySeparation.apply(
            checker,
            mask: mask,
            parameters: wrinkleSettings,
            structure: noProtection
        )
        XCTAssertLessThan(RGBImage.meanAbsoluteDifference(checker, kept), 0.02)

        let wrinkled = sine(width: 96, height: 24, period: 12, amplitude: 0.2)
        var fineSettings = DewrinkleParameters(strength: 1, fine: 1, coarse: 0)
        fineSettings.detailRadiusOverride = 0.8
        fineSettings.fineRadiusOverride = 4.5
        fineSettings.coarseRadiusOverride = 16
        let smoothed = FrequencySeparation.apply(
            wrinkled,
            mask: MaskBuffer(width: wrinkled.width, height: wrinkled.height, fill: 1),
            parameters: fineSettings,
            structure: noProtection
        )
        XCTAssertGreaterThan(peakToPeak(wrinkled), 0.35)
        XCTAssertLessThan(peakToPeak(smoothed), 0.12)
    }

    func testCoarseBandRemovesFoldsAndKeepsBroadDrape() {
        let fold = sine(width: 160, height: 24, period: 40, amplitude: 0.18)
        var removeCoarse = DewrinkleParameters(strength: 1, fine: 0, coarse: 1)
        removeCoarse.detailRadiusOverride = 0.8
        removeCoarse.fineRadiusOverride = 3
        removeCoarse.coarseRadiusOverride = 14
        let mask = MaskBuffer(width: fold.width, height: fold.height, fill: 1)
        let flattened = FrequencySeparation.apply(fold, mask: mask, parameters: removeCoarse, structure: noProtection)
        XCTAssertLessThan(peakToPeak(flattened), 0.16)

        var keepCoarse = removeCoarse
        keepCoarse.coarse = 0
        let untouched = FrequencySeparation.apply(fold, mask: mask, parameters: keepCoarse, structure: noProtection)
        XCTAssertGreaterThan(peakToPeak(untouched), 0.30)

        let drape = sine(width: 220, height: 20, period: 180, amplitude: 0.15)
        var aggressive = DewrinkleParameters(strength: 1, fine: 1, coarse: 1)
        aggressive.detailRadiusOverride = 1
        aggressive.fineRadiusOverride = 4
        aggressive.coarseRadiusOverride = 10
        let stillDraped = FrequencySeparation.apply(
            drape,
            mask: MaskBuffer(width: drape.width, height: drape.height, fill: 1),
            parameters: aggressive,
            structure: noProtection
        )
        XCTAssertGreaterThan(peakToPeak(stillDraped), 0.22)
    }

    func testStrengthAndEmptyMaskLeaveTheFileAlone() {
        let image = sine(width: 48, height: 16, period: 10, amplitude: 0.2)
        var settings = DewrinkleParameters.standard
        settings.strength = 0
        let mask = MaskBuffer(width: image.width, height: image.height, fill: 1)
        XCTAssertEqual(FrequencySeparation.apply(image, mask: mask, parameters: settings), image)
        settings.strength = 1
        let empty = MaskBuffer(width: image.width, height: image.height, fill: 0)
        XCTAssertEqual(FrequencySeparation.apply(image, mask: empty, parameters: settings), image)
    }

    func testZ8ScaleKeepsDrapeAboveTheCoarseRadius() {
        let sigmas = FrequencyScales.standard.fullResolutionSigmas(shortSide: 5504)
        XCTAssertEqual(sigmas.detail, 7.7056, accuracy: 0.01)
        XCTAssertEqual(sigmas.fine, 66.048, accuracy: 0.01)
        XCTAssertEqual(sigmas.coarse, 165.12, accuracy: 0.01)
        XCTAssertEqual(DewrinkleParameters.standard.strength, 0.70, accuracy: 0.0001)
        XCTAssertEqual(DewrinkleParameters.standard.fine, 0.80, accuracy: 0.0001)
        XCTAssertEqual(DewrinkleParameters.standard.coarse, 0.45, accuracy: 0.0001)
        let preview = DewrinkleParameters.standard.resolvedSigmas(fullShortSide: 5504, pixelScale: 1366 / 5504)
        XCTAssertEqual(preview.coarse / sigmas.coarse, 1366 / 5504, accuracy: 0.001)
    }

    func testStructureKeepsAStitchAndNotASoftWrinkle() {
        var image = sine(width: 96, height: 64, period: 16, amplitude: 0.08)
        for y in 0..<image.height {
            image.setPixel(20, y, r: 0.95, g: 0.95, b: 0.95)
        }
        // Sobel fires on the shoulders of a one-pixel stitch. Dilate covers the thread itself.
        let structure = StructureParameters(edgeLow: 0.06, edgeHigh: 0.22, dilatePixels: 1, featherPixels: 0)
        let protection = StructureMask.make(image: image, parameters: structure)
        XCTAssertEqual(protection.values[protection.index(20, 32)], 1, accuracy: 0.001)
        XCTAssertLessThan(protection.values[protection.index(40, 32)], 0.05)

        var settings = DewrinkleParameters(strength: 1, fine: 1, coarse: 1)
        settings.detailRadiusOverride = 0.8
        settings.fineRadiusOverride = 4
        settings.coarseRadiusOverride = 12
        let result = FrequencySeparation.apply(
            image,
            mask: MaskBuffer(width: image.width, height: image.height, fill: 1),
            parameters: settings,
            structure: structure
        )
        XCTAssertEqual(result.pixels[result.offset(20, 32)], 0.95, accuracy: 0.0001)
        let before = image.pixels[image.offset(70, 8)]
        let after = result.pixels[result.offset(70, 8)]
        XCTAssertGreaterThan(abs(before - 0.5), abs(after - 0.5) + 0.01)

        let ramp = RGBImage(width: 40, height: 12, pixels: {
            var pixels = [Float](repeating: 0, count: 40 * 12 * 3)
            for y in 0..<12 {
                for x in 0..<40 {
                    let value = Float(x) / 39 * 0.08
                    let index = (y * 40 + x) * 3
                    pixels[index] = value
                    pixels[index + 1] = value
                    pixels[index + 2] = value
                }
            }
            return pixels
        }())
        let gentle = StructureMask.gradientMagnitude(of: ramp)
        XCTAssertLessThan(gentle[6 * 40 + 20], 0.02)

        var step = RGBImage(width: 32, height: 12, fill: 0.2)
        for y in 0..<12 {
            for x in 16..<32 {
                step.setPixel(x, y, r: 0.7, g: 0.7, b: 0.7)
            }
        }
        let edge = StructureMask.gradientMagnitude(of: step)
        XCTAssertGreaterThan(edge[6 * 32 + 16], 0.4)
    }

    func testBrushPaintRestoreUndoAndRedo() {
        var document = MaskDocument()
        let painted = BrushStroke(
            settings: BrushSettings(radius: 6, hardness: 1, opacity: 1, mode: .paint),
            referenceWidth: 64,
            points: [SIMD2<Float>(Float(32.5 / 64), Float(32.5 / 64))]
        )
        document.add(painted)
        let mask = document.rasterize(width: 64, height: 64)
        XCTAssertGreaterThan(mask.values[mask.index(32, 32)], 0.95)
        XCTAssertEqual(mask.values[mask.index(44, 32)], 0, accuracy: 0.0001)

        document.add(BrushStroke(
            settings: BrushSettings(radius: 6, hardness: 1, opacity: 1, mode: .restore),
            referenceWidth: 64,
            points: [SIMD2<Float>(Float(32.5 / 64), Float(32.5 / 64))]
        ))
        XCTAssertLessThan(document.rasterize(width: 64, height: 64).values[32 * 64 + 32], 0.05)
        XCTAssertTrue(document.canUndo)
        document.undo()
        XCTAssertGreaterThan(document.rasterize(width: 64, height: 64).values[32 * 64 + 32], 0.95)
        XCTAssertTrue(document.canRedo)
        document.redo()
        XCTAssertLessThan(document.rasterize(width: 64, height: 64).values[32 * 64 + 32], 0.05)

        let spaced = BrushRasterizer.densify(
            [SIMD2<Float>(0, 0.5), SIMD2<Float>(1, 0.5)],
            normalizedSpacing: 0.2
        )
        XCTAssertGreaterThan(spaced.count, 4)
    }

    func testSkinAndFaceRefinementSpareTexturedCloth() {
        let skin = SkinTone.likelihood(r: 0.78, g: 0.55, b: 0.42)
        XCTAssertGreaterThan(skin, 0.7)
        XCTAssertLessThan(SkinTone.likelihood(r: 0.25, g: 0.35, b: 0.75), 0.15)
        XCTAssertLessThan(SkinTone.likelihood(r: 0.04, g: 0.04, b: 0.05), 0.05)

        let flatSkin = RGBImage(width: 24, height: 24, pixels: {
            var pixels = [Float](repeating: 0, count: 24 * 24 * 3)
            for index in 0..<(24 * 24) {
                pixels[index * 3] = 0.78
                pixels[index * 3 + 1] = 0.55
                pixels[index * 3 + 2] = 0.42
            }
            return pixels
        }())
        let peeled = GarmentMaskRefinement.refine(
            person: MaskBuffer(width: 24, height: 24, fill: 1),
            image: flatSkin,
            faces: []
        )
        XCTAssertLessThan(peeled.mean(), 0.25)

        var weave = RGBImage(width: 32, height: 32, fill: 0)
        for y in 0..<32 {
            for x in 0..<32 {
                if (x + y) % 2 == 0 {
                    weave.setPixel(x, y, r: 0.90, g: 0.70, b: 0.55)
                } else {
                    weave.setPixel(x, y, r: 0.40, g: 0.18, b: 0.12)
                }
            }
        }
        let kept = GarmentMaskRefinement.refine(
            person: MaskBuffer(width: 32, height: 32, fill: 1),
            image: weave,
            faces: []
        )
        XCTAssertGreaterThan(kept.mean(), 0.75)

        let dark = RGBImage(width: 40, height: 40, fill: 0.05)
        let face = NormalizedRect(x: 0.35, y: 0.30, width: 0.30, height: 0.28)
        let withoutFace = GarmentMaskRefinement.refine(
            person: MaskBuffer(width: 40, height: 40, fill: 1),
            image: dark,
            faces: [face]
        )
        XCTAssertLessThan(withoutFace.values[withoutFace.index(20, 18)], 0.05)
        XCTAssertGreaterThan(withoutFace.values[withoutFace.index(2, 2)], 0.9)
    }

    func testNoiseIsOffByDefaultAndChromaDropsWithoutMovingLuma() {
        XCTAssertFalse(NoiseReductionParameters.off.isActive)
        XCTAssertEqual(NoiseReductionParameters.off.detail, 0.5, accuracy: 0.0001)
        XCTAssertFalse(NoiseReductionParameters.off.limitToMask)
        let resolved = NoiseReductionParameters(luminance: 1, chroma: 0.5, detail: 1, limitToMask: false).resolved()
        let soft = NoiseReductionParameters(luminance: 1, chroma: 0.5, detail: 0, limitToMask: false).resolved()
        XCTAssertLessThan(resolved.rangeSigma, soft.rangeSigma)
        XCTAssertGreaterThan(resolved.ciSharpness, soft.ciSharpness)

        let flat = RGBImage(width: 20, height: 12, fill: 0.3)
        XCTAssertEqual(NoiseReduction.apply(flat, parameters: .off, mask: nil), flat)

        var pixels = [Float](repeating: 0, count: 32 * 32 * 3)
        for y in 0..<32 {
            for x in 0..<32 {
                let cr: Float = x % 2 == 0 ? 0.62 : 0.42
                let rgb = YCbCr.toRGB(y: 0.5, cb: 0.5, cr: cr)
                let index = (y * 32 + x) * 3
                pixels[index] = rgb.r
                pixels[index + 1] = rgb.g
                pixels[index + 2] = rgb.b
            }
        }
        let noisy = RGBImage(width: 32, height: 32, pixels: pixels)
        let denoised = NoiseReduction.apply(
            noisy,
            parameters: NoiseReductionParameters(luminance: 0, chroma: 1, detail: 0.5, limitToMask: false),
            mask: nil
        )
        XCTAssertGreaterThan(chromaSwing(noisy), 0.15)
        XCTAssertLessThan(chromaSwing(denoised), 0.04)
        XCTAssertLessThan(lumaDrift(noisy, denoised), 0.03)
    }

    func testLuminanceDetailKeepsAStepAndTheMaskLimitsTheEffect() {
        var step = RGBImage(width: 48, height: 16, fill: 0.2)
        for y in 0..<16 {
            for x in 24..<48 {
                step.setPixel(x, y, r: 0.8, g: 0.8, b: 0.8)
            }
        }
        let sharp = NoiseReduction.apply(
            step,
            parameters: NoiseReductionParameters(luminance: 1, chroma: 0, detail: 1, limitToMask: false),
            mask: nil
        )
        let soft = NoiseReduction.apply(
            step,
            parameters: NoiseReductionParameters(luminance: 1, chroma: 0, detail: 0, limitToMask: false),
            mask: nil
        )
        let sharpGap = sharp.pixels[sharp.offset(24, 8)] - sharp.pixels[sharp.offset(23, 8)]
        let softGap = soft.pixels[soft.offset(24, 8)] - soft.pixels[soft.offset(23, 8)]
        XCTAssertGreaterThan(sharpGap, 0.5)
        XCTAssertGreaterThan(sharpGap, softGap + 0.05)

        var speckled = RGBImage(width: 48, height: 16, fill: 0.45)
        speckled.setPixel(6, 8, r: 0.9, g: 0.9, b: 0.9)
        speckled.setPixel(40, 8, r: 0.9, g: 0.9, b: 0.9)
        var mask = MaskBuffer(width: 48, height: 16, fill: 0)
        for y in 0..<16 {
            for x in 24..<48 {
                mask.values[mask.index(x, y)] = 1
            }
        }
        let limited = NoiseReduction.apply(
            speckled,
            parameters: NoiseReductionParameters(luminance: 1, chroma: 0, detail: 0.15, limitToMask: true),
            mask: mask
        )
        XCTAssertEqual(limited.pixels[limited.offset(6, 8)], 0.9, accuracy: 0.0001)
        XCTAssertLessThan(limited.pixels[limited.offset(40, 8)], 0.7)
    }

    func testPipelineDenoisesBeforeDewrinkleAndCoreMLIsOptional() async throws {
        XCTAssertEqual(ProcessingOrder.stages, ["denoise", "dewrinkle"])
        let image = sine(width: 36, height: 16, period: 8, amplitude: 0.12)
        let mask = MaskBuffer(width: image.width, height: image.height, fill: 1)
        var edits = EditParameters.standard
        edits.dewrinkle.strength = 0
        edits.noise = NoiseReductionParameters(luminance: 0, chroma: 1, detail: 0.4, limitToMask: false)
        let onlyNoise = ImagePipeline.apply(image, mask: mask, parameters: edits)
        let direct = NoiseReduction.apply(image, parameters: edits.noise, mask: nil)
        XCTAssertLessThan(RGBImage.maxAbsoluteDifference(onlyNoise, direct), 0.0001)

        edits.noise = .off
        edits.dewrinkle.strength = 1
        edits.dewrinkle.fine = 1
        edits.dewrinkle.detailRadiusOverride = 0.6
        edits.dewrinkle.fineRadiusOverride = 3
        edits.dewrinkle.coarseRadiusOverride = 8
        let onlyDewrinkle = ImagePipeline.apply(image, mask: mask, parameters: edits)
        XCTAssertLessThan(peakToPeak(onlyDewrinkle), peakToPeak(image) * 0.7)

        let counter = CountingDenoiser()
        edits.noise = .off
        edits.dewrinkle.strength = 0
        _ = try await ImagePipeline.apply(image, mask: mask, parameters: edits, model: counter)
        XCTAssertEqual(counter.calls, 0)

        edits.noise.luminance = 1
        let tinted = try await ImagePipeline.apply(image, mask: mask, parameters: edits, model: counter)
        XCTAssertEqual(counter.calls, 1)
        XCTAssertEqual(tinted.pixels[0], 1, accuracy: 0.0001)
        XCTAssertNil(DenoiseSlot.shared.model)
    }

    func testExportDefaultsFollowTheFileYouOpened() {
        XCTAssertEqual(ExportSettings.defaultJPEGQuality, 0.92, accuracy: 0.0001)
        let jpeg = ExportSettings.matching(source: .jpeg)
        XCTAssertEqual(jpeg.container, .jpeg)
        XCTAssertEqual(jpeg.jpegQuality, 0.92, accuracy: 0.0001)
        XCTAssertEqual(ExportSettings.matching(source: .tiff).container, .tiff16)
        XCTAssertEqual(ExportSettings.matching(source: .png).container, .png16)
        XCTAssertEqual(SourceContainer(fileExtension: "JPEG"), .jpeg)
        XCTAssertEqual(SourceContainer(fileExtension: "tiff"), .tiff)
        XCTAssertEqual(ExportContainer.jpeg.fileExtension, "jpg")
        XCTAssertEqual(ExportContainer.tiff16.menuTitle, "16-bit TIFF")
        var overridden = jpeg
        overridden.container = .tiff16
        XCTAssertEqual(overridden.container, .tiff16)
    }

    func testYCbCrRoundTrip() {
        let samples: [(Float, Float, Float)] = [
            (0.2, 0.2, 0.2),
            (0.78, 0.55, 0.42),
            (0.1, 0.4, 0.9),
            (1, 1, 1),
            (0.05, 0.05, 0.05)
        ]
        for sample in samples {
            let converted = YCbCr.fromRGB(r: sample.0, g: sample.1, b: sample.2)
            let back = YCbCr.toRGB(y: converted.y, cb: converted.cb, cr: converted.cr)
            XCTAssertEqual(back.r, sample.0, accuracy: 0.0001)
            XCTAssertEqual(back.g, sample.1, accuracy: 0.0001)
            XCTAssertEqual(back.b, sample.2, accuracy: 0.0001)
        }
    }

    func testUninstalledClickSelectorExplainsItself() async {
        let selector = UninstalledSAM2Selector()
        do {
            _ = try await selector.mask(
                for: RGBImage(width: 4, height: 4, fill: 0),
                points: [ClickPoint(x: 0.5, y: 0.5, kind: .include)]
            )
            XCTFail("SAM 2 should not be bundled")
        } catch let error as MaskingError {
            guard case .modelNotInstalled(let message) = error else {
                return XCTFail("unexpected masking error")
            }
            XCTAssertTrue(message.contains("SAM 2"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}

private let noProtection = StructureParameters(edgeLow: 10, edgeHigh: 11, dilatePixels: 0, featherPixels: 0)

private func sine(width: Int, height: Int, period: Float, amplitude: Float) -> RGBImage {
    var image = RGBImage(width: width, height: height, fill: 0)
    for y in 0..<height {
        for x in 0..<width {
            let value = 0.5 + amplitude * sin(2 * Float.pi * Float(x) / period)
            image.setPixel(x, y, r: value, g: value, b: value)
        }
    }
    return image
}

private func peakToPeak(_ image: RGBImage) -> Float {
    let y = image.height / 2
    let start = image.width / 5
    let end = image.width - start
    var low: Float = 1
    var high: Float = 0
    for x in start..<end {
        let value = image.pixels[image.offset(x, y)]
        low = min(low, value)
        high = max(high, value)
    }
    return high - low
}

private func checkerboard(width: Int, height: Int, low: Float, high: Float) -> RGBImage {
    var image = RGBImage(width: width, height: height, fill: low)
    for y in 0..<height {
        for x in 0..<width where (x + y) % 2 == 0 {
            image.setPixel(x, y, r: high, g: high, b: high)
        }
    }
    return image
}

private func chromaSwing(_ image: RGBImage) -> Float {
    var low: Float = 1
    var high: Float = 0
    let y = image.height / 2
    let start = image.width / 5
    let end = image.width - start
    for x in start..<end {
        let index = image.offset(x, y)
        let converted = YCbCr.fromRGB(r: image.pixels[index], g: image.pixels[index + 1], b: image.pixels[index + 2])
        low = min(low, converted.cr)
        high = max(high, converted.cr)
    }
    return high - low
}

private func lumaDrift(_ a: RGBImage, _ b: RGBImage) -> Float {
    var sum: Float = 0
    for y in 0..<a.height {
        for x in 0..<a.width {
            let ia = a.offset(x, y)
            let ib = b.offset(x, y)
            let ya = YCbCr.fromRGB(r: a.pixels[ia], g: a.pixels[ia + 1], b: a.pixels[ia + 2]).y
            let yb = YCbCr.fromRGB(r: b.pixels[ib], g: b.pixels[ib + 1], b: b.pixels[ib + 2]).y
            sum += abs(ya - yb)
        }
    }
    return sum / Float(a.pixelCount)
}

private final class CountingDenoiser: MLDenoiseModel {
    let displayName = "Counter"
    var calls = 0

    func denoise(_ image: RGBImage, parameters: NoiseReductionParameters) async throws -> RGBImage {
        calls += 1
        var output = image
        for index in stride(from: 0, to: output.pixels.count, by: 3) {
            output.pixels[index] = 1
        }
        return output
    }
}
