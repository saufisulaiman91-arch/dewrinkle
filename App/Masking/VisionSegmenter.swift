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
        try await maskedGarment(for: image)
    }

    /// Person mask with faces and hands cut out. Skin color is not used: pink
    /// satin scores as skin and would lose the dress. Face rectangles, face
    /// landmarks, and hand pose are geometry, so the cloth stays.
    func maskedGarment(for image: RGBImage) async throws -> MaskBuffer {
        guard let cgImage = CGBridge.cgImage(from: image) else {
            throw MaskingError.failed("Couldn’t read the preview for segmentation.")
        }
        let width = image.width
        let height = image.height
        return try await Task.detached(priority: .userInitiated) {
            let person = try Self.segment(cgImage, width: width, height: height)
            let faces = (try? Self.faces(in: cgImage)) ?? []
            let hands = (try? Self.hands(in: cgImage)) ?? []
            return GarmentMaskRefinement.refine(
                person: person,
                image: image,
                faces: faces,
                skinStrength: 0,
                hands: hands
            )
        }.value
    }

    static func faces(in image: CGImage) throws -> [DewrinkleCore.NormalizedRect] {
        let rectangles = VNDetectFaceRectanglesRequest()
        let landmarks = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([rectangles, landmarks])
        let observations = landmarks.results?.isEmpty == false ? (landmarks.results ?? []) : (rectangles.results ?? [])
        return observations.map { face in
            topLeftRect(faceBox(face), padX: 1.7, padY: 1.95)
        }
    }

    static func hands(in image: CGImage) throws -> [DewrinkleCore.NormalizedRect] {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 6
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])
        var rects: [DewrinkleCore.NormalizedRect] = []
        for observation in request.results ?? [] {
            guard let box = handBox(observation) else { continue }
            rects.append(topLeftRect(box, padX: 1.85, padY: 1.85))
        }
        return rects
    }

    /// Vision boxes are normalized with a bottom-left origin. Masks and the
    /// canvas use a top-left origin. `padX`/`padY` grow the box around its center.
    static func topLeftRect(_ box: CGRect, padX: CGFloat, padY: CGFloat) -> DewrinkleCore.NormalizedRect {
        let width = min(1, max(box.width * padX, 0))
        let height = min(1, max(box.height * padY, 0))
        var x = box.midX - width / 2
        var y = box.midY - height / 2
        x = min(max(x, 0), 1)
        y = min(max(y, 0), 1)
        let clampedWidth = min(width, 1 - x)
        let clampedHeight = min(height, 1 - y)
        let top = 1 - (y + clampedHeight)
        return DewrinkleCore.NormalizedRect(
            x: Float(x),
            y: Float(min(max(top, 0), 1)),
            width: Float(clampedWidth),
            height: Float(clampedHeight)
        )
    }

    private static func faceBox(_ face: VNFaceObservation) -> CGRect {
        let box = face.boundingBox
        guard let points = face.landmarks?.allPoints?.normalizedPoints, !points.isEmpty else {
            return box
        }
        var minX = CGFloat(1)
        var minY = CGFloat(1)
        var maxX = CGFloat(0)
        var maxY = CGFloat(0)
        for point in points {
            let imageX = box.origin.x + point.x * box.width
            let imageY = box.origin.y + point.y * box.height
            minX = min(minX, imageX)
            minY = min(minY, imageY)
            maxX = max(maxX, imageX)
            maxY = max(maxY, imageY)
        }
        guard maxX > minX, maxY > minY else { return box }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func handBox(_ observation: VNHumanHandPoseObservation) -> CGRect? {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        var minX = CGFloat(1)
        var minY = CGFloat(1)
        var maxX = CGFloat(0)
        var maxY = CGFloat(0)
        var count = 0
        for (_, point) in points where point.confidence > 0.15 {
            minX = min(minX, point.location.x)
            minY = min(minY, point.location.y)
            maxX = max(maxX, point.location.x)
            maxY = max(maxY, point.location.y)
            count += 1
        }
        guard count >= 3, maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    struct Regions {
        var subject: MaskBuffer
        var background: MaskBuffer
        var skin: MaskBuffer
        var hijab: MaskBuffer
        var clothing: MaskBuffer
    }

    func regions(for image: RGBImage, tolerance: Float = 0.14) async throws -> Regions {
        guard let cgImage = CGBridge.cgImage(from: image) else {
            throw MaskingError.failed("Couldn’t read the preview for segmentation.")
        }
        return try await Task.detached(priority: .userInitiated) {
            let subject = try Self.segment(cgImage, width: image.width, height: image.height)
                .resized(toWidth: image.width, height: image.height)
            let faces = (try? Self.faces(in: cgImage)) ?? []
            let hands = (try? Self.hands(in: cgImage)) ?? []
            let skin = Self.skinMask(image: image, faces: faces, hands: hands)
            let hijab = HijabRegion.mask(
                image: image,
                person: subject,
                faces: faces,
                skin: skin,
                tolerance: tolerance
            )
            let clothing = Self.subtract(hijab, from: Self.subtract(skin, from: subject))
            let background = Self.invert(subject)
            return Regions(
                subject: subject,
                background: background,
                skin: skin,
                hijab: hijab,
                clothing: clothing
            )
        }.value
    }

    func region(for image: RGBImage, at point: SIMD2<Float>, tolerance: Float) async throws -> (MaskBuffer, String) {
        let built = try await regions(for: image, tolerance: tolerance)
        if let choice = Self.choice(in: built, at: point) {
            return choice
        }
        let grown = RegionGrow.mask(of: image, seedU: point.x, seedV: point.y, tolerance: tolerance)
        return (grown, "Colour region")
    }

    private static func choice(in regions: Regions, at point: SIMD2<Float>) -> (MaskBuffer, String)? {
        let candidates: [(MaskBuffer, String)] = [
            (regions.skin, "Select skin"),
            (regions.hijab, "Select hijab"),
            (regions.clothing, "Select clothing"),
            (regions.subject, "Select subject"),
            (regions.background, "Select background")
        ]
        for (mask, name) in candidates where mask.sampleNormalized(u: point.x, v: point.y) > 0.35 {
            return (mask, name)
        }
        return nil
    }

    private static func skinMask(image: RGBImage, faces: [DewrinkleCore.NormalizedRect], hands: [DewrinkleCore.NormalizedRect]) -> MaskBuffer {
        var seeds = MaskBuffer(width: image.width, height: image.height, fill: 0)
        for rect in faces + hands {
            stamp(rect, into: &seeds)
        }
        guard seeds.maximum() > 0.2 else {
            return seeds
        }
        return RegionGrow.grow(image, seeds: seeds, tolerance: 0.16)
    }

    private static func stamp(_ rect: DewrinkleCore.NormalizedRect, into mask: inout MaskBuffer) {
        let width = mask.width
        let height = mask.height
        let minX = max(0, Int(rect.x * Float(width)))
        let maxX = min(width - 1, Int((rect.x + rect.width) * Float(width)))
        let minY = max(0, Int(rect.y * Float(height)))
        let maxY = min(height - 1, Int((rect.y + rect.height) * Float(height)))
        guard maxX >= minX, maxY >= minY else { return }
        for y in minY...maxY {
            for x in minX...maxX {
                mask.values[y * width + x] = 1
            }
        }
    }

    private static func invert(_ mask: MaskBuffer) -> MaskBuffer {
        var output = mask
        for index in output.values.indices {
            output.values[index] = 1 - output.values[index]
        }
        return output
    }

    private static func subtract(_ cut: MaskBuffer, from mask: MaskBuffer) -> MaskBuffer {
        let aligned = cut.resized(toWidth: mask.width, height: mask.height)
        var output = mask
        for index in output.values.indices {
            output.values[index] = max(0, output.values[index] * (1 - aligned.values[index]))
        }
        return output
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

/// Vision stand-in for `ClickSelecting` until a SAM 2 Core ML model is installed.
final class VisionClickSelector: ClickSelecting {
    var tolerance: Float = 0.12

    func mask(for image: RGBImage, points: [ClickPoint]) async throws -> MaskBuffer {
        let segmenter = VisionForegroundSegmenter()
        var result = MaskBuffer(width: image.width, height: image.height, fill: 0)
        for point in points {
            let (region, _) = try await segmenter.region(
                for: image,
                at: SIMD2(point.x, point.y),
                tolerance: tolerance
            )
            let aligned = region.resized(toWidth: result.width, height: result.height)
            switch point.kind {
            case .include:
                for index in result.values.indices {
                    result.values[index] = max(result.values[index], aligned.values[index])
                }
            case .exclude:
                for index in result.values.indices {
                    result.values[index] *= 1 - aligned.values[index]
                }
            }
        }
        return result
    }
}
