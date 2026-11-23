import AppKit
import Combine
import LabelCore
import SwiftUI
import UniformTypeIdentifiers

final class AppModel: ObservableObject {
    @Published var doc: LabelDocument { didSet { if doc != oldValue { autosave() } } }
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
            e.text = "Text"; e.fontSize = Double(min(48, doc.widthDots / 2))
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
        if kind == .text { editingID = e.id }
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

    func centerSelected(horizontally: Bool, vertically: Bool) {
        guard let i = selectedIndex else { return }
        center(&doc.elements[i], horizontally: horizontally, vertically: vertically)
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
        doc.elements[i].x += dx; doc.elements[i].y += dy
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
