import AppKit
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import DewrinkleCore

enum ViewportAction: Equatable {
    case none
    case fit
    case actualPixels
}

@MainActor
final class EditorModel: ObservableObject {
    static let shared = EditorModel()

    @Published var photo: LoadedPhoto?
    @Published var parameters = DewrinkleParameters.standard
    @Published var noise = NoiseReductionParameters.off
    @Published var brush = BrushSettings.standard
    @Published var exportSettings = ExportSettings(container: .tiff16)
    @Published var useCustomRadii = false
    @Published var previewAfter: CGImage?
    @Published var maskOverlay: CGImage?
    @Published var showBeforeLocked = false
    @Published var beforeHeld = false
    @Published var splitEnabled = false
    @Published var maskOverlayVisible = true
    @Published var spaceDown = false
    @Published var status = "Open a 16-bit TIFF or a JPEG."
    @Published var isBusy = false
    @Published var busyLabel = ""
    @Published var errorMessage: String?
    @Published var confirmOverwrite = false
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var zoomPercent = 100
    @Published var viewportAction: ViewportAction = .none
    @Published var viewportTicket = 0
    @Published var detailRadius: Double = 8
    @Published var fineRadius: Double = 66
    @Published var coarseRadius: Double = 165

    var showingOriginal: Bool { showBeforeLocked || beforeHeld }

    private var maskDocument = MaskDocument()
    private var inFlight: BrushStroke?
    private var renderTask: Task<Void, Never>?
    private var renderGeneration = 0
    private let pipeline = RenderPipeline()
    private var monitors: [Any] = []
    private var didInstallKeys = false

    private init() {}

    func installKeysIfNeeded() {
        guard !didInstallKeys else { return }
        didInstallKeys = true
        let down = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                EditorModel.shared.handle(event, isDown: true)
            }
        }
        let up = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            MainActor.assumeIsolated {
                EditorModel.shared.handle(event, isDown: false)
            }
        }
        if let down { monitors.append(down) }
        if let up { monitors.append(up) }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.tiff, .jpeg, .png]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "TIFF, JPEG, or PNG. 16-bit TIFF and 8-bit JPEG are both edited in 32-bit float."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url: url)
    }

    func open(url: URL) {
        isBusy = true
        busyLabel = "Reading \(url.lastPathComponent)…"
        errorMessage = nil
        do {
            let loaded = try ImageFile.load(url: url)
            photo = loaded
            parameters = .standard
            noise = .off
            useCustomRadii = false
            exportSettings = .matching(source: loaded.source)
            maskDocument = MaskDocument()
            inFlight = nil
            previewAfter = loaded.preview
            maskOverlay = nil
            showBeforeLocked = false
            splitEnabled = false
            syncHistory()
            syncRadiusFields()
            status = loaded.statusLine + "  ·  preview \(loaded.preview.width) px"
            isBusy = false
            fit()
            schedulePreview()
        } catch {
            isBusy = false
            errorMessage = error.localizedDescription
        }
    }

    func exportPanel() {
        guard let photo else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = ImageFile.suggestedName(for: photo, settings: exportSettings)
        panel.allowedContentTypes = [contentType(exportSettings.container)]
        switch exportSettings.container {
        case .jpeg:
            panel.message = "JPEG at \(Int((exportSettings.jpegQuality * 100).rounded())). The ICC profile and EXIF from the original are written back."
        case .tiff16:
            panel.message = "16-bit TIFF, LZW. ICC profile and EXIF are written back. This is the Capture One round trip."
        case .png16:
            panel.message = "16-bit PNG with the original ICC profile."
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    func requestSave() {
        guard photo != nil else { return }
        if let photo, ImageFile.sameContainer(photo, exportSettings) {
            confirmOverwrite = true
        } else if let photo {
            write(to: ImageFile.siblingURL(for: photo, settings: exportSettings))
        }
    }

    func confirmSaveOverOriginal() {
        guard let photo else { return }
        write(to: photo.url)
    }

    func fit() {
        viewportAction = .fit
        viewportTicket += 1
    }

    func actualPixels() {
        viewportAction = .actualPixels
        viewportTicket += 1
    }

    func schedulePreview() {
        guard let photo else { return }
        renderGeneration += 1
        let generation = renderGeneration
        let mask = maskDocument.rasterize(
            width: photo.preview.width,
            height: photo.preview.height,
            extra: inFlight
        )
        let edits = EditParameters(dewrinkle: parameters, noise: noise)
        let source = photo.previewCI
        let fullShort = photo.fullShortSide
        let pixelScale = photo.previewPixelScale
        let showOverlay = maskOverlayVisible
        renderTask?.cancel()
        renderTask = Task { [pipeline] in
            try? await Task.sleep(nanoseconds: 28_000_000)
            guard !Task.isCancelled else { return }
            let rendered: CGImage? = await Self.offMain {
                try? pipeline.renderPreview(
                    source: source,
                    mask: mask,
                    edits: edits,
                    fullShortSide: fullShort,
                    pixelScale: pixelScale
                )
            }
            let overlay = showOverlay ? CGBridge.overlayImage(mask) : nil
            guard generation == self.renderGeneration else { return }
            if let rendered {
                self.previewAfter = rendered
            }
            self.maskOverlay = overlay
        }
    }

    func detectGarment() {
        guard let photo else { return }
        isBusy = true
        busyLabel = "Finding the garment…"
        let rgb = photo.previewRGB
        let preview = photo.preview
        Task {
            do {
                let segmenter = VisionForegroundSegmenter()
                let person = try await segmenter.foregroundMask(for: rgb)
                let faces = (try? VisionForegroundSegmenter.faces(in: preview)) ?? []
                let refined = GarmentMaskRefinement.refine(person: person, image: rgb, faces: faces)
                if refined.mean() < 0.004 {
                    self.status = "No subject found. Paint the cloth, or try a shot where the garment is the foreground."
                } else {
                    self.maskDocument.setBase(refined)
                    self.maskOverlayVisible = true
                    let coverage = Int((refined.mean() * 100).rounded())
                    self.status = "Garment mask covers about \(coverage)% of the preview. Paint to add, option-drag to restore."
                }
                self.syncHistory()
                self.isBusy = false
                self.schedulePreview()
            } catch {
                self.isBusy = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func clearMask() {
        maskDocument.clear()
        syncHistory()
        schedulePreview()
        status = "Mask cleared."
    }

    func undo() {
        guard maskDocument.canUndo else { return }
        maskDocument.undo()
        syncHistory()
        schedulePreview()
    }

    func redo() {
        guard maskDocument.canRedo else { return }
        maskDocument.redo()
        syncHistory()
        schedulePreview()
    }

    func resetEffect() {
        let overrides = (parameters.detailRadiusOverride, parameters.fineRadiusOverride, parameters.coarseRadiusOverride)
        parameters = .standard
        if useCustomRadii {
            parameters.detailRadiusOverride = overrides.0
            parameters.fineRadiusOverride = overrides.1
            parameters.coarseRadiusOverride = overrides.2
        }
        schedulePreview()
    }

    func resetNoise() {
        let limit = noise.limitToMask
        noise = .off
        noise.limitToMask = limit
        schedulePreview()
    }

    func setCustomRadii(_ enabled: Bool) {
        useCustomRadii = enabled
        if enabled {
            syncRadiusFields()
            parameters.detailRadiusOverride = Float(detailRadius)
            parameters.fineRadiusOverride = Float(fineRadius)
            parameters.coarseRadiusOverride = Float(coarseRadius)
        } else {
            parameters.detailRadiusOverride = nil
            parameters.fineRadiusOverride = nil
            parameters.coarseRadiusOverride = nil
            syncRadiusFields()
        }
        schedulePreview()
    }

    func applyRadiusFields() {
        guard useCustomRadii else { return }
        parameters.detailRadiusOverride = Float(detailRadius)
        parameters.fineRadiusOverride = Float(max(fineRadius, detailRadius + 1))
        parameters.coarseRadiusOverride = Float(max(coarseRadius, fineRadius + 1))
        schedulePreview()
    }

    func previewStroke(points: [SIMD2<Float>], temporaryRestore: Bool) {
        guard let photo, !points.isEmpty else { return }
        inFlight = makeStroke(points: points, temporaryRestore: temporaryRestore, referenceWidth: photo.orientedWidth)
        schedulePreview()
    }

    func commitStroke(points: [SIMD2<Float>], temporaryRestore: Bool) {
        guard let photo, !points.isEmpty else {
            inFlight = nil
            return
        }
        maskDocument.add(makeStroke(points: points, temporaryRestore: temporaryRestore, referenceWidth: photo.orientedWidth))
        inFlight = nil
        syncHistory()
        schedulePreview()
    }

    func radiusCaption() -> String {
        guard let photo else { return "Radii scale with the frame. On a Z8 file, coarse stops near 165 px." }
        let sigmas = parameters.resolvedSigmas(fullShortSide: photo.fullShortSide, pixelScale: 1)
        return String(format: "Detail %.0f px · fine %.0f px · coarse %.0f px, full resolution", sigmas.detail, sigmas.fine, sigmas.coarse)
    }

    private func write(to url: URL) {
        guard let photo else { return }
        isBusy = true
        busyLabel = "Rendering \(photo.orientedWidth) × \(photo.orientedHeight)…"
        let settings = exportSettings
        let edits = EditParameters(dewrinkle: parameters, noise: noise)
        let document = maskDocument
        let sourceURL = photo.url
        let fullShort = photo.fullShortSide
        let colorSpace = photo.colorSpace
        let properties = photo.properties
        let pipeline = pipeline
        Task {
            do {
                let rendered: (pixels: [Float], width: Int, height: Int) = try await Self.offMain {
                    guard let full = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]) else {
                        throw ImageFileError.unreadable
                    }
                    let extent = full.extent.integral
                    let width = max(Int(extent.width), 1)
                    let height = max(Int(extent.height), 1)
                    let mask = document.rasterize(width: width, height: height)
                    let pixels = try pipeline.renderExport(
                        source: full,
                        mask: mask,
                        edits: edits,
                        fullShortSide: fullShort,
                        width: width,
                        height: height
                    )
                    return (pixels, width, height)
                }
                try ImageFile.write(
                    rgba: rendered.pixels,
                    width: rendered.width,
                    height: rendered.height,
                    to: url,
                    settings: settings,
                    colorSpace: colorSpace,
                    properties: properties
                )
                self.isBusy = false
                self.status = "Saved \(url.lastPathComponent)"
            } catch {
                self.isBusy = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func makeStroke(points: [SIMD2<Float>], temporaryRestore: Bool, referenceWidth: Int) -> BrushStroke {
        var settings = brush
        if temporaryRestore { settings.mode = .restore }
        return BrushStroke(settings: settings, referenceWidth: referenceWidth, points: points)
    }

    private func syncHistory() {
        canUndo = maskDocument.canUndo
        canRedo = maskDocument.canRedo
    }

    private func syncRadiusFields() {
        guard let photo else { return }
        let sigmas = FrequencyScales.standard.fullResolutionSigmas(shortSide: photo.fullShortSide)
        detailRadius = Double(parameters.detailRadiusOverride ?? sigmas.detail)
        fineRadius = Double(parameters.fineRadiusOverride ?? sigmas.fine)
        coarseRadius = Double(parameters.coarseRadiusOverride ?? sigmas.coarse)
    }

    private func contentType(_ container: ExportContainer) -> UTType {
        switch container {
        case .jpeg: return .jpeg
        case .tiff16: return .tiff
        case .png16: return .png
        }
    }

    private func handle(_ event: NSEvent, isDown: Bool) -> NSEvent? {
        if textIsEditing { return event }
        let characters = event.charactersIgnoringModifiers ?? ""
        if event.keyCode == 49 {
            spaceDown = isDown
            return nil
        }
        if characters == "\\" {
            if isDown, !event.isARepeat { beforeHeld = true }
            if !isDown { beforeHeld = false }
            return nil
        }
        guard isDown, !event.isARepeat else { return event }
        switch characters.lowercased() {
        case "b":
            brush.mode = .paint
            return nil
        case "e":
            brush.mode = .restore
            return nil
        case "[":
            brush.radius = max(4, brush.radius / 1.12)
            return nil
        case "]":
            brush.radius = min(4000, brush.radius * 1.12)
            return nil
        case "a":
            detectGarment()
            return nil
        case "m":
            maskOverlayVisible.toggle()
            schedulePreview()
            return nil
        case "y":
            splitEnabled.toggle()
            return nil
        default:
            return event
        }
    }

    private var textIsEditing: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    private static func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
