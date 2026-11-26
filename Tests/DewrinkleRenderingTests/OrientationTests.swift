import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DewrinkleRendering
import DewrinkleCore

final class OrientationTests: XCTestCase {
    func testLoadDisplayAndExportKeepTheTopLeft() throws {
        let source = temporaryJPEG()
        let exported = temporaryJPEG()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: exported)
        }
        try writeJPEG(width: 32, height: 48, orientation: 1, to: source) { x, y, width, height in
            if y < height / 3 && x < width / 3 { return (1, 0, 0) }
            if y > height * 2 / 3 && x > width * 2 / 3 { return (0, 0, 1) }
            return (0.04, 0.04, 0.04)
        }

        let loaded = try ImageFile.load(url: source)
        assertTopLeftIsRed(loaded.previewRGB)

        let pipeline = RenderPipeline()
        let mask = MaskBuffer(width: loaded.preview.width, height: loaded.preview.height, fill: 0)
        let edits = EditParameters(dewrinkle: DewrinkleParameters(strength: 0.7, fine: 1, coarse: 1), noise: .off)
        let displayed = try pipeline.renderPreview(
            source: loaded.previewCI,
            mask: mask,
            edits: edits,
            fullShortSide: loaded.fullShortSide,
            pixelScale: 1
        )
        assertTopLeftIsRed(CGBridge.rgbImage(from: displayed))

        let floats = try pipeline.renderExport(
            source: loaded.previewCI,
            mask: mask,
            edits: edits,
            fullShortSide: loaded.fullShortSide,
            width: loaded.preview.width,
            height: loaded.preview.height
        )
        XCTAssertGreaterThan(floats[0], 0.55, "export buffer top-left should stay red")
        XCTAssertLessThan(floats[2], 0.35)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        try ImageFile.write(
            rgba: floats,
            width: loaded.preview.width,
            height: loaded.preview.height,
            to: exported,
            settings: ExportSettings(container: .jpeg, jpegQuality: 0.95),
            colorSpace: space,
            properties: [kCGImagePropertyOrientation: 1]
        )
        let roundTrip = try ImageFile.load(url: exported)
        assertTopLeftIsRed(roundTrip.previewRGB)
    }

    func testClockwiseTurnMovesTheLeftPixelToTheTop() throws {
        var bytes: [UInt8] = [
            255, 0, 0, 255,
            0, 0, 255, 255
        ]
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let cgImage = CGImage(
                width: 2,
                height: 1,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return XCTFail("fixture")
        }
        let turned = ImageGeometry.apply(.clockwise, to: CIImage(cgImage: cgImage))
        let pipeline = RenderPipeline()
        let displayed = try pipeline.renderPreview(
            source: turned,
            mask: MaskBuffer(width: max(Int(turned.extent.width), 1), height: max(Int(turned.extent.height), 1), fill: 0),
            edits: EditParameters(dewrinkle: DewrinkleParameters(strength: 0, fine: 0, coarse: 0), noise: .off),
            fullShortSide: 1,
            pixelScale: 1
        )
        let rgb = CGBridge.rgbImage(from: displayed)
        XCTAssertEqual(rgb.width, 1)
        XCTAssertEqual(rgb.height, 2)
        XCTAssertGreaterThan(rgb.pixels[rgb.offset(0, 0)], 0.5, "left pixel should become the top pixel")
        XCTAssertGreaterThan(rgb.pixels[rgb.offset(0, 1) + 2], 0.5, "right pixel should become the bottom pixel")
    }

    func testExifOrientationSixIsUpright() throws {
        let source = temporaryJPEG()
        defer { try? FileManager.default.removeItem(at: source) }
        // Orientation 6 rotates the stored bitmap 90° clockwise. The stored
        // bottom-left becomes the upright top-left, which is how a Z8 portrait
        // JPEG is tagged when the pixels are still in sensor order.
        try writeJPEG(width: 64, height: 40, orientation: 6, to: source) { x, y, _, height in
            if x < 14 && y >= height - 14 { return (1, 0, 0) }
            if x > 50 && y < 10 { return (0, 0, 1) }
            return (0.08, 0.08, 0.08)
        }
        let loaded = try ImageFile.load(url: source)
        XCTAssertGreaterThan(loaded.orientedHeight, loaded.orientedWidth)
        assertTopLeftIsRed(loaded.previewRGB)
        let bottom = loaded.previewRGB.offset(1, loaded.previewRGB.height - 2)
        XCTAssertLessThan(
            loaded.previewRGB.pixels[bottom],
            loaded.previewRGB.pixels[loaded.previewRGB.offset(1, 1)],
            "orientation 6 must not leave the marker at the bottom"
        )
    }

    private func assertTopLeftIsRed(_ image: RGBImage, file: StaticString = #filePath, line: UInt = #line) {
        let top = image.offset(1, 1)
        XCTAssertGreaterThan(image.pixels[top], 0.55, "top-left should stay red", file: file, line: line)
        XCTAssertLessThan(image.pixels[top + 2], 0.35, "top-left should not be the blue corner", file: file, line: line)
        let bottom = image.offset(max(image.width - 2, 0), max(image.height - 2, 0))
        XCTAssertLessThan(image.pixels[bottom], image.pixels[top], "image is vertically flipped", file: file, line: line)
    }

    private func temporaryJPEG() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dewrinkle-\(UUID().uuidString).jpg")
    }

    private func writeJPEG(
        width: Int,
        height: Int,
        orientation: Int,
        to url: URL,
        pixel: (Int, Int, Int, Int) -> (Float, Float, Float)
    ) throws {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let sample = pixel(x, y, width, height)
                let index = (y * width + x) * 4
                bytes[index] = UInt8((min(max(sample.0, 0), 1) * 255).rounded())
                bytes[index + 1] = UInt8((min(max(sample.1, 0), 1) * 255).rounded())
                bytes[index + 2] = UInt8((min(max(sample.2, 0), 1) * 255).rounded())
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
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else {
            XCTFail("Could not build the fixture JPEG")
            return
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.97,
            kCGImagePropertyOrientation: orientation
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            XCTFail("Could not write the fixture JPEG")
        }
    }
}
