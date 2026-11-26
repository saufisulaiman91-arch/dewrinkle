import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
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
        XCTAssertLessThan(peakToPeak(smoothed), 0.24)
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
        XCTAssertEqual(DewrinkleParameters.standard.strength, 0.50, accuracy: 0.0001)
        XCTAssertEqual(DewrinkleParameters.standard.fine, 0.50, accuracy: 0.0001)
        XCTAssertEqual(DewrinkleParameters.standard.coarse, 0.50, accuracy: 0.0001)
        XCTAssertEqual(DewrinkleParameters.standard.preserveFolds, 0.75, accuracy: 0.0001)
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

    func testPinkSatinStaysWhenSkinColorIsOffAndAHandIsCutOut() {
        let pink = RGBImage(width: 30, height: 30, pixels: {
            var pixels = [Float](repeating: 0, count: 30 * 30 * 3)
            for index in 0..<(30 * 30) {
                pixels[index * 3] = 0.86
                pixels[index * 3 + 1] = 0.45
                pixels[index * 3 + 2] = 0.50
            }
            return pixels
        }())
        let kept = GarmentMaskRefinement.refine(
            person: MaskBuffer(width: 30, height: 30, fill: 1),
            image: pink,
            faces: [],
            skinStrength: 0
        )
        XCTAssertGreaterThan(kept.mean(), 0.95)

        let hand = NormalizedRect(x: 0.62, y: 0.62, width: 0.22, height: 0.22)
        let carved = GarmentMaskRefinement.refine(
            person: MaskBuffer(width: 30, height: 30, fill: 1),
            image: pink,
            faces: [],
            skinStrength: 0,
            hands: [hand]
        )
        XCTAssertLessThan(carved.values[carved.index(22, 22)], 0.05)
        XCTAssertGreaterThan(carved.values[carved.index(2, 2)], 0.9)
    }

    func testBrushStrokeAtTheTopLeftLandsOnTheTopLeft() {
        let point = UprightPoint.unit(
            viewX: 2,
            viewY: 2,
            originX: 0,
            originY: 0,
            scale: 1,
            pixelWidth: 40,
            pixelHeight: 40
        )
        XCTAssertNotNil(point)
        var document = MaskDocument()
        document.add(BrushStroke(
            settings: BrushSettings(radius: 6, hardness: 1, opacity: 1, mode: .paint),
            referenceWidth: 40,
            points: [point!]
        ))
        let mask = document.rasterize(width: 40, height: 40)
        XCTAssertGreaterThan(mask.values[mask.index(2, 2)], 0.8)
        XCTAssertLessThan(mask.values[mask.index(2, 37)], 0.05)
        XCTAssertLessThan(mask.values[mask.index(37, 2)], 0.05)
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
        XCTAssertEqual(ProcessingOrder.stages, ["dewrinkle"])
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
        XCTAssertLessThan(peakToPeak(onlyDewrinkle), peakToPeak(image) * 0.85)
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

    func testFourClockwiseTurnsReturnThePixelAndTheBrush() {
        var mask = MaskBuffer(width: 6, height: 4, fill: 0)
        mask.values[mask.index(1, 0)] = 1
        var document = MaskDocument()
        document.setBase(mask)
        document.add(BrushStroke(
            settings: BrushSettings(radius: 2, hardness: 1, opacity: 1, mode: .paint),
            referenceWidth: 6,
            points: [SIMD2<Float>(0.1, 0.1)]
        ))
        var width = 6
        var height = 4
        var turned = document
        for _ in 0..<4 {
            turned = turned.applying(.clockwise, referenceWidth: width, referenceHeight: height)
            swap(&width, &height)
        }
        let raster = turned.rasterize(width: 6, height: 4)
        XCTAssertGreaterThan(raster.values[raster.index(1, 0)], 0.5)
        let point = [PictureTurn.clockwise, .clockwise, .clockwise, .clockwise].reduce(SIMD2<Float>(0.2, 0.8)) { $1.map($0) }
        XCTAssertEqual(point.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.8, accuracy: 0.0001)
    }

    func testNaturalSmoothsACreaseAndKeepsSheenWeaveAndChroma() {
        let width = 120
        let height = 24
        var image = RGBImage(width: width, height: height, fill: 0)
        for y in 0..<height {
            for x in 0..<width {
                let sheen = 0.08 * sin(2 * Float.pi * Float(x) / 90)
                let crease = 0.16 * sin(2 * Float.pi * Float(x) / 16)
                let weave: Float = (x + y) % 2 == 0 ? 0.05 : -0.05
                let luma = 0.55 + sheen + crease + weave
                image.setPixel(x, y, r: luma + 0.08, g: luma, b: luma - 0.05)
            }
        }
        var natural = DewrinkleParameters.standard
        natural.strength = 1
        natural.fine = 1
        natural.coarse = 0
        natural.preserveFolds = 1
        natural.detailRadiusOverride = 1.1
        natural.fineRadiusOverride = 6
        natural.coarseRadiusOverride = 22
        let smoothed = FrequencySeparation.apply(
            image,
            mask: MaskBuffer(width: width, height: height, fill: 1),
            parameters: natural,
            structure: noProtection
        )
        let row = 12
        XCTAssertLessThan(tone(smoothed, period: 16, y: row), tone(image, period: 16, y: row) * 0.75)
        XCTAssertGreaterThan(tone(smoothed, period: 90, y: row), tone(image, period: 90, y: row) * 0.75)
        var weaveBefore: Float = 0
        var weaveAfter: Float = 0
        let samples = width / 2 - 2
        for x in stride(from: 2, to: width - 2, by: 2) {
            weaveBefore += abs(image.pixels[image.offset(x, row)] - image.pixels[image.offset(x + 1, row)])
            weaveAfter += abs(smoothed.pixels[smoothed.offset(x, row)] - smoothed.pixels[smoothed.offset(x + 1, row)])
        }
        XCTAssertGreaterThan(weaveAfter / Float(samples), weaveBefore / Float(samples) * 0.55)
        let index = image.offset(30, 8)
        let chromaBefore = image.pixels[index] - image.pixels[index + 2]
        let chromaAfter = smoothed.pixels[index] - smoothed.pixels[index + 2]
        XCTAssertEqual(chromaAfter, chromaBefore, accuracy: 0.03)
    }

    func testStrokeFollowsTheTurnAndTheRadiusReferenceSwaps() {
        var document = MaskDocument()
        document.add(BrushStroke(
            settings: BrushSettings(radius: 1.2, hardness: 1, opacity: 1, mode: .paint),
            referenceWidth: 40,
            points: [SIMD2<Float>(0.05, 0.08)]
        ))
        let before = document.rasterize(width: 40, height: 20)
        XCTAssertGreaterThan(before.values[before.index(2, 1)], 0.4)
        let turned = document.applying(.clockwise, referenceWidth: 40, referenceHeight: 20)
        XCTAssertEqual(turned.strokes.first?.referenceWidth, 20)
        let mapped = PictureTurn.clockwise.map(SIMD2<Float>(0.05, 0.08))
        let after = turned.rasterize(width: 20, height: 40)
        let x = min(max(Int((mapped.x * 20).rounded()) - 1, 0), 19)
        let y = min(max(Int((mapped.y * 40).rounded()) - 1, 0), 39)
        XCTAssertGreaterThan(after.values[after.index(x, y)], 0.4)
        XCTAssertLessThan(after.values[after.index(1, 1)], 0.15)
    }

    func testRotationHistoryRestoresTheUprightMask() {
        var upright = MaskDocument()
        var base = MaskBuffer(width: 5, height: 3, fill: 0)
        base.values[base.index(0, 0)] = 1
        upright.setBase(base)
        var history = HistoryStack<MaskDocument>()
        history.reset(name: "Original", state: upright)
        let right = upright.applying(.clockwise, referenceWidth: 5, referenceHeight: 3)
        history.commit(name: "Rotate right", state: right)
        let again = right.applying(.clockwise, referenceWidth: 3, referenceHeight: 5)
        history.commit(name: "Rotate right", state: again)
        let restored = history.undo()
        XCTAssertEqual(restored?.base?.width, 3)
        XCTAssertEqual(history.undo()?.base?.width, 5)
        XCTAssertEqual(history.redo()?.base?.width, 3)
    }

    func testClockwiseTurnMovesTheTopLeftToTheTopRight() {
        var mask = MaskBuffer(width: 4, height: 2, fill: 0)
        mask.values[mask.index(0, 0)] = 1
        let turned = mask.applying(.clockwise)
        XCTAssertEqual(turned.width, 2)
        XCTAssertEqual(turned.height, 4)
        XCTAssertGreaterThan(turned.values[turned.index(1, 0)], 0.99)
        XCTAssertLessThan(turned.values[turned.index(0, 0)], 0.01)
        let point = PictureTurn.clockwise.map(SIMD2<Float>(0, 0))
        XCTAssertEqual(point.x, 1, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0, accuracy: 0.0001)
    }

    func testHistoryJumpKeepsLaterStepsUntilANewEdit() {
        struct Box: Equatable { var value: Int }
        var history = HistoryStack<Box>()
        history.reset(name: "Original", state: Box(value: 0))
        history.commit(name: "Brush", state: Box(value: 1))
        history.commit(name: "Rotate right", state: Box(value: 2))
        XCTAssertEqual(history.undo()?.value, 1)
        XCTAssertEqual(history.entries.map(\.name), ["Original", "Brush", "Rotate right"])
        XCTAssertEqual(history.index, 1)
        history.commit(name: "Noise reduction", state: Box(value: 3))
        XCTAssertEqual(history.entries.map(\.name), ["Original", "Brush", "Noise reduction"])
        XCTAssertFalse(history.canRedo)
    }

    func testHijabStaysOffTheFaceAndOffTheDress() {
        let width = 40
        let height = 48
        var image = RGBImage(width: width, height: height, fill: 0.45)
        for y in 0..<height {
            for x in 0..<width {
                image.setPixel(x, y, r: 0.42, g: 0.16, b: 0.1)
            }
        }
        let face = NormalizedRect(x: 0.34, y: 0.18, width: 0.32, height: 0.16)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width)
                let v = (Float(y) + 0.5) / Float(height)
                let nx = (u - (face.x + face.width / 2)) / (face.width * 0.5)
                let ny = (v - (face.y + face.height / 2)) / (face.height * 0.5)
                let ellipse = hypot(nx, ny)
                if ellipse < 0.9 {
                    image.setPixel(x, y, r: 0.78, g: 0.55, b: 0.42)
                } else if ellipse < 1.7 && v < face.y + face.height + face.height * 0.8 {
                    image.setPixel(x, y, r: 0.08, g: 0.16, b: 0.32)
                }
            }
        }
        let person = MaskBuffer(width: width, height: height, fill: 1)
        var skin = MaskBuffer(width: width, height: height, fill: 0)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width)
                let v = (Float(y) + 0.5) / Float(height)
                let nx = (u - (face.x + face.width / 2)) / (face.width * 0.5)
                let ny = (v - (face.y + face.height / 2)) / (face.height * 0.5)
                if hypot(nx, ny) < 0.95 {
                    skin.values[skin.index(x, y)] = 1
                }
            }
        }
        let hijab = HijabRegion.mask(image: image, person: person, faces: [face], skin: skin, tolerance: 0.12)
        let scarfV = (face.y + face.height / 2) - face.height * 0.7
        let scarf = hijab.index(width / 2, min(height - 1, max(0, Int(scarfV * Float(height)))))
        let cheek = hijab.index(width / 2, Int(Float(height) * (face.y + face.height * 0.45)))
        let skirt = hijab.index(width / 2, height - 4)
        XCTAssertGreaterThan(hijab.values[scarf], 0.5)
        XCTAssertLessThan(hijab.values[cheek], 0.2)
        XCTAssertLessThan(hijab.values[skirt], 0.2)
    }

    func testRegionGrowStaysInsideASimilarPatch() {
        var image = RGBImage(width: 12, height: 8, fill: 0.1)
        for y in 2..<6 {
            for x in 2..<7 {
                image.setPixel(x, y, r: 0.8, g: 0.2, b: 0.2)
            }
        }
        let mask = RegionGrow.mask(of: image, seedU: 4.5 / 12, seedV: 3.5 / 8, tolerance: 0.08)
        XCTAssertGreaterThan(mask.values[mask.index(3, 3)], 0.9)
        XCTAssertLessThan(mask.values[mask.index(0, 0)], 0.05)
        XCTAssertLessThan(mask.values[mask.index(10, 6)], 0.05)
    }

    func testDetectedCreasesSmoothTheSkirtAndLeaveEmbroidery() throws {
        let image = bajuScene()
        let clothing = MaskBuffer(width: image.width, height: image.height, fill: 1)
        let mask = WrinkleDetector.mask(
            image: image,
            clothing: clothing,
            settings: WrinkleDetector.Settings(sensitivity: 0.58)
        )
        let gentle = WrinkleDetector.mask(
            image: image,
            clothing: clothing,
            settings: WrinkleDetector.Settings(sensitivity: 0.2)
        )
        XCTAssertLessThan(gentle.mean(), mask.mean())

        XCTAssertLessThan(mean(mask, y: 14..<62, x: 30..<(image.width - 30)), 0.12, "embroidery stays out of the mask")
        XCTAssertLessThan(meanColumn(mask, x: 14, y: 150..<(image.height - 28)), 0.28, "the side seam stays out")
        XCTAssertLessThan(meanRow(mask, y: image.height - 16, x: 40..<(image.width - 20)), 0.28, "the hem stays out")
        XCTAssertGreaterThan(maximum(mask, y: 140..<(image.height - 40), x: 48..<(image.width - 24)), 0.4, "skirt creases are marked")

        var smoothing = DewrinkleParameters.detected
        smoothing.detailRadiusOverride = 1
        smoothing.fineRadiusOverride = 8
        smoothing.coarseRadiusOverride = 18
        let smoothed = FrequencySeparation.apply(
            image,
            mask: mask,
            parameters: smoothing,
            structure: noProtection
        )
        let skirt = skirtRegion(image)
        let beforeEnergy = WrinkleDetector.creaseEnergy(of: image, region: skirt)
        let afterEnergy = WrinkleDetector.creaseEnergy(of: smoothed, region: skirt)
        XCTAssertGreaterThan(beforeEnergy, 0.01)
        XCTAssertLessThan(afterEnergy, beforeEnergy * 0.9, "diagonal crease energy should drop")
        XCTAssertGreaterThan(shadeSplit(smoothed), shadeSplit(image) * 0.68, "broad body shading stays")
        XCTAssertLessThan(meanAbsDelta(image, smoothed, y: 16..<58, x: 32..<(image.width - 32)), 0.04, "embroidery stays crisp")
        XCTAssertLessThan(
            meanAbsDelta(image, smoothed, y: (image.height - 16)..<(image.height - 15), x: 40..<(image.width - 20)),
            0.05,
            "the hem line stays"
        )
        writeRegression(before: image, mask: mask, after: smoothed, name: "satin-skirt")
    }

    func testBajuKurungReferenceMatchesTheAfterCreaseEnergy() throws {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        let beforeURL = fixtures.appendingPathComponent("baju-kurung-before.png")
        let afterURL = fixtures.appendingPathComponent("baju-kurung-after.png")
        let before = scaled(try loadRGB(beforeURL), maxSide: 900)
        let target = scaled(try loadRGB(afterURL), maxSide: 900)
        let clothing = satinCloth(before)
        var settings = DewrinkleParameters.standard
        settings.strength = 0.55
        settings.fine = 0.55
        settings.coarse = 0.55
        let output = FrequencySeparation.apply(before, mask: clothing, parameters: settings, structure: noProtection)
        let skirt = fractionalMask(before, y: 0.50..<0.76, x: 0.34..<0.66)
        let beforeEnergy = WrinkleDetector.creaseEnergy(of: before, region: skirt)
        let outputEnergy = WrinkleDetector.creaseEnergy(of: output, region: skirt)
        let targetSkirt = fractionalMask(target, y: 0.50..<0.76, x: 0.34..<0.66)
        let targetEnergy = WrinkleDetector.creaseEnergy(of: target, region: targetSkirt)
        XCTAssertGreaterThan(beforeEnergy, targetEnergy)
        XCTAssertLessThan(outputEnergy, beforeEnergy * 0.92, "skirt crease energy should fall")
        XCTAssertLessThan(regionDelta(before, output, y: 0.12..<0.28, x: 0.10..<0.32), 0.04, "left embroidery stays crisp")
        XCTAssertLessThan(regionDelta(before, output, y: 0.12..<0.28, x: 0.68..<0.90), 0.04, "right embroidery stays crisp")
        let chromaBefore = regionChroma(before, y: 0.55..<0.74, x: 0.38..<0.62)
        let chromaAfter = regionChroma(output, y: 0.55..<0.74, x: 0.38..<0.62)
        XCTAssertEqual(chromaAfter, chromaBefore, accuracy: 0.015, "satin colour should not shift")
        writeRegression(before: before, mask: clothing, after: output, name: "baju-kurung", target: target)
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

private func tone(_ image: RGBImage, period: Float, y: Int) -> Float {
    var sine: Float = 0
    var cosine: Float = 0
    for x in 0..<image.width {
        let phase = 2 * Float.pi * Float(x) / period
        let value = image.pixels[image.offset(x, y)]
        sine += value * sin(phase)
        cosine += value * cos(phase)
    }
    return 2 * hypot(sine, cosine) / Float(image.width)
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

private func bajuScene() -> RGBImage {
    let width = 180
    let height = 220
    var image = RGBImage(width: width, height: height, fill: 0)
    for y in 0..<height {
        for x in 0..<width {
            var luma = 0.40 + 0.10 * Float(x) / Float(width)
            if y >= 110 && x >= 36 {
                luma += 0.11 * sin(2 * Float.pi * (0.55 * Float(x) + 0.84 * Float(y)) / 16)
            }
            if y < 78 {
                luma += ((x / 2) + (y / 2)) % 2 == 0 ? 0.16 : -0.16
            }
            if x == 14 && y > 100 { luma -= 0.42 }
            if y == height - 16 { luma -= 0.42 }
            luma = min(max(luma, 0.02), 0.92)
            var red = luma + 0.05
            var green = luma * 0.62
            var blue = luma * 0.38
            if y < 78 && (x + y) % 6 == 0 {
                red += 0.18
                green += 0.1
                blue += 0.14
            }
            image.setPixel(x, y, r: min(red, 1), g: min(green, 1), b: min(blue, 1))
        }
    }
    return image
}

private func skirtRegion(_ image: RGBImage) -> MaskBuffer {
    var mask = MaskBuffer(width: image.width, height: image.height, fill: 0)
    for y in 140..<(image.height - 40) {
        for x in 48..<(image.width - 24) {
            mask.values[mask.index(x, y)] = 1
        }
    }
    return mask
}

private func mean(_ mask: MaskBuffer, y: Range<Int>, x: Range<Int>) -> Float {
    var sum: Float = 0
    var count: Float = 0
    for yy in y {
        for xx in x {
            sum += mask.values[mask.index(xx, yy)]
            count += 1
        }
    }
    return sum / max(count, 1)
}

private func meanColumn(_ mask: MaskBuffer, x: Int, y: Range<Int>) -> Float {
    var sum: Float = 0
    var count: Float = 0
    for yy in y {
        sum += mask.values[mask.index(x, yy)]
        count += 1
    }
    return sum / max(count, 1)
}

private func meanRow(_ mask: MaskBuffer, y: Int, x: Range<Int>) -> Float {
    var sum: Float = 0
    var count: Float = 0
    for xx in x {
        sum += mask.values[mask.index(xx, y)]
        count += 1
    }
    return sum / max(count, 1)
}

private func maximum(_ mask: MaskBuffer, y: Range<Int>, x: Range<Int>) -> Float {
    var peak: Float = 0
    for yy in y {
        for xx in x {
            peak = max(peak, mask.values[mask.index(xx, yy)])
        }
    }
    return peak
}

private func meanAbsDelta(_ a: RGBImage, _ b: RGBImage, y: Range<Int>, x: Range<Int>) -> Float {
    var sum: Float = 0
    var count: Float = 0
    for yy in y {
        for xx in x {
            let ia = a.offset(xx, yy)
            let ib = b.offset(xx, yy)
            sum += abs(a.pixels[ia] - b.pixels[ib])
            sum += abs(a.pixels[ia + 1] - b.pixels[ib + 1])
            sum += abs(a.pixels[ia + 2] - b.pixels[ib + 2])
            count += 3
        }
    }
    return sum / max(count, 1)
}

private func shadeSplit(_ image: RGBImage) -> Float {
    func average(_ xs: Range<Int>) -> Float {
        var sum: Float = 0
        var count: Float = 0
        for y in 160..<(image.height - 40) {
            for x in xs {
                let index = image.offset(x, y)
                sum += 0.299 * image.pixels[index] + 0.587 * image.pixels[index + 1] + 0.114 * image.pixels[index + 2]
                count += 1
            }
        }
        return sum / max(count, 1)
    }
    return abs(average(40..<90) - average((image.width - 90)..<(image.width - 20)))
}

private func satinCloth(_ image: RGBImage) -> MaskBuffer {
    var mask = MaskBuffer(width: image.width, height: image.height, fill: 0)
    for y in 0..<image.height {
        for x in 0..<image.width {
            let index = image.offset(x, y)
            let red = image.pixels[index]
            let green = image.pixels[index + 1]
            let blue = image.pixels[index + 2]
            let luma = 0.299 * red + 0.587 * green + 0.114 * blue
            let grass = green > red * 1.05 && green > 0.18
            let wall = luma > 0.75 && abs(red - green) < 0.08 && abs(red - blue) < 0.1
            if !grass && !wall && luma > 0.08 {
                mask.values[mask.index(x, y)] = 1
            }
        }
    }
    return mask
}

private func loadRGB(_ url: URL) throws -> RGBImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw NSError(domain: "DewrinkleTests", code: 1)
    }
    let width = cgImage.width
    let height = cgImage.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
        guard let context = CGContext(
            data: raw.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return false }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    if !drew { throw NSError(domain: "DewrinkleTests", code: 2) }
    var pixels = [Float](repeating: 0, count: width * height * 3)
    for index in 0..<(width * height) {
        pixels[index * 3] = Float(bytes[index * 4]) / 255
        pixels[index * 3 + 1] = Float(bytes[index * 4 + 1]) / 255
        pixels[index * 3 + 2] = Float(bytes[index * 4 + 2]) / 255
    }
    return RGBImage(width: width, height: height, pixels: pixels)
}

private func fractionalMask(_ image: RGBImage, y: Range<Double>, x: Range<Double>) -> MaskBuffer {
    var mask = MaskBuffer(width: image.width, height: image.height, fill: 0)
    let y0 = max(0, Int(y.lowerBound * Double(image.height)))
    let y1 = min(image.height, Int(y.upperBound * Double(image.height)))
    let x0 = max(0, Int(x.lowerBound * Double(image.width)))
    let x1 = min(image.width, Int(x.upperBound * Double(image.width)))
    guard y1 > y0, x1 > x0 else { return mask }
    for yy in y0..<y1 {
        for xx in x0..<x1 {
            mask.values[mask.index(xx, yy)] = 1
        }
    }
    return mask
}

private func regionMean(_ mask: MaskBuffer, y: Range<Double>, x: Range<Double>) -> Float {
    let y0 = max(0, Int(y.lowerBound * Double(mask.height)))
    let y1 = min(mask.height, Int(y.upperBound * Double(mask.height)))
    let x0 = max(0, Int(x.lowerBound * Double(mask.width)))
    let x1 = min(mask.width, Int(x.upperBound * Double(mask.width)))
    var sum: Float = 0
    var count: Float = 0
    guard y1 > y0, x1 > x0 else { return 0 }
    for yy in y0..<y1 {
        for xx in x0..<x1 {
            sum += mask.values[mask.index(xx, yy)]
            count += 1
        }
    }
    return sum / max(count, 1)
}

private func regionDelta(_ a: RGBImage, _ b: RGBImage, y: Range<Double>, x: Range<Double>) -> Float {
    let y0 = max(0, Int(y.lowerBound * Double(a.height)))
    let y1 = min(a.height, Int(y.upperBound * Double(a.height)))
    let x0 = max(0, Int(x.lowerBound * Double(a.width)))
    let x1 = min(a.width, Int(x.upperBound * Double(a.width)))
    var sum: Float = 0
    var count: Float = 0
    for yy in y0..<y1 {
        for xx in x0..<x1 {
            let ia = a.offset(xx, yy)
            let ib = b.offset(xx, yy)
            sum += abs(a.pixels[ia] - b.pixels[ib])
            sum += abs(a.pixels[ia + 1] - b.pixels[ib + 1])
            sum += abs(a.pixels[ia + 2] - b.pixels[ib + 2])
            count += 3
        }
    }
    return sum / max(count, 1)
}

private func regionChroma(_ image: RGBImage, y: Range<Double>, x: Range<Double>) -> Float {
    let y0 = max(0, Int(y.lowerBound * Double(image.height)))
    let y1 = min(image.height, Int(y.upperBound * Double(image.height)))
    let x0 = max(0, Int(x.lowerBound * Double(image.width)))
    let x1 = min(image.width, Int(x.upperBound * Double(image.width)))
    var sum: Float = 0
    var count: Float = 0
    for yy in y0..<y1 {
        for xx in x0..<x1 {
            let index = image.offset(xx, yy)
            sum += image.pixels[index] - image.pixels[index + 2]
            count += 1
        }
    }
    return sum / max(count, 1)
}

private func scaled(_ image: RGBImage, maxSide: Int) -> RGBImage {
    let longSide = max(image.width, image.height)
    if longSide <= maxSide { return image }
    let scale = Float(maxSide) / Float(longSide)
    let width = max(1, Int((Float(image.width) * scale).rounded()))
    let height = max(1, Int((Float(image.height) * scale).rounded()))
    var output = RGBImage(width: width, height: height, fill: 0)
    for y in 0..<height {
        let v = (Float(y) + 0.5) / Float(height)
        for x in 0..<width {
            let u = (Float(x) + 0.5) / Float(width)
            let sx = min(max(Int(u * Float(image.width)), 0), image.width - 1)
            let sy = min(max(Int(v * Float(image.height)), 0), image.height - 1)
            let source = image.offset(sx, sy)
            output.setPixel(x, y, r: image.pixels[source], g: image.pixels[source + 1], b: image.pixels[source + 2])
        }
    }
    return output
}

private func fitted(_ image: RGBImage, width: Int, height: Int) -> RGBImage {
    let scale = min(Float(width) / Float(image.width), Float(height) / Float(image.height))
    let fittedWidth = max(1, Int((Float(image.width) * scale).rounded()))
    let fittedHeight = max(1, Int((Float(image.height) * scale).rounded()))
    var output = RGBImage(width: width, height: height, fill: 0)
    let originX = (width - fittedWidth) / 2
    let originY = (height - fittedHeight) / 2
    for y in 0..<fittedHeight {
        let v = (Float(y) + 0.5) / Float(fittedHeight)
        for x in 0..<fittedWidth {
            let u = (Float(x) + 0.5) / Float(fittedWidth)
            let sx = min(max(Int(u * Float(image.width)), 0), image.width - 1)
            let sy = min(max(Int(v * Float(image.height)), 0), image.height - 1)
            let source = image.offset(sx, sy)
            output.setPixel(
                originX + x,
                originY + y,
                r: image.pixels[source],
                g: image.pixels[source + 1],
                b: image.pixels[source + 2]
            )
        }
    }
    return output
}

private func writeRegression(before: RGBImage, mask: MaskBuffer, after: RGBImage, name: String, target: RGBImage? = nil) {
    guard let directory = ProcessInfo.processInfo.environment["DEWRINKLE_REGRESSION_DIR"], !directory.isEmpty else { return }
    let folder = URL(fileURLWithPath: directory, isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let aligned = mask.resized(toWidth: before.width, height: before.height)
    let reference = target.map { fitted($0, width: before.width, height: before.height) }
    let panels = 3
    let width = before.width * panels
    let height = before.height
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<before.width {
            let source = before.offset(x, y)
            let edited = after.offset(x, y)
            let coverage = aligned.values[y * before.width + x]
            for panel in 0..<panels {
                let origin = panel * before.width
                let destination = (y * width + origin + x) * 4
                var red = before.pixels[source]
                var green = before.pixels[source + 1]
                var blue = before.pixels[source + 2]
                if panel == 2 {
                    red = after.pixels[edited]
                    green = after.pixels[edited + 1]
                    blue = after.pixels[edited + 2]
                }
                if panel == 3, let reference {
                    let index = reference.offset(x, y)
                    red = reference.pixels[index]
                    green = reference.pixels[index + 1]
                    blue = reference.pixels[index + 2]
                }
                if panel == 1, reference == nil {
                    red = red * (1 - coverage) + coverage
                    green *= 1 - coverage * 0.85
                    blue *= 1 - coverage * 0.85
                }
                if panel == 1, reference != nil {
                    red = after.pixels[edited]
                    green = after.pixels[edited + 1]
                    blue = after.pixels[edited + 2]
                }
                if panel == 2, let reference {
                    let index = reference.offset(x, y)
                    red = reference.pixels[index]
                    green = reference.pixels[index + 1]
                    blue = reference.pixels[index + 2]
                }
                bytes[destination] = UInt8((min(max(red, 0), 1) * 255).rounded())
                bytes[destination + 1] = UInt8((min(max(green, 0), 1) * 255).rounded())
                bytes[destination + 2] = UInt8((min(max(blue, 0), 1) * 255).rounded())
            }
        }
    }
    let data = Data(bytes) as CFData
    guard let provider = CGDataProvider(data: data),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(
            folder.appendingPathComponent("\(name).png") as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
          ) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

