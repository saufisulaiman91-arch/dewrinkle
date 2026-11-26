import Foundation

public enum BrushMode: String, Equatable, Sendable {
    case paint
    case restore
}

public struct BrushSettings: Equatable, Sendable {
    /// Radius in full-resolution image pixels.
    public var radius: Float
    public var hardness: Float
    public var opacity: Float
    public var mode: BrushMode

    public init(radius: Float, hardness: Float, opacity: Float, mode: BrushMode) {
        self.radius = max(0.5, radius)
        self.hardness = clamp01(hardness)
        self.opacity = clamp01(opacity)
        self.mode = mode
    }

    public static let standard = BrushSettings(radius: 220, hardness: 0.65, opacity: 1, mode: .paint)
}

public struct BrushStroke: Equatable, Sendable {
    public var mode: BrushMode
    public var radiusPixels: Float
    /// Oriented full-resolution width the radius is measured against.
    public var referenceWidth: Int
    public var hardness: Float
    public var opacity: Float
    /// Normalized image position, origin top-left.
    public var points: [SIMD2<Float>]

    public init(settings: BrushSettings, referenceWidth: Int, points: [SIMD2<Float>]) {
        self.mode = settings.mode
        self.radiusPixels = max(0.5, settings.radius)
        self.referenceWidth = max(referenceWidth, 1)
        self.hardness = clamp01(settings.hardness)
        self.opacity = clamp01(settings.opacity)
        self.points = points
    }
}

public struct MaskDocument: Equatable, Sendable {
    public private(set) var base: MaskBuffer?
    public private(set) var strokes: [BrushStroke]
    public private(set) var undone: [BrushStroke]

    public init() {
        base = nil
        strokes = []
        undone = []
    }

    public var canUndo: Bool { !strokes.isEmpty }
    public var canRedo: Bool { !undone.isEmpty }

    public mutating func setBase(_ mask: MaskBuffer?) {
        base = mask
    }

    public mutating func add(_ stroke: BrushStroke) {
        guard !stroke.points.isEmpty else { return }
        strokes.append(stroke)
        undone.removeAll()
    }

    public mutating func undo() {
        guard let stroke = strokes.popLast() else { return }
        undone.append(stroke)
    }

    public mutating func redo() {
        guard let stroke = undone.popLast() else { return }
        strokes.append(stroke)
    }

    public mutating func clear() {
        base = nil
        strokes.removeAll()
        undone.removeAll()
    }

    public func rasterize(width: Int, height: Int, extra: BrushStroke? = nil) -> MaskBuffer {
        var mask = base?.resized(toWidth: width, height: height) ?? MaskBuffer(width: width, height: height, fill: 0)
        for stroke in strokes {
            BrushRasterizer.stamp(&mask, stroke: stroke)
        }
        if let extra, !extra.points.isEmpty {
            BrushRasterizer.stamp(&mask, stroke: extra)
        }
        return mask
    }
}

public enum BrushRasterizer {
    public static func weight(dx: Float, dy: Float, radius: Float, hardness: Float, opacity: Float) -> Float {
        if radius <= 0 || opacity <= 0 { return 0 }
        let distance = hypot(dx, dy)
        if distance >= radius { return 0 }
        let inner = min(max(hardness, 0), 0.999) * radius
        if distance <= inner { return opacity }
        let t = (distance - inner) / (radius - inner)
        return opacity * (1 - smoothstep(0, 1, t))
    }

    /// Inserts dabs so a fast drag does not leave gaps. Spacing is a fraction of the radius.
    public static func densify(_ points: [SIMD2<Float>], normalizedSpacing: Float) -> [SIMD2<Float>] {
        guard let first = points.first else { return [] }
        if points.count == 1 || normalizedSpacing <= 0 { return points }
        var output: [SIMD2<Float>] = [first]
        var last = first
        for point in points.dropFirst() {
            var from = last
            var remaining = point - from
            var distance = hypot(remaining.x, remaining.y)
            while distance >= normalizedSpacing {
                let step = remaining / distance * normalizedSpacing
                from += step
                output.append(from)
                last = from
                remaining = point - from
                distance = hypot(remaining.x, remaining.y)
            }
        }
        return output
    }

    public static func stamp(_ mask: inout MaskBuffer, stroke: BrushStroke) {
        let scale = Float(mask.width) / Float(max(stroke.referenceWidth, 1))
        let radius = max(0.5, stroke.radiusPixels * scale)
        let spacing = (stroke.radiusPixels * 0.22) / Float(stroke.referenceWidth)
        let dabs = densify(stroke.points, normalizedSpacing: spacing)
        for dab in dabs {
            let centerX = dab.x * Float(mask.width)
            let centerY = dab.y * Float(mask.height)
            let minX = max(0, Int(floor(centerX - radius)))
            let maxX = min(mask.width - 1, Int(ceil(centerX + radius)))
            let minY = max(0, Int(floor(centerY - radius)))
            let maxY = min(mask.height - 1, Int(ceil(centerY + radius)))
            if maxX < minX || maxY < minY { continue }
            for y in minY...maxY {
                for x in minX...maxX {
                    let dx = (Float(x) + 0.5) - centerX
                    let dy = (Float(y) + 0.5) - centerY
                    let amount = weight(
                        dx: dx,
                        dy: dy,
                        radius: radius,
                        hardness: stroke.hardness,
                        opacity: stroke.opacity
                    )
                    if amount <= 0 { continue }
                    let index = y * mask.width + x
                    switch stroke.mode {
                    case .paint:
                        mask.values[index] += amount * (1 - mask.values[index])
                    case .restore:
                        mask.values[index] *= (1 - amount)
                    }
                }
            }
        }
    }
}
