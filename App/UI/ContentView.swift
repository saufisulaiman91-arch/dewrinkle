import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: EditorModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarView(model: model)
                    .frame(width: 232)
                Divider().background(Theme.hairline)
                ZStack {
                    Theme.canvas
                    if model.photo == nil {
                        emptyState
                    } else {
                        CanvasView(model: model)
                    }
                    if model.isBusy {
                        busyChip
                    }
                    if let toast = model.maskToast {
                        Text(toast)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.72), in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .padding(.top, 18)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                                    if model.maskToast == toast { model.maskToast = nil }
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().background(Theme.hairline)
                InspectorView(model: model)
                    .frame(width: 312)
            }
            statusBar
        }
        .background(Theme.window)
        .preferredColorScheme(.dark)
        .toolbar { toolbar }
        .onAppear { model.installKeysIfNeeded() }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)
        .alert("Couldn’t finish that", isPresented: errorPresented) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "Save over the original file?",
            isPresented: $model.confirmOverwrite,
            titleVisibility: .visible
        ) {
            Button("Save Over", role: .destructive) { model.confirmSaveOverOriginal() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The pixels of the file you opened will be replaced. Export writes a new file next to it if you’d rather keep the original.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Drop a TIFF or JPEG")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.primary)
            Text("16-bit TIFF from Capture One, or a JPEG a client sent. Both are edited in 32-bit float, so an 8-bit file doesn’t pick up banding while you smooth the cloth.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Open") { model.openPanel() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .controlSize(.large)
        }
        .padding(32)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Theme.accent, lineWidth: 1)
                    .padding(24)
            }
        }
    }

    private var busyChip: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.busyLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.72), in: Capsule())
            .padding(.bottom, 18)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Text(model.status)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("Hold \\ for original")
            Text("\(model.zoomPercent)%")
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.window)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            tool("Open a TIFF, JPEG, or PNG. (⌘O)", systemImage: "folder", title: "Open") { model.openPanel() }
            tool("Save over the file you opened, after a confirm. (⌘S)", systemImage: "square.and.arrow.down", title: "Save") { model.requestSave() }
                .disabled(model.photo == nil)
            tool("Write a new file next to the original. (⌘E)", systemImage: "square.and.arrow.up", title: "Export") { model.exportPanel() }
                .disabled(model.photo == nil)
        }
        ToolbarItemGroup(placement: .principal) {
            tool("Step back through the history list. (⌘Z)", systemImage: "arrow.uturn.backward", title: "Undo") { model.undo() }
                .disabled(!model.canUndo)
            tool("Step forward through the history list. (⇧⌘Z)", systemImage: "arrow.uturn.forward", title: "Redo") { model.redo() }
                .disabled(!model.canRedo)
            tool("Hold the original upright photo. (⌘\\)", systemImage: model.showBeforeLocked ? "eye.fill" : "eye", title: "Before") {
                model.showBeforeLocked.toggle()
            }
            .disabled(model.photo == nil)
            tool("Split the original and the edit. (Y)", systemImage: "rectangle.split.2x1", title: "Split") {
                model.splitEnabled.toggle()
            }
            .disabled(model.photo == nil)
            tool("Show or hide the red mask. (M)", systemImage: model.maskOverlayVisible ? "circle.lefthalf.filled" : "circle", title: "Mask") {
                model.toggleMaskOverlay()
            }
            .disabled(model.photo == nil)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            tool("Rotate the photo and its masks 90° left. (⌘[)", systemImage: "rotate.left", title: "Left") {
                model.rotate(clockwise: false)
            }
            .disabled(model.photo == nil)
            tool("Rotate the photo and its masks 90° right. (⌘])", systemImage: "rotate.right", title: "Right") {
                model.rotate(clockwise: true)
            }
            .disabled(model.photo == nil)
            tool("Paint de-wrinkle onto the cloth. [ and ] change size. Option-drag erases. (B)", systemImage: "paintbrush.pointed", title: "Draw") {
                model.canvasTool = .brush
                model.brush.mode = .paint
            }
            .disabled(model.photo == nil)
            tool("Click the cloth, hijab, skin, or background to fill the mask. Shift adds, Option subtracts.", systemImage: "wand.and.rays", title: "Click") {
                model.canvasTool = .clickSelect
            }
            .disabled(model.photo == nil)
            tool("Fill the mask with the garment so you can refine it. (A)", systemImage: "person.crop.rectangle", title: "Auto") {
                model.detectGarment()
            }
            .disabled(model.photo == nil)
            tool("Fit the photo in the window. (⌘0)", systemImage: "arrow.up.left.and.arrow.down.right", title: "Fit") { model.fit() }
                .disabled(model.photo == nil)
            tool("Show one photo pixel per screen pixel. (⌘1)", systemImage: "1.circle", title: "1:1") { model.actualPixels() }
                .disabled(model.photo == nil)
        }
    }

    private func tool(_ help: String, systemImage: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: systemImage)
                Text(title)
                    .font(.system(size: 9))
            }
        }
        .help(help)
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else if let direct = item as? URL {
                url = direct
            } else {
                url = nil
            }
            guard let url else { return }
            Task { @MainActor in
                model.open(url: url)
            }
        }
        return true
    }
}
