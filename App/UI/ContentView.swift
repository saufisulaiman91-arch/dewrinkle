import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: EditorModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
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
            Button { model.openPanel() } label: { Label("Open", systemImage: "folder") }
            Button { model.requestSave() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .disabled(model.photo == nil)
            Button { model.exportPanel() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(model.photo == nil)
        }
        ToolbarItemGroup(placement: .principal) {
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
            Button { model.showBeforeLocked.toggle() } label: {
                Label("Before", systemImage: model.showBeforeLocked ? "eye.fill" : "eye")
            }
            .disabled(model.photo == nil)
            Button { model.splitEnabled.toggle() } label: {
                Label("Split", systemImage: "rectangle.split.2x1")
            }
            .disabled(model.photo == nil)
            Button {
                model.maskOverlayVisible.toggle()
                model.schedulePreview()
            } label: {
                Label("Mask", systemImage: model.maskOverlayVisible ? "circle.lefthalf.filled" : "circle")
            }
            .disabled(model.photo == nil)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.detectGarment() } label: { Label("Auto", systemImage: "person.crop.rectangle") }
                .disabled(model.photo == nil)
            Button { model.fit() } label: { Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right") }
                .disabled(model.photo == nil)
            Button { model.actualPixels() } label: { Label("1:1", systemImage: "1.circle") }
                .disabled(model.photo == nil)
        }
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
