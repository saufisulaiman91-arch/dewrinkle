import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import DewrinkleCore

enum ImageFileError: LocalizedError {
    case unreadable
    case unsupported(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "That file couldn’t be read as a TIFF, JPEG, or PNG."
        case .unsupported(let message):
            return message
        case .exportFailed(let message):
            return message
        }
    }
}

final class LoadedPhoto {
    let url: URL
    let source: SourceContainer
    let bitDepth: Int
    let orientedWidth: Int
    let orientedHeight: Int
    let colorSpace: CGColorSpace
    let profileName: String
    let properties: [CFString: Any]
    let preview: CGImage
    let previewCI: CIImage
    let previewRGB: RGBImage

    init(
        url: URL,
        source: SourceContainer,
        bitDepth: Int,
        orientedWidth: Int,
        orientedHeight: Int,
        colorSpace: CGColorSpace,
        profileName: String,
        properties: [CFString: Any],
        preview: CGImage,
        previewCI: CIImage,
        previewRGB: RGBImage
    ) {
        self.url = url
        self.source = source
        self.bitDepth = bitDepth
        self.orientedWidth = orientedWidth
        self.orientedHeight = orientedHeight
        self.colorSpace = colorSpace
        self.profileName = profileName
        self.properties = properties
        self.preview = preview
        self.previewCI = previewCI
        self.previewRGB = previewRGB
    }

    var statusLine: String {
        let depth = bitDepth >= 16 ? "16-bit" : "8-bit"
        let kind: String
        switch source {
        case .jpeg: kind = "JPEG"
        case .tiff: kind = "TIFF"
        case .png: kind = "PNG"
        case .other: kind = "Image"
        }
        return "\(orientedWidth) × \(orientedHeight) · \(kind) \(depth) · \(profileName) · 32-bit float"
    }

    var fullShortSide: Int { min(orientedWidth, orientedHeight) }

    var previewPixelScale: Float {
        Float(min(preview.width, preview.height)) / Float(max(fullShortSide, 1))
    }
}

enum ImageFile {
    static let previewMaxPixel: CGFloat = 2048

    static func load(url: URL) throws -> LoadedPhoto {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageFileError.unreadable
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw ImageFileError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: previewMaxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImageFileError.unreadable
        }

        let pixelWidth = intValue(properties[kCGImagePropertyPixelWidth]) ?? preview.width
        let pixelHeight = intValue(properties[kCGImagePropertyPixelHeight]) ?? preview.height
        let orientation = ImageOrientation(exif: intValue(properties[kCGImagePropertyOrientation]) ?? 1)
        let oriented = orientation.orientedSize(width: pixelWidth, height: pixelHeight)
        let container = container(for: source, url: url)
        let depth = intValue(properties[kCGImagePropertyDepth]) ?? preview.bitsPerComponent
        let (colorSpace, profileName) = colorSpace(from: preview, properties: properties)
        let previewRGB = CGBridge.rgbImage(from: preview)
        let previewCI = CIImage(cgImage: preview)

        return LoadedPhoto(
            url: url,
            source: container,
            bitDepth: depth,
            orientedWidth: oriented.width,
            orientedHeight: oriented.height,
            colorSpace: colorSpace,
            profileName: profileName,
            properties: properties,
            preview: preview,
            previewCI: previewCI,
            previewRGB: previewRGB
        )
    }

    static func write(
        rgba: [Float],
        width: Int,
        height: Int,
        to url: URL,
        settings: ExportSettings,
        colorSpace: CGColorSpace,
        properties: [CFString: Any]
    ) throws {
        let image: CGImage
        switch settings.container {
        case .jpeg:
            guard let cg = jpegImage(rgba: rgba, width: width, height: height, colorSpace: colorSpace) else {
                throw ImageFileError.exportFailed("Couldn’t build the JPEG image.")
            }
            image = cg
        case .tiff16, .png16:
            guard let cg = tiff16Image(rgba: rgba, width: width, height: height, colorSpace: colorSpace) else {
                throw ImageFileError.exportFailed("Couldn’t build the 16-bit image.")
            }
            image = cg
        }
        let type: CFString
        switch settings.container {
        case .jpeg: type = UTType.jpeg.identifier as CFString
        case .tiff16: type = UTType.tiff.identifier as CFString
        case .png16: type = UTType.png.identifier as CFString
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw ImageFileError.exportFailed("Couldn’t create \(url.lastPathComponent).")
        }
        let metadata = exportProperties(settings: settings, source: properties)
        CGImageDestinationAddImage(destination, image, metadata as CFDictionary)
        if !CGImageDestinationFinalize(destination) {
            throw ImageFileError.exportFailed("ImageIO didn’t finish writing \(url.lastPathComponent).")
        }
    }

    static func suggestedName(for photo: LoadedPhoto, settings: ExportSettings) -> String {
        let base = photo.url.deletingPathExtension().lastPathComponent
        return "\(base)_dewrinkle.\(settings.container.fileExtension)"
    }

    static func siblingURL(for photo: LoadedPhoto, settings: ExportSettings) -> URL {
        let directory = photo.url.deletingLastPathComponent()
        return directory.appendingPathComponent(suggestedName(for: photo, settings: settings))
    }

    static func sameContainer(_ photo: LoadedPhoto, _ settings: ExportSettings) -> Bool {
        switch (photo.source, settings.container) {
        case (.jpeg, .jpeg), (.tiff, .tiff16), (.png, .png16):
            return true
        default:
            return false
        }
    }

    private static func container(for source: CGImageSource, url: URL) -> SourceContainer {
        let type = CGImageSourceGetType(source) as String? ?? ""
        if type == UTType.jpeg.identifier { return .jpeg }
        if type == UTType.tiff.identifier { return .tiff }
        if type == UTType.png.identifier { return .png }
        return SourceContainer(fileExtension: url.pathExtension)
    }

    private static func colorSpace(from image: CGImage, properties: [CFString: Any]) -> (CGColorSpace, String) {
        let name = properties[kCGImagePropertyProfileName] as? String
        if let space = image.colorSpace, space.model == .rgb {
            return (space, name ?? space.name as String? ?? "Color profile")
        }
        if let icc = image.colorSpace?.copyICCData(), let space = CGColorSpace(iccData: icc), space.model == .rgb {
            return (space, name ?? "Color profile")
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return (srgb, name ?? "Untagged · sRGB on export")
    }

    private static func exportProperties(settings: ExportSettings, source: [CFString: Any]) -> [CFString: Any] {
        var output: [CFString: Any] = [:]
        let passthrough = [
            kCGImagePropertyExifDictionary,
            kCGImagePropertyExifAuxDictionary,
            kCGImagePropertyIPTCDictionary,
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyMakerAppleDictionary
        ]
        for key in passthrough {
            if let value = source[key] {
                output[key] = value
            }
        }
        var tiff = nestedDictionary(source, key: kCGImagePropertyTIFFDictionary)
        tiff[kCGImagePropertyTIFFOrientation] = 1
        if settings.container == .tiff16 {
            tiff[kCGImagePropertyTIFFCompression] = 5
        }
        if !tiff.isEmpty {
            output[kCGImagePropertyTIFFDictionary] = tiff
        }
        output[kCGImagePropertyOrientation] = 1
        if let dpiW = source[kCGImagePropertyDPIWidth] { output[kCGImagePropertyDPIWidth] = dpiW }
        if let dpiH = source[kCGImagePropertyDPIHeight] { output[kCGImagePropertyDPIHeight] = dpiH }
        if let profile = source[kCGImagePropertyProfileName] { output[kCGImagePropertyProfileName] = profile }
        if settings.container == .jpeg {
            output[kCGImageDestinationLossyCompressionQuality] = settings.jpegQuality
        }
        if settings.container == .tiff16 {
            output[kCGImagePropertyTIFFCompression] = 5
        }
        return output
    }

    private static func nestedDictionary(_ properties: [CFString: Any], key: CFString) -> [CFString: Any] {
        if let typed = properties[key] as? [CFString: Any] {
            return typed
        }
        if let typed = properties[key] as? [String: Any] {
            var output: [CFString: Any] = [:]
            for (name, value) in typed {
                output[name as CFString] = value
            }
            return output
        }
        return [:]
    }

    private static func jpegImage(rgba: [Float], width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let count = min(width * height, rgba.count / 4)
        for index in 0..<count {
            bytes[index * 4] = PixelDepth.quantize8(rgba[index * 4])
            bytes[index * 4 + 1] = PixelDepth.quantize8(rgba[index * 4 + 1])
            bytes[index * 4 + 2] = PixelDepth.quantize8(rgba[index * 4 + 2])
        }
        return CGBridge.rgba8Image(bytes: bytes, width: width, height: height, colorSpace: colorSpace)
    }

    private static func tiff16Image(rgba: [Float], width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
        let rowSamples = width * 3
        let paddedRow = (rowSamples + 7) & ~7
        var samples = [UInt16](repeating: 0, count: paddedRow * height)
        let count = min(width * height, rgba.count / 4)
        for index in 0..<count {
            let y = index / width
            let x = index - y * width
            let destination = y * paddedRow + x * 3
            samples[destination] = PixelDepth.quantize16(rgba[index * 4])
            samples[destination + 1] = PixelDepth.quantize16(rgba[index * 4 + 1])
            samples[destination + 2] = PixelDepth.quantize16(rgba[index * 4 + 2])
        }
        let data = samples.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
            .union(.byteOrder16Little)
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 16,
            bitsPerPixel: 48,
            bytesPerRow: paddedRow * MemoryLayout<UInt16>.size,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
