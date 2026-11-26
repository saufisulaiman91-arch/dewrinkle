import Foundation

public enum RegionGrow {
    /// Connected pixels near the seed colour. `tolerance` is 0...1 in RGB distance.
    public static func mask(of image: RGBImage, seedU: Float, seedV: Float, tolerance: Float) -> MaskBuffer {
        let x = min(max(Int(seedU * Float(image.width)), 0), image.width - 1)
        let y = min(max(Int(seedV * Float(image.height)), 0), image.height - 1)
        var seeds = MaskBuffer(width: image.width, height: image.height, fill: 0)
        seeds.values[y * image.width + x] = 1
        return grow(image, seeds: seeds, tolerance: tolerance)
    }

    /// Grows every seed pixel into neighbouring pixels of a similar colour.
    public static func grow(_ image: RGBImage, seeds: MaskBuffer, tolerance: Float) -> MaskBuffer {
        let width = image.width
        let height = image.height
        let aligned = seeds.resized(toWidth: width, height: height)
        var mask = MaskBuffer(width: width, height: height, fill: 0)
        var seen = [Bool](repeating: false, count: width * height)
        var queue: [(Int, Int, Float, Float, Float)] = []
        for y in 0..<height {
            for x in 0..<width where aligned.values[y * width + x] > 0.5 {
                let offset = image.offset(x, y)
                seen[y * width + x] = true
                queue.append((x, y, image.pixels[offset], image.pixels[offset + 1], image.pixels[offset + 2]))
            }
        }
        let limit = max(tolerance, 0)
        var head = 0
        while head < queue.count {
            let (x, y, sr, sg, sb) = queue[head]
            head += 1
            mask.values[y * width + x] = 1
            let neighbours = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            for (nx, ny) in neighbours {
                guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                let index = ny * width + nx
                if seen[index] { continue }
                let offset = image.offset(nx, ny)
                let dr = image.pixels[offset] - sr
                let dg = image.pixels[offset + 1] - sg
                let db = image.pixels[offset + 2] - sb
                let distance = sqrt(dr * dr + dg * dg + db * db) / sqrt(3)
                if distance <= limit {
                    seen[index] = true
                    queue.append((nx, ny, image.pixels[offset], image.pixels[offset + 1], image.pixels[offset + 2]))
                }
            }
        }
        return mask
    }
}
