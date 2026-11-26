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
            Button("Undo Mask") { EditorModel.shared.undo() }
                .keyboardShortcut("z")
            Button("Redo Mask") { EditorModel.shared.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
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
            Button("Mask Overlay") {
                EditorModel.shared.maskOverlayVisible.toggle()
                EditorModel.shared.schedulePreview()
            }
            .keyboardShortcut("m")
            Divider()
            Button("Detect Garment") { EditorModel.shared.detectGarment() }
                .keyboardShortcut("a")
        }
    }
}
