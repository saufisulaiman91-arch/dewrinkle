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
    @Published var parameters = DewrinkleParameters.detected {
        didSet { mirrorParameters() }
    }
    @Published var noise = NoiseReductionParameters.off {
        didSet { mirrorNoise() }
    }
    @Published var layers: [EditLayer] = []
    @Published var selectedLayerID: UUID?
    @Published var canvasTool: CanvasTool = .brush
    @Published var selectTolerance: Double = 12
    @Published var detectionSensitivity: Double = 58
    @Published var includeHijab = false
    @Published var maskToast: String?
    @Published var historyRows: [HistoryRow] = []
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
    @Published var displayPixelWidth = 0
    @Published var displayPixelHeight = 0
    @Published var orientedOriginal: CGImage?
    @Published var detailRadius: Double = 8
    @Published var fineRadius: Double = 66
    @Published var coarseRadius: Double = 165

    var showingOriginal: Bool { showBeforeLocked || beforeHeld }
    var selectedLayerIsBackground: Bool { selectedLayer?.isBackground == true }

    struct HistoryRow: Identifiable, Equatable {
        let id: UUID
        let index: Int
        let name: String
        let isCurrent: Bool
        let isFuture: Bool
    }

    private var turns: [PictureTurn] = []
    private var history = HistoryStack<EditSnapshot>()
    private var suppressLayerSync = false
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
            useCustomRadii = false
            exportSettings = .matching(source: loaded.source)
            turns = []
            canvasTool = .brush
            let paint = EditLayer.dewrinkle(index: 1)
            let base = EditLayer.background()
            suppressLayerSync = true
            layers = [paint, base]
            selectedLayerID = paint.id
            parameters = paint.dewrinkle
            noise = paint.noise
            suppressLayerSync = false
            inFlight = nil
            previewAfter = loaded.preview
            maskOverlay = nil
            showBeforeLocked = false
            splitEnabled = false
            history.reset(name: "Original", state: snapshot())
            publishHistory()
            refreshDisplaySize()
            syncRadiusFields()
            status = loaded.statusLine + "  ·  finding creases"
            isBusy = false
            fit()
            schedulePreview()
            detectWrinkles()
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
        let source = ImageGeometry.apply(turns, to: photo.previewCI)
        let fullShort = min(displayWidth, displayHeight)
        let previewSize = orientedPreviewSize(photo)
        let pixelScale = Float(min(previewSize.width, previewSize.height)) / Float(max(fullShort, 1))
        let passes = renderPasses(extra: inFlight)
        let overlayMask = selectedMask(extra: inFlight)
        let showOverlay = maskOverlayVisible
        renderTask?.cancel()
        renderTask = Task { [pipeline] in
            try? await Task.sleep(nanoseconds: 28_000_000)
            guard !Task.isCancelled else { return }
            let renderedPair: (CGImage, CGImage)? = try? await Self.offMain {
                let base = try pipeline.renderStackedPreview(
                    source: source,
                    passes: [],
                    fullShortSide: fullShort,
                    pixelScale: pixelScale
                )
                let edited = try pipeline.renderStackedPreview(
                    source: source,
                    passes: passes,
                    fullShortSide: fullShort,
                    pixelScale: pixelScale
                )
                return (base, edited)
            }
            let overlay = showOverlay ? overlayMask.flatMap { CGBridge.overlayImage($0) } : nil
            guard generation == self.renderGeneration else { return }
            if let renderedPair {
                self.orientedOriginal = renderedPair.0
                self.previewAfter = renderedPair.1
                self.displayPixelWidth = renderedPair.1.width
                self.displayPixelHeight = renderedPair.1.height
            }
            self.maskOverlay = overlay
        }
    }

    func detectWrinkles() {
        guard photo != nil else { return }
        guard let targetID = layers.first(where: { !$0.isBackground })?.id ?? selectedLayerID else { return }
        isBusy = true
        busyLabel = "Finding creases…"
        let rgb = orientedRGB()
        let sensitivity = Float(detectionSensitivity / 100)
        let withHijab = includeHijab
        let tolerance = Float(selectTolerance / 100)
        Task {
            let clothing: MaskBuffer
            var note: String?
            do {
                let built = try await VisionForegroundSegmenter().regions(for: rgb, tolerance: tolerance)
                if withHijab {
                    clothing = Self.unionMasks(built.clothing, built.hijab)
                } else if built.clothing.mean() > 0.01 {
                    clothing = built.clothing
                } else {
                    let person = Self.subtractMask(built.skin, from: built.subject)
                    clothing = person.mean() > 0.01 ? person : MaskBuffer(width: rgb.width, height: rgb.height, fill: 1)
                }
            } catch {
                clothing = MaskBuffer(width: rgb.width, height: rgb.height, fill: 1)
                note = "Person detection missed, so creases were found on the whole frame."
            }
            let settings = WrinkleDetector.Settings(sensitivity: sensitivity)
            let detected = (try? await Self.offMain {
                WrinkleDetector.mask(image: rgb, clothing: clothing, settings: settings)
            }) ?? WrinkleDetector.mask(image: rgb, clothing: clothing, settings: settings)
            self.finishDetection(detected, on: targetID, note: note)
        }
    }

    private func finishDetection(_ mask: MaskBuffer, on id: UUID, note: String?) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else {
            isBusy = false
            return
        }
        var document = MaskDocument()
        document.setBase(mask)
        layers[index].mask = document
        layers[index].dewrinkle = .detected
        layers[index].dewrinkleOn = true
        selectedLayerID = id
        suppressLayerSync = true
        parameters = .detected
        suppressLayerSync = false
        maskOverlayVisible = true
        maskToast = "Creases"
        commitHistory("Detect creases")
        isBusy = false
        let coverage = Int((mask.mean() * 100).rounded())
        if coverage < 1 {
            status = "No creases marked. Raise Detection sensitivity, or paint the ones you want."
        } else if let note {
            status = note
        } else {
            status = "Creases cover about \(coverage)% of the preview. Paint to add, Option-drag to leave cloth alone."
        }
        schedulePreview()
    }

    func clearMask() {
        storeSelectedMask(MaskDocument())
        commitHistory("Clear mask")
        schedulePreview()
        status = "Mask cleared."
    }

    func undo() {
        guard let state = history.undo() else { return }
        restore(state)
    }

    func redo() {
        guard let state = history.redo() else { return }
        restore(state)
    }

    func jumpHistory(to index: Int) {
        guard let state = history.jump(to: index) else { return }
        restore(state)
    }

    func usePreset(_ preset: DewrinkleParameters) {
        parameters = preset
        commitHistory(preset.preserveFolds > 0.5 ? "Natural de-wrinkle" : "Strong de-wrinkle")
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
        inFlight = makeStroke(points: points, temporaryRestore: temporaryRestore, referenceWidth: displayWidth)
        schedulePreview()
    }

    func commitStroke(points: [SIMD2<Float>], temporaryRestore: Bool) {
        guard photo != nil, !points.isEmpty else {
            inFlight = nil
            return
        }
        let stroke = makeStroke(points: points, temporaryRestore: temporaryRestore, referenceWidth: displayWidth)
        var mask = selectedMaskDocument()
        mask.add(stroke)
        storeSelectedMask(mask)
        inFlight = nil
        let name = stroke.mode == .restore ? "Erase mask" : "De-wrinkle brush"
        commitHistory(name)
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
        let size = orientedSize(width: photo.orientedWidth, height: photo.orientedHeight)
        busyLabel = "Rendering \(size.width) × \(size.height)…"
        let settings = exportSettings
        let sourceURL = photo.url
        let colorSpace = photo.colorSpace
        let properties = photo.properties
        let pipeline = pipeline
        let turns = turns
        let layerSnapshot = layers
        let fullShort = min(size.width, size.height)
        Task {
            do {
                let rendered: (pixels: [Float], width: Int, height: Int) = try await Self.offMain {
                    guard let full = CIImage(contentsOf: sourceURL, options: [.applyOrientationProperty: true]) else {
                        throw ImageFileError.unreadable
                    }
                    let oriented = ImageGeometry.apply(turns, to: full)
                    let extent = oriented.extent.integral
                    let width = max(Int(extent.width), 1)
                    let height = max(Int(extent.height), 1)
                    let passes = Self.passes(from: layerSnapshot, width: width, height: height, extra: nil, selectedID: nil)
                    let pixels = try pipeline.renderStackedExport(
                        source: oriented,
                        passes: passes,
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
        publishHistory()
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
        if event.modifierFlags.contains(.command), characters == "[" || characters == "]" {
            return event
        }
        switch characters.lowercased() {
        case "b":
            canvasTool = .brush
            brush.mode = .paint
            return nil
        case "e":
            canvasTool = .brush
            brush.mode = .restore
            return nil
        case "[":
            brush.radius = max(4, brush.radius / 1.12)
            return nil
        case "]":
            brush.radius = min(4000, brush.radius * 1.12)
            return nil
        case "a":
            detectWrinkles()
            return nil
        case "m":
            toggleMaskOverlay()
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

    func rotate(clockwise: Bool) {
        let turn: PictureTurn = clockwise ? .clockwise : .counterClockwise
        apply(turn)
        publishTurnedFrame(turn)
        commitHistory(clockwise ? "Rotate right" : "Rotate left")
        fit()
        schedulePreview()
    }

    func flip(horizontal: Bool) {
        let turn: PictureTurn = horizontal ? .flipHorizontal : .flipVertical
        apply(turn)
        publishTurnedFrame(turn)
        commitHistory(horizontal ? "Flip horizontal" : "Flip vertical")
        fit()
        schedulePreview()
    }

    func addLayer() {
        let index = layers.filter { !$0.isBackground }.count + 1
        let layer = EditLayer.dewrinkle(index: index)
        layers.insert(layer, at: 0)
        selectLayer(layer.id)
        commitHistory("Add layer")
        schedulePreview()
    }

    func deleteSelectedLayer() {
        guard let layer = selectedLayer, !layer.isBackground, let index = selectedIndex else { return }
        let name = layer.name
        layers.remove(at: index)
        selectedLayerID = layers.first?.id
        pullSelectedAdjustments()
        commitHistory("Delete \(name)")
        schedulePreview()
    }

    func selectLayer(_ id: UUID) {
        selectedLayerID = id
        pullSelectedAdjustments()
        schedulePreview()
    }

    func setLayerName(_ id: UUID, to name: String) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].name = name
    }

    func setLayerVisible(_ id: UUID, _ visible: Bool) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].visible = visible
        commitHistory(visible ? "Show \(layers[index].name)" : "Hide \(layers[index].name)")
        schedulePreview()
    }

    func setLayerOpacity(_ id: UUID, _ opacity: Float) {
        guard let index = layers.firstIndex(where: { $0.id == id }) else { return }
        layers[index].opacity = min(max(opacity, 0), 1)
        schedulePreview()
    }

    func moveSelectedLayer(up: Bool) {
        guard let index = selectedIndex else { return }
        let destination = up ? index - 1 : index + 1
        guard layers.indices.contains(destination) else { return }
        if layers[index].isBackground || layers[destination].isBackground { return }
        layers.swapAt(index, destination)
        commitHistory("Reorder layers")
        schedulePreview()
    }

    func commitHistory(_ name: String) {
        history.commit(name: name, state: snapshot())
        publishHistory()
    }

    func clickSelect(at point: SIMD2<Float>, adding: Bool, subtracting: Bool) {
        guard let photo else { return }
        let rgb = orientedRGB()
        let tolerance = Float(selectTolerance / 100)
        isBusy = true
        busyLabel = "Selecting…"
        Task {
            do {
                let segmenter = VisionForegroundSegmenter()
                let (region, name) = try await segmenter.region(for: rgb, at: point, tolerance: tolerance)
                self.combineSelectedMask(region, adding: adding, subtracting: subtracting)
                self.maskOverlayVisible = true
                self.maskToast = subtracting ? "Subtract \(name)" : name
                self.commitHistory(subtracting ? "Mask subtract" : (adding ? "Mask add" : name))
                self.status = name
                self.isBusy = false
                self.schedulePreview()
            } catch {
                self.isBusy = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func applyQuickMask(_ kind: String) {
        guard let photo else { return }
        let rgb = orientedRGB()
        isBusy = true
        busyLabel = kind
        Task {
            do {
                let built = try await VisionForegroundSegmenter().regions(
                    for: rgb,
                    tolerance: Float(self.selectTolerance / 100)
                )
                let mask: MaskBuffer
                switch kind {
                case "Select background": mask = built.background
                case "Select skin": mask = built.skin
                case "Select hijab": mask = built.hijab
                case "Select clothing": mask = built.clothing
                default: mask = built.subject
                }
                self.replaceSelectedMask(mask)
                self.maskOverlayVisible = true
                self.maskToast = kind
                self.commitHistory(kind)
                self.isBusy = false
                self.schedulePreview()
            } catch {
                self.isBusy = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func invertSelectedMask() {
        guard let current = selectedMask(extra: nil) else { return }
        var inverted = current
        for index in inverted.values.indices {
            inverted.values[index] = 1 - inverted.values[index]
        }
        replaceSelectedMask(inverted)
        commitHistory("Invert mask")
        schedulePreview()
    }

    func featherSelectedMask() {
        guard var current = selectedMask(extra: nil) else { return }
        let sigma = Float(max(selectTolerance, 1)) * 0.15
        current = GaussianBlur.mask(current, sigma: sigma)
        replaceSelectedMask(current)
        commitHistory("Feather mask")
        schedulePreview()
    }

    func toggleMaskOverlay() {
        maskOverlayVisible.toggle()
        maskToast = maskOverlayVisible ? "Always Display Mask" : "Never Display Mask"
        schedulePreview()
    }

    /// Turns the picture on screen immediately, using the same mapping as the masks.
    /// The Core Image preview replaces it once the edit has been re-rendered.
    private func publishTurnedFrame(_ turn: PictureTurn) {
        if let current = previewAfter {
            previewAfter = CGBridge.cgImage(from: CGBridge.rgbImage(from: current).applying(turn))
        }
        orientedOriginal = CGBridge.cgImage(from: orientedRGB())
        maskOverlay = nil
        refreshDisplaySize()
    }

    private func apply(_ turn: PictureTurn) {
        guard let photo else { return }
        let size = orientedSize(width: photo.orientedWidth, height: photo.orientedHeight)
        for index in layers.indices {
            layers[index].mask = layers[index].mask.applying(turn, referenceWidth: size.width, referenceHeight: size.height)
        }
        turns.append(turn)
    }

    private func orientedSize(width: Int, height: Int) -> (width: Int, height: Int) {
        var w = width
        var h = height
        for turn in turns where turn.swapsAxes {
            swap(&w, &h)
        }
        return (w, h)
    }

    var displayReferenceWidth: Int {
        max(displayWidth, 1)
    }

    private var displayWidth: Int {
        guard let photo else { return 1 }
        return orientedSize(width: photo.orientedWidth, height: photo.orientedHeight).width
    }

    private var displayHeight: Int {
        guard let photo else { return 1 }
        return orientedSize(width: photo.orientedWidth, height: photo.orientedHeight).height
    }

    private func orientedRGB() -> RGBImage {
        guard let photo else { return RGBImage(width: 1, height: 1, fill: 0) }
        var image = photo.previewRGB
        for turn in turns {
            image = image.applying(turn)
        }
        return image
    }

    private var selectedIndex: Int? {
        guard let selectedLayerID else { return layers.indices.first }
        return layers.firstIndex { $0.id == selectedLayerID }
    }

    var selectedLayer: EditLayer? {
        guard let selectedIndex else { return nil }
        return layers[selectedIndex]
    }

    private func selectedMaskDocument() -> MaskDocument {
        selectedLayer?.mask ?? MaskDocument()
    }

    private func storeSelectedMask(_ mask: MaskDocument) {
        guard let selectedIndex else { return }
        layers[selectedIndex].mask = mask
        if layers[selectedIndex].isBackground == false {
            layers[selectedIndex].dewrinkleOn = true
        }
    }

    private func replaceSelectedMask(_ mask: MaskBuffer) {
        var document = MaskDocument()
        document.setBase(mask)
        storeSelectedMask(document)
    }

    private func combineSelectedMask(_ mask: MaskBuffer, adding: Bool, subtracting: Bool) {
        let current = selectedMask(extra: nil) ?? MaskBuffer(width: mask.width, height: mask.height, fill: 0)
        let aligned = mask.resized(toWidth: current.width, height: current.height)
        var combined = current
        for index in combined.values.indices {
            if subtracting {
                combined.values[index] *= 1 - aligned.values[index]
            } else if adding {
                combined.values[index] = max(combined.values[index], aligned.values[index])
            } else {
                combined.values[index] = aligned.values[index]
            }
        }
        replaceSelectedMask(combined)
    }

    private func selectedMask(extra: BrushStroke?) -> MaskBuffer? {
        guard let photo else { return nil }
        let size = orientedPreviewSize(photo)
        return selectedMaskDocument().rasterize(width: size.width, height: size.height, extra: extra)
    }

    private func refreshDisplaySize() {
        guard let photo else {
            displayPixelWidth = 0
            displayPixelHeight = 0
            return
        }
        let size = orientedPreviewSize(photo)
        displayPixelWidth = size.width
        displayPixelHeight = size.height
    }

    private func orientedPreviewSize(_ photo: LoadedPhoto) -> (width: Int, height: Int) {
        orientedSize(width: photo.preview.width, height: photo.preview.height)
    }

    private func renderPasses(extra: BrushStroke?) -> [RenderPass] {
        guard let photo else { return [] }
        let size = orientedPreviewSize(photo)
        return Self.passes(from: layers, width: size.width, height: size.height, extra: extra, selectedID: selectedLayerID)
    }

    private static func subtractMask(_ cut: MaskBuffer, from mask: MaskBuffer) -> MaskBuffer {
        let other = cut.resized(toWidth: mask.width, height: mask.height)
        var output = mask
        for index in output.values.indices {
            output.values[index] *= 1 - other.values[index]
        }
        return output
    }

    private static func unionMasks(_ first: MaskBuffer, _ second: MaskBuffer) -> MaskBuffer {
        let other = second.resized(toWidth: first.width, height: first.height)
        var output = first
        for index in output.values.indices {
            output.values[index] = max(output.values[index], other.values[index])
        }
        return output
    }

    private static func passes(
        from layers: [EditLayer],
        width: Int,
        height: Int,
        extra: BrushStroke?,
        selectedID: UUID?
    ) -> [RenderPass] {
        var passes: [RenderPass] = []
        for layer in layers.reversed() where layer.visible && layer.opacity > 0.001 {
            let extraStroke = layer.id == selectedID ? extra : nil
            let mask = layer.mask.rasterize(width: width, height: height, extra: extraStroke)
            var dewrinkle = layer.dewrinkle
            if !layer.dewrinkleOn { dewrinkle.strength = 0 }
            var noise = layer.noise
            noise.limitToMask = true
            passes.append(RenderPass(
                mask: mask,
                edits: EditParameters(dewrinkle: dewrinkle, noise: noise),
                opacity: layer.opacity
            ))
        }
        return passes
    }

    private func snapshot() -> EditSnapshot {
        EditSnapshot(
            turns: turns,
            layers: layers,
            selectedLayerID: selectedLayerID ?? layers.first?.id ?? UUID(),
            brush: brush,
            detectionSensitivity: Float(detectionSensitivity / 100),
            includeHijab: includeHijab
        )
    }

    private func restore(_ state: EditSnapshot) {
        let turnsChanged = state.turns != turns
        suppressLayerSync = true
        turns = state.turns
        layers = state.layers
        selectedLayerID = state.selectedLayerID
        brush = state.brush
        detectionSensitivity = Double(state.detectionSensitivity * 100)
        includeHijab = state.includeHijab
        if let layer = selectedLayer {
            parameters = layer.dewrinkle
            noise = layer.noise
        }
        suppressLayerSync = false
        inFlight = nil
        if turnsChanged {
            let frame = CGBridge.cgImage(from: orientedRGB())
            orientedOriginal = frame
            previewAfter = frame
            maskOverlay = nil
            refreshDisplaySize()
            fit()
        }
        publishHistory()
        schedulePreview()
    }

    private func publishHistory() {
        canUndo = history.canUndo
        canRedo = history.canRedo
        historyRows = history.entries.enumerated().map { offset, entry in
            HistoryRow(
                id: entry.id,
                index: offset,
                name: entry.name,
                isCurrent: offset == history.index,
                isFuture: offset > history.index
            )
        }
    }

    private func mirrorParameters() {
        guard !suppressLayerSync, let selectedIndex else { return }
        layers[selectedIndex].dewrinkle = parameters
        layers[selectedIndex].dewrinkleOn = true
    }

    private func mirrorNoise() {
        guard !suppressLayerSync, let selectedIndex else { return }
        layers[selectedIndex].noise = noise
    }

    private func pullSelectedAdjustments() {
        guard let layer = selectedLayer else { return }
        suppressLayerSync = true
        parameters = layer.dewrinkle
        noise = layer.noise
        suppressLayerSync = false
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
