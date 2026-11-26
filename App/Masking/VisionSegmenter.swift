import CoreGraphics
import CoreVideo
import Foundation
import Vision
import DewrinkleCore

/// Vision person mask, with a foreground-instance fallback for product shots
/// that have no person. Face boxes are returned separately so
/// `GarmentMaskRefinement` can take them out. A future SAM 2 model does not
/// replace this type; it adopts `ClickSelecting` on its own.
final class VisionForegroundSegmenter: ForegroundSegmenting {
    func foregroundMask(for image: RGBImage) async throws -> MaskBuffer {
        guard let cgImage = CGBridge.cgImage(from: image) else {
            throw MaskingError.failed("Couldn’t read the preview for segmentation.")
        }
        let width = image.width
        let height = image.height
        return try await Task.detached(priority: .userInitiated) {
            try Self.segment(cgImage, width: width, height: height)
        }.value
    }

    static func faces(in image: CGImage) throws -> [NormalizedRect] {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).map { face in
            let box = face.boundingBox
            return NormalizedRect(
                x: Float(box.origin.x),
                y: Float(1 - box.origin.y - box.height),
                width: Float(box.width),
                height: Float(box.height)
            )
        }
    }

    private static func segment(_ image: CGImage, width: Int, height: Int) throws -> MaskBuffer {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .accurate
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try handler.perform([person])
        if let buffer = person.results?.first?.pixelBuffer {
            let mask = maskBuffer(from: buffer).resized(toWidth: width, height: height)
            if mask.mean() > 0.02 {
                return mask
            }
        }

        let foreground = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([foreground])
        if let observation = foreground.results?.first, !observation.allInstances.isEmpty {
            let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
            return maskBuffer(from: buffer).resized(toWidth: width, height: height)
        }
        return MaskBuffer(width: width, height: height, fill: 0)
    }

    private static func maskBuffer(from buffer: CVPixelBuffer) -> MaskBuffer {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else {
            return MaskBuffer(width: 1, height: 1, fill: 0)
        }
        var mask = MaskBuffer(width: width, height: height, fill: 0)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if format == kCVPixelFormatType_OneComponent32Float {
            let row = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float>.size
            let pointer = base.assumingMemoryBound(to: Float.self)
            for y in 0..<height {
                for x in 0..<width {
                    mask.values[y * width + x] = min(max(pointer[y * row + x], 0), 1)
                }
            }
            return mask
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                mask.values[y * width + x] = Float(pointer[y * rowBytes + x]) / 255
            }
        }
        return mask
    }
}
