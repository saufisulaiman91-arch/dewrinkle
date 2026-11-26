import Foundation

/// Head-scarf region inside a person mask, separate from the face and from body clothing.
/// Seeds are the fabric pixels that frame the face. Colour similarity then grows the drape,
/// and the result is kept inside the person and inside a window from above the head to the chest.
public enum HijabRegion {
    public static func searchWindow(around face: NormalizedRect) -> NormalizedRect {
        let side = face.width * 0.9
        let above = face.height * 1.8
        let drape = face.height * 1.25
        return NormalizedRect(
            x: face.x - side,
            y: face.y - above,
            width: face.width + side * 2,
            height: face.height + above + drape
        ).clampedToUnitSquare()
    }

    public static func mask(
        image: RGBImage,
        person: MaskBuffer,
        faces: [NormalizedRect],
        skin: MaskBuffer,
        tolerance: Float
    ) -> MaskBuffer {
        let width = image.width
        let height = image.height
        let subject = person.resized(toWidth: width, height: height)
        let faceSkin = skin.resized(toWidth: width, height: height)
        var hijab = MaskBuffer(width: width, height: height, fill: 0)
        guard !faces.isEmpty else { return hijab }
        for face in faces {
            let window = searchWindow(around: face)
            let seeds = ringSeeds(image: image, person: subject, face: face, skin: faceSkin, window: window)
            guard seeds.maximum() > 0.2 else { continue }
            let grown = RegionGrow.grow(image, seeds: seeds, tolerance: tolerance)
            let limited = limit(grown, to: window, person: subject, excluding: faceSkin)
            for index in hijab.values.indices {
                hijab.values[index] = max(hijab.values[index], limited.values[index])
            }
        }
        return hijab
    }

    /// Pixels just outside the face oval, on the person, not on skin, inside the scarf window.
    static func ringSeeds(
        image: RGBImage,
        person: MaskBuffer,
        face: NormalizedRect,
        skin: MaskBuffer,
        window: NormalizedRect
    ) -> MaskBuffer {
        let width = image.width
        let height = image.height
        var seeds = MaskBuffer(width: width, height: height, fill: 0)
        let centerX = face.x + face.width / 2
        let centerY = face.y + face.height / 2
        let radiusX = max(face.width * 0.5, 0.001)
        let radiusY = max(face.height * 0.5, 0.001)
        for y in 0..<height {
            let v = (Float(y) + 0.5) / Float(height)
            for x in 0..<width {
                let u = (Float(x) + 0.5) / Float(width)
                guard contains(window, u: u, v: v) else { continue }
                let index = y * width + x
                guard person.values[index] > 0.45, skin.values[index] < 0.25 else { continue }
                let ellipse = hypot((u - centerX) / radiusX, (v - centerY) / radiusY)
                if ellipse > 1.08 && ellipse < 1.85 {
                    seeds.values[index] = 1
                }
            }
        }
        return seeds
    }

    private static func limit(
        _ grown: MaskBuffer,
        to window: NormalizedRect,
        person: MaskBuffer,
        excluding skin: MaskBuffer
    ) -> MaskBuffer {
        var output = grown
        let width = grown.width
        let height = grown.height
        for y in 0..<height {
            let v = (Float(y) + 0.5) / Float(height)
            for x in 0..<width {
                let index = y * width + x
                let u = (Float(x) + 0.5) / Float(width)
                if !contains(window, u: u, v: v) || person.values[index] < 0.35 || skin.values[index] > 0.45 {
                    output.values[index] = 0
                }
            }
        }
        return output
    }

    private static func contains(_ rect: NormalizedRect, u: Float, v: Float) -> Bool {
        u >= rect.x && v >= rect.y && u <= rect.x + rect.width && v <= rect.y + rect.height
    }
}

extension NormalizedRect {
    func clampedToUnitSquare() -> NormalizedRect {
        let minX = min(max(x, 0), 1)
        let minY = min(max(y, 0), 1)
        let maxX = min(max(x + width, 0), 1)
        let maxY = min(max(y + height, 0), 1)
        return NormalizedRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }
}
