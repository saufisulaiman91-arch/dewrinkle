import AppKit
import SwiftUI
import DewrinkleCore

struct CanvasView: NSViewRepresentable {
    @ObservedObject var model: EditorModel

    func makeNSView(context: Context) -> CanvasNSView {
        let view = CanvasNSView()
        view.model = model
        return view
    }

    func updateNSView(_ view: CanvasNSView, context: Context) {
        view.model = model
        view.sync(from: model)
    }
}

final class CanvasNSView: NSView {
    weak var model: EditorModel?
    private var afterImage: CGImage?
    private var beforeImage: CGImage?
    private var overlayImage: CGImage?
    private var afterCache: NSImage?
    private var beforeCache: NSImage?
    private var overlayCache: NSImage?
    private var documentKey = ""
    private var appliedTicket = 0

    private var scale: CGFloat = 1
    private var originX: CGFloat = 0
    private var originY: CGFloat = 0
    private var pixelWidth = 0
    private var pixelHeight = 0
    private var didFit = false

    private var splitFraction: CGFloat = 0.5
    private var draggingSplit = false
    private var draggingPan = false
    private var lastDrag = NSPoint.zero
    private var stroke: [SIMD2<Float>] = []
    private var temporaryRestore = false
    private var cursorPoint: NSPoint?
    private var showBefore = false
    private var splitEnabled = false
    private var showOverlay = false
    private var brushRadius: CGFloat = 220
    private var spaceDown = false
    private var referenceWidth = 1
    private var clickSelect = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !didFit, pixelWidth > 0, newSize.width > 40, newSize.height > 40 {
            fit()
        }
    }

    func sync(from model: EditorModel) {
        let key = model.photo?.url.path ?? ""
        let photoChanged = key != documentKey
        documentKey = key
        beforeImage = model.photo?.preview
        afterImage = model.previewAfter ?? model.photo?.preview
        overlayImage = model.maskOverlay
        showBefore = model.showingOriginal
        splitEnabled = model.splitEnabled
        showOverlay = model.maskOverlayVisible && !model.showingOriginal
        brushRadius = CGFloat(model.brush.radius)
        spaceDown = model.spaceDown
        clickSelect = model.canvasTool == .clickSelect
        referenceWidth = max(model.displayReferenceWidth, 1)
        if let photo = model.photo {
            pixelWidth = photo.preview.width
            pixelHeight = photo.preview.height
        }
        rebuildCaches()
        if photoChanged {
            didFit = false
        }
        if model.viewportTicket != appliedTicket {
            appliedTicket = model.viewportTicket
            switch model.viewportAction {
            case .fit: fit()
            case .actualPixels: actualPixels()
            case .none: break
            }
        } else if !didFit, pixelWidth > 0, bounds.width > 10 {
            fit()
        }
        publishZoom()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.067, green: 0.065, blue: 0.062, alpha: 1).setFill()
        dirtyRect.fill()
        guard pixelWidth > 0, let after = afterCache else { return }
        let destination = imageRect()
        let screenScale = window?.backingScaleFactor ?? 2
        NSGraphicsContext.current?.imageInterpolation = (scale * screenScale) >= 1.2 ? .none : .high

        if splitEnabled, !showBefore, let before = beforeCache {
            draw(after, in: destination, operation: .copy)
            NSGraphicsContext.current?.saveGraphicsState()
            NSRect(x: 0, y: 0, width: splitX, height: bounds.height).clip()
            draw(before, in: destination, operation: .copy)
            NSGraphicsContext.current?.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSRect(x: splitX - 0.5, y: 0, width: 1, height: bounds.height).fill()
        } else {
            let image = showBefore ? (beforeCache ?? after) : after
            draw(image, in: destination, operation: .copy)
        }

        if showOverlay, let overlay = overlayCache {
            draw(overlay, in: destination, operation: .sourceOver)
        }

        if let cursorPoint, !spaceDown, !draggingPan, destination.contains(cursorPoint) {
            let radius = brushRadius * scale * CGFloat(pixelWidth) / CGFloat(referenceWidth)
            let rect = NSRect(x: cursorPoint.x - radius, y: cursorPoint.y - radius, width: radius * 2, height: radius * 2)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        if clickSelect {
            return
        }
        if splitEnabled, abs(point.x - splitX) < 8 {
            draggingSplit = true
            return
        }
        if spaceDown || event.buttonNumber == 2 {
            beginPan(point)
            return
        }
        guard normalized(point) != nil else { return }
        temporaryRestore = event.modifierFlags.contains(.option) || model?.brush.mode == .restore
        if model?.brush.mode == .restore { temporaryRestore = true }
        if event.modifierFlags.contains(.option) { temporaryRestore = true }
        stroke = []
        if let point = normalized(point) { stroke.append(point) }
        model?.previewStroke(points: stroke, temporaryRestore: temporaryRestore && model?.brush.mode == .paint)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cursorPoint = point
        if draggingSplit {
            splitFraction = min(max(point.x / max(bounds.width, 1), 0.04), 0.96)
            needsDisplay = true
            return
        }
        if draggingPan {
            originX -= (point.x - lastDrag.x) / scale
            originY -= (point.y - lastDrag.y) / scale
            lastDrag = point
            needsDisplay = true
            return
        }
        if spaceDown {
            beginPan(point)
            return
        }
        if let norm = normalized(point) {
            stroke.append(norm)
            let restoring = temporaryRestore && model?.brush.mode == .paint
            model?.previewStroke(points: stroke, temporaryRestore: restoring)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if clickSelect {
            if let norm = normalized(point) {
                model?.clickSelect(
                    at: norm,
                    adding: event.modifierFlags.contains(.shift),
                    subtracting: event.modifierFlags.contains(.option)
                )
            }
            return
        }
        if draggingSplit || draggingPan {
            draggingSplit = false
            draggingPan = false
            window?.invalidateCursorRects(for: self)
            return
        }
        if !stroke.isEmpty {
            let restoring = temporaryRestore && model?.brush.mode == .paint
            model?.commitStroke(points: stroke, temporaryRestore: restoring)
        }
        stroke = []
    }

    override func mouseMoved(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        cursorPoint = nil
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            let factor = exp(event.scrollingDeltaY * 0.012)
            zoom(by: factor, at: point)
        } else {
            originX -= event.scrollingDeltaX / scale
            originY -= event.scrollingDeltaY / scale
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + event.magnification, at: point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        let cursor: NSCursor = (spaceDown || draggingPan) ? .openHand : .crosshair
        addCursorRect(bounds, cursor: cursor)
    }

    private func beginPan(_ point: NSPoint) {
        draggingPan = true
        lastDrag = point
    }

    private func fit() {
        guard pixelWidth > 0, bounds.width > 20, bounds.height > 20 else { return }
        let pad: CGFloat = 36
        let sx = (bounds.width - pad) / CGFloat(pixelWidth)
        let sy = (bounds.height - pad) / CGFloat(pixelHeight)
        scale = max(min(sx, sy), 0.01)
        center()
        didFit = true
        publishZoom()
        needsDisplay = true
    }

    private func actualPixels() {
        let screen = window?.backingScaleFactor ?? 2
        scale = 1 / screen
        center()
        publishZoom()
        needsDisplay = true
    }

    private func center() {
        let imageWidth = CGFloat(pixelWidth) * scale
        let imageHeight = CGFloat(pixelHeight) * scale
        originX = -((bounds.width - imageWidth) / 2) / scale
        originY = -((bounds.height - imageHeight) / 2) / scale
    }

    private func zoom(by factor: CGFloat, at viewPoint: NSPoint) {
        guard factor > 0, scale > 0 else { return }
        let imageX = originX + viewPoint.x / scale
        let imageY = originY + viewPoint.y / scale
        let screen = window?.backingScaleFactor ?? 2
        let minimum = 0.02
        let maximum = 12 / screen
        scale = min(max(scale * factor, minimum), maximum)
        originX = imageX - viewPoint.x / scale
        originY = imageY - viewPoint.y / scale
        publishZoom()
        needsDisplay = true
    }

    private func imageRect() -> NSRect {
        NSRect(
            x: -originX * scale,
            y: -originY * scale,
            width: CGFloat(pixelWidth) * scale,
            height: CGFloat(pixelHeight) * scale
        )
    }

    private var splitX: CGFloat { bounds.width * splitFraction }

    /// This view is flipped, so a plain `NSImage.draw` paints the photo upside down.
    /// `respectFlipped` keeps row 0 of the upright image at the top, which is the
    /// same corner `normalized` and the brush use.
    private func draw(_ image: NSImage, in destination: NSRect, operation: NSCompositingOperation) {
        image.draw(
            in: destination,
            from: .zero,
            operation: operation,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    private func normalized(_ point: NSPoint) -> SIMD2<Float>? {
        UprightPoint.unit(
            viewX: Float(point.x),
            viewY: Float(point.y),
            originX: Float(originX),
            originY: Float(originY),
            scale: Float(scale),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    private func publishZoom() {
        let screen = window?.backingScaleFactor ?? 2
        let percent = Int((scale * screen * 100).rounded())
        guard model?.zoomPercent != percent else { return }
        DispatchQueue.main.async { [weak model] in
            model?.zoomPercent = percent
        }
    }

    private func rebuildCaches() {
        afterCache = afterImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        beforeCache = beforeImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        overlayCache = overlayImage.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}
