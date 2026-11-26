import Foundation

/// One orientation change, in top-left image coordinates (v grows downward).
public enum PictureTurn: String, Equatable, Sendable {
    case clockwise
    case counterClockwise
    case flipHorizontal
    case flipVertical

    public var swapsAxes: Bool {
        switch self {
        case .clockwise, .counterClockwise: return true
        case .flipHorizontal, .flipVertical: return false
        }
    }

    /// Normalized point, origin top-left.
    public func map(_ point: SIMD2<Float>) -> SIMD2<Float> {
        let u = point.x
        let v = point.y
        switch self {
        case .clockwise:
            return SIMD2(1 - v, u)
        case .counterClockwise:
            return SIMD2(v, 1 - u)
        case .flipHorizontal:
            return SIMD2(1 - u, v)
        case .flipVertical:
            return SIMD2(u, 1 - v)
        }
    }
}

extension RGBImage {
    public func applying(_ turn: PictureTurn) -> RGBImage {
        let newWidth = turn.swapsAxes ? height : width
        let newHeight = turn.swapsAxes ? width : height
        var output = RGBImage(width: max(newWidth, 1), height: max(newHeight, 1), fill: 0)
        guard width > 0, height > 0 else { return output }
        for y in 0..<height {
            for x in 0..<width {
                let mapped = turn.map(SIMD2(
                    (Float(x) + 0.5) / Float(width),
                    (Float(y) + 0.5) / Float(height)
                ))
                let nx = min(max(Int(mapped.x * Float(newWidth)), 0), newWidth - 1)
                let ny = min(max(Int(mapped.y * Float(newHeight)), 0), newHeight - 1)
                let source = offset(x, y)
                output.setPixel(nx, ny, r: pixels[source], g: pixels[source + 1], b: pixels[source + 2])
            }
        }
        return output
    }
}

extension MaskBuffer {
    public func applying(_ turn: PictureTurn) -> MaskBuffer {
        let newWidth = turn.swapsAxes ? height : width
        let newHeight = turn.swapsAxes ? width : height
        var output = MaskBuffer(width: newWidth, height: newHeight, fill: 0)
        for y in 0..<height {
            for x in 0..<width {
                let mapped = turn.map(SIMD2(
                    (Float(x) + 0.5) / Float(width),
                    (Float(y) + 0.5) / Float(height)
                ))
                let nx = min(max(Int(mapped.x * Float(newWidth)), 0), newWidth - 1)
                let ny = min(max(Int(mapped.y * Float(newHeight)), 0), newHeight - 1)
                output.values[ny * newWidth + nx] = values[y * width + x]
            }
        }
        return output
    }
}

