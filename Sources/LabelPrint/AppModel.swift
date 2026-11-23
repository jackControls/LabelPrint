import AppKit
import Combine
import LabelCore
import SwiftUI
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
    @Published var doc: LabelDocument {
        didSet {
            guard doc != oldValue else { return }
            if isFitting || isRestoring { autosave(); return }
            recordUndo(oldValue)
            var fitted = doc
            fitted.fitText()
            // When text changes size (typing, bold, a new font, shrinking) it stays centred on the spot
            // where it stood, instead of growing from its top-left corner. Text the user just moved is left alone.
            var reanchored = false
            for i in fitted.elements.indices where fitted.elements[i].kind == .text {
                let new = fitted.elements[i]
                guard let old = oldValue.elements.first(where: { $0.id == new.id }),
                      old.x == doc.elements[i].x, old.y == doc.elements[i].y else { continue }
                let was = Renderer.bounds(old), now = Renderer.bounds(new)
                guard was.size != now.size else { continue }
                switch new.alignment {
                case 0: fitted.elements[i].x = was.minX
                case 2: fitted.elements[i].x = was.maxX - now.width
                default: fitted.elements[i].x = was.midX - now.width / 2
                }
                fitted.elements[i].y = was.midY - now.height / 2
                reanchored = true
            }
            if reanchored { fitted.fitText() }
            if fitted != doc {
                isFitting = true
                doc = fitted
                isFitting = false
            } else {
                autosave()
            }
        }
    }
    private var isFitting = false

    // MARK: undo

    private var undoStack: [LabelDocument] = []
    private var redoStack: [LabelDocument] = []
    private var isRestoring = false
    private var lastChange = Date.distantPast

    /// Changes that follow each other within a moment (a drag, a slider, a burst of typing) undo as one step.
    private func recordUndo(_ previous: LabelDocument) {
        let now = Date()
        if undoStack.isEmpty || now.timeIntervalSince(lastChange) > 0.8 {
            undoStack.append(previous)
            if undoStack.count > 200 { undoStack.removeFirst() }
        }
        redoStack.removeAll()
        lastChange = now
    }

    private func restore(_ d: LabelDocument) {
        isRestoring = true
        doc = d
        isRestoring = false
        lastChange = .distantPast
        if let id = selection, !doc.elements.contains(where: { $0.id == id }) { selection = nil }
        if let id = editingID, !doc.elements.contains(where: { $0.id == id }) { editingID = nil }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(doc)
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(doc)
        restore(next)
    }
    @Published var selection: UUID?
    /// Text element currently being typed into on the canvas.
    @Published var editingID: UUID?
    @Published var copies = 1
    @Published var density = 4
    let printer = PrinterLink()

    private static let autosaveKey = "currentLabel"
    private var rollWatch: AnyCancellable?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.autosaveKey),
           let saved = try? JSONDecoder().decode(LabelDocument.self, from: data) {
            doc = saved
        } else {
            doc = .sample
        }
        doc.fitText()
        // The label always takes the size of the roll the printer reports.
        rollWatch = printer.$material.sink { [weak self] m in
            DispatchQueue.main.async { self?.applyRoll(m) }
        }
    }

    /// True when the printer has told us the roll size, so the size is not user-editable.
    var sizeFollowsRoll: Bool { printer.material != nil }

    func applyRoll(_ m: LabelCore.Material?) {
        guard let m else { return }
        if doc.widthMM != m.widthMM { doc.widthMM = m.widthMM }
        if m.lengthMM > 0, doc.lengthMM != m.lengthMM { doc.lengthMM = m.lengthMM }
    }

    func beginEditing(_ id: UUID) {
        selection = id
        editingID = id
    }

    func endEditing() {
        guard let id = editingID else { return }
        editingID = nil
        if let i = doc.elements.firstIndex(where: { $0.id == id }),
           doc.elements[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.elements.remove(at: i)
            if selection == id { selection = nil }
        }
    }

    private func autosave() {
        if let data = try? JSONEncoder().encode(doc) { UserDefaults.standard.set(data, forKey: Self.autosaveKey) }
    }

    // MARK: selection

    var selectedIndex: Int? { doc.elements.firstIndex { $0.id == selection } }
    var selected: LabelElement? { selectedIndex.map { doc.elements[$0] } }

    /// Binding to the selected element that stays safe while it is being deleted.
    func binding(for id: UUID) -> Binding<LabelElement> {
        Binding(
            get: { self.doc.elements.first { $0.id == id } ?? LabelElement(kind: .box) },
            set: { new in if let i = self.doc.elements.firstIndex(where: { $0.id == id }) { self.doc.elements[i] = new } }
        )
    }

    func element(at p: CGPoint) -> LabelElement? {
        doc.elements.last { Renderer.bounds($0).insetBy(dx: -3, dy: -3).contains(p) }
    }

    // MARK: editing

    func add(_ kind: ElementKind) {
        var e = LabelElement(kind: kind)
        switch kind {
        case .text:
            e.text = "Text"; e.fontSize = Double(min(48, doc.widthDots / 2)); e.verticalAlignment = 1
        case .qr:
            e.text = "https://example.com"; e.width = Double(min(doc.widthDots - 8, 88))
        case .barcode:
            e.text = "12345678"; e.lineWidth = 2; e.height = Double(max(24, doc.widthDots - 32))
        case .box:
            e.width = Double(doc.lengthDots - 32); e.height = Double(doc.widthDots - 16); e.cornerRadius = 8
        case .image:
            guard let data = Self.chooseImage() else { return }
            e.imageData = data
            fit(&e, toImage: data)
        }
        center(&e, horizontally: true, vertically: true)
        doc.elements.append(e)
        selection = e.id
        if kind == .text { beginEditing(e.id) }
    }

    private func fit(_ e: inout LabelElement, toImage data: Data) {
        guard let img = NSImage(data: data), img.size.width > 0, img.size.height > 0 else { return }
        let h = Double(doc.widthDots - 8)
        e.height = h
        e.width = (h * img.size.width / img.size.height).rounded()
        if e.width > Double(doc.lengthDots - 16) {
            e.width = Double(doc.lengthDots - 16)
            e.height = (e.width * img.size.height / img.size.width).rounded()
        }
    }

    static func chooseImage() -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return try? Data(contentsOf: url)
    }

    func replaceImage() {
        guard let i = selectedIndex, let data = Self.chooseImage() else { return }
        doc.elements[i].imageData = data
        fit(&doc.elements[i], toImage: data)
    }

    func center(_ e: inout LabelElement, horizontally: Bool, vertically: Bool) {
        let b = Renderer.bounds(e)
        if horizontally { e.x = ((Double(doc.lengthDots) - b.width) / 2).rounded() }
        if vertically { e.y = ((Double(doc.widthDots) - b.height) / 2).rounded() }
    }

    // MARK: defaults

    /// Put one item back to how a new item of its kind starts out, keeping its content, centred on the label.
    private func resetElement(_ i: Int, in d: inout LabelDocument) {
        var e = d.elements[i]
        let fresh = LabelElement(kind: e.kind)
        e.rotation = 0
        switch e.kind {
        case .text:
            e.fontName = fresh.fontName; e.fontSize = Double(min(48, d.widthDots / 2))
            e.bold = false; e.italic = false; e.alignment = 1; e.autoShrink = true; e.verticalAlignment = 1
        case .qr:
            e.width = Double(min(d.widthDots - 8, 88))
        case .barcode:
            e.lineWidth = 2; e.height = Double(max(24, d.widthDots - 32))
        case .box:
            e.width = Double(d.lengthDots - 32); e.height = Double(d.widthDots - 16); e.lineWidth = 2; e.cornerRadius = 8
        case .image:
            e.dither = true; e.invert = false
            if let data = e.imageData { fit(&e, toImage: data) }
        }
        d.elements[i] = e
        d.fitText()                      // settle the shrunk size first, then centre what is left
        e = d.elements[i]
        center(&e, horizontally: true, vertically: true)
        d.elements[i] = e
    }

    func resetSelected() {
        guard let i = selectedIndex else { return }
        var d = doc
        resetElement(i, in: &d)
        doc = d
    }

    /// Every item back to its default style and centred, and the print settings back to 1 copy, darkness 4.
    func resetEverything() {
        endEditing()
        var d = doc
        for i in d.elements.indices { resetElement(i, in: &d) }
        doc = d
        copies = 1
        density = 4
    }

    func centerSelected(horizontally: Bool, vertically: Bool) {
        guard let i = selectedIndex else { return }
        var e = doc.elements[i]
        center(&e, horizontally: horizontally, vertically: vertically)
        if vertically, e.kind == .text { e.verticalAlignment = 1 }
        doc.elements[i] = e
    }

    func deleteSelected() {
        guard let i = selectedIndex else { return }
        doc.elements.remove(at: i)
        selection = nil
        editingID = nil
    }

    func duplicateSelected() {
        guard var e = selected else { return }
        e.id = UUID(); e.x += 12; e.y += 4
        doc.elements.append(e)
        selection = e.id
    }

    func moveSelected(toFront: Bool) {
        guard let i = selectedIndex else { return }
        let e = doc.elements.remove(at: i)
        if toFront { doc.elements.append(e) } else { doc.elements.insert(e, at: 0) }
    }

    func nudge(dx: Double, dy: Double) {
        guard let i = selectedIndex else { return }
        var e = doc.elements[i]
        e.x += dx
        if dy != 0 { e.y += dy; e.verticalAlignment = -1 }   // moving it by hand releases top/middle/bottom
        doc.elements[i] = e
    }

    // MARK: files

    static let fileType = UTType(filenameExtension: "label") ?? .json

    func newDocument() {
        var d = LabelDocument()
        d.widthMM = doc.widthMM; d.lengthMM = doc.lengthMM
        doc = d
        selection = nil
        editingID = nil
    }

    func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.fileType, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            doc = try JSONDecoder().decode(LabelDocument.self, from: Data(contentsOf: url))
            selection = nil
            editingID = nil
            applyRoll(printer.material)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.fileType]
        panel.nameFieldStringValue = "Untitled.label"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try JSONEncoder().encode(doc).write(to: url)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    // MARK: printing

    @MainActor
    func printNow() async {
        endEditing()
        await printer.printLabel(columns: Renderer.columns(doc), copies: copies, density: density)
    }
}
