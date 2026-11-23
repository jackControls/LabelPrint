import LabelCore
import SwiftUI

struct LabelPrintApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Label Print", id: "main") {
            ContentView(model: model)
        }
        .commands {
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
            }
        }
    }
}
