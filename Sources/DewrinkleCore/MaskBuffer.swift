import Foundation

/// Single-channel mask, 0 = leave the photo alone, 1 = full effect. Row 0 is the top.
public struct MaskBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var values: [Float]

    public init(width: Int, height: Int, fill: Float = 0) {
        precondition(width > 0 && height > 0)
        self.width = width
        self.height = height
        self.values = [Float](repeating: clamp01(fill), count: width * height)
    }

    public init(width: Int, height: Int, values: [Float]) {
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    public func index(_ x: Int, _ y: Int) -> Int {
        y * width + x
    }

    public func maximum() -> Float {
        values.max() ?? 0
    }

    public func mean() -> Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Float(values.count)
    }

    public func sample(_ x: Float, _ y: Float) -> Float {
        if values.isEmpty { return 0 }
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let x1 = x0 + 1
        let y1 = y0 + 1
        let tx = x - Float(x0)
        let ty = y - Float(y0)
        let v00 = clamped(x0, y0)
        let v10 = clamped(x1, y0)
        let v01 = clamped(x0, y1)
        let v11 = clamped(x1, y1)
        let top = v00 + (v10 - v00) * tx
        let bottom = v01 + (v11 - v01) * tx
        return top + (bottom - top) * ty
    }

    /// `u` and `v` are 0...1 across the image, origin top-left, continuous pixel centers.
    public func sampleNormalized(u: Float, v: Float) -> Float {
        let x = u * Float(width) - 0.5
        let y = v * Float(height) - 0.5
        return sample(x, y)
    }

    public func resized(toWidth newWidth: Int, height newHeight: Int) -> MaskBuffer {
        precondition(newWidth > 0 && newHeight > 0)
        if newWidth == width && newHeight == height { return self }
        var output = MaskBuffer(width: newWidth, height: newHeight, fill: 0)
        for y in 0..<newHeight {
            let v = (Float(y) + 0.5) / Float(newHeight)
            for x in 0..<newWidth {
                let u = (Float(x) + 0.5) / Float(newWidth)
                output.values[y * newWidth + x] = sampleNormalized(u: u, v: v)
            }
        }
        return output
    }

    private func clamped(_ x: Int, _ y: Int) -> Float {
        let xx = min(max(x, 0), width - 1)
        let yy = min(max(y, 0), height - 1)
        return values[yy * width + xx]
    }
}
