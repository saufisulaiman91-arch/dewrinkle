import AppKit
import SwiftUI

@main
struct DewrinkleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = EditorModel.shared

    var body: some Scene {
        Window("Dewrinkle", id: "main") {
            ContentView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1320, height: 860)
        .commands { DewrinkleCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in
            EditorModel.shared.open(url: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct DewrinkleCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") { EditorModel.shared.openPanel() }
                .keyboardShortcut("o")
            Button("Save") { EditorModel.shared.requestSave() }
                .keyboardShortcut("s")
            Button("Export…") { EditorModel.shared.exportPanel() }
                .keyboardShortcut("e")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { EditorModel.shared.undo() }
                .keyboardShortcut("z")
            Button("Redo") { EditorModel.shared.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Image") {
            Button("Rotate Left") { EditorModel.shared.rotate(clockwise: false) }
                .keyboardShortcut("[", modifiers: .command)
            Button("Rotate Right") { EditorModel.shared.rotate(clockwise: true) }
                .keyboardShortcut("]", modifiers: .command)
            Divider()
            Button("Flip Horizontal") { EditorModel.shared.flip(horizontal: true) }
            Button("Flip Vertical") { EditorModel.shared.flip(horizontal: false) }
        }
        CommandMenu("Canvas") {
            Button("Fit in Window") { EditorModel.shared.fit() }
                .keyboardShortcut("0")
            Button("Actual Pixels") { EditorModel.shared.actualPixels() }
                .keyboardShortcut("1")
            Button("Toggle Original") { EditorModel.shared.showBeforeLocked.toggle() }
                .keyboardShortcut("\\", modifiers: .command)
            Button("Split View") { EditorModel.shared.splitEnabled.toggle() }
                .keyboardShortcut("y")
            Button("Mask Overlay") { EditorModel.shared.toggleMaskOverlay() }
                .keyboardShortcut("m")
            Divider()
            Button("Draw Mask") {
                EditorModel.shared.canvasTool = .brush
                EditorModel.shared.brush.mode = .paint
            }
            .keyboardShortcut("b")
            Button("Erase Mask") {
                EditorModel.shared.canvasTool = .brush
                EditorModel.shared.brush.mode = .restore
            }
            .keyboardShortcut("e")
            Button("Click to Select") { EditorModel.shared.canvasTool = .clickSelect }
            Divider()
            Button("Auto Suggest") { EditorModel.shared.detectGarment() }
                .keyboardShortcut("a")
            Button("Select Subject") { EditorModel.shared.applyQuickMask("Select subject") }
            Button("Select Background") { EditorModel.shared.applyQuickMask("Select background") }
            Button("Select Skin") { EditorModel.shared.applyQuickMask("Select skin") }
            Button("Select Hijab") { EditorModel.shared.applyQuickMask("Select hijab") }
            Button("Select Clothing") { EditorModel.shared.applyQuickMask("Select clothing") }
        }
    }
}
