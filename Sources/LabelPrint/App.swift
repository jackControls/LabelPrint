import LabelCore
import SwiftUI

struct LabelPrintApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("showInspector") private var showInspector = true
    @AppStorage("exactDots") private var exactDots = false

    var body: some Scene {
        Window("Label Print", id: "main") {
            ContentView(model: model)
        }
        .defaultSize(width: 880, height: 420)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }.keyboardShortcut("z")
                Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .newItem) {
                Button("New Label") { model.newDocument() }.keyboardShortcut("n")
                Button("Open…") { model.open() }.keyboardShortcut("o")
                Button("Save As…") { model.save() }.keyboardShortcut("s")
            }
            CommandMenu("Label") {
                Button("Add Text") { model.add(.text) }.keyboardShortcut("t")
                Button("Add QR Code") { model.add(.qr) }
                Button("Add Barcode") { model.add(.barcode) }
                Button("Add Image…") { model.add(.image) }
                Button("Add Box") { model.add(.box) }
                Divider()
                Button("Duplicate") { model.duplicateSelected() }.keyboardShortcut("d")
                Divider()
                Toggle("Show Exact Printer Dots", isOn: $exactDots)
                Button(showInspector ? "Hide Inspector" : "Show Inspector") { showInspector.toggle() }
                    .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}
