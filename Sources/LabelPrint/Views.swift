import AppKit
import LabelCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        HStack(spacing: 0) {
            PrinterPanel(model: model, printer: model.printer)
                .frame(width: 220)
            Divider()
            VStack(spacing: 0) {
                AddBar(model: model)
                Divider()
                CanvasView(model: model)
            }
            .frame(minWidth: 430)
            if showInspector {
                Divider()
                InspectorPanel(model: model, printer: model.printer)
                    .frame(width: 220)
            }
        }
        .frame(minHeight: 380)
    }
}

// MARK: - toolbar

struct AddBar: View {
    @ObservedObject var model: AppModel
    @AppStorage("showInspector") private var showInspector = true

    var body: some View {
        HStack(spacing: 8) {
            Button { model.add(.text) } label: { Label("Text", systemImage: "textformat") }
            Button { model.add(.qr) } label: { Label("QR Code", systemImage: "qrcode") }
            Button { model.add(.barcode) } label: { Label("Barcode", systemImage: "barcode") }
            Button { model.add(.image) } label: { Label("Image", systemImage: "photo") }
            Button { model.add(.box) } label: { Label("Box", systemImage: "rectangle") }
            Spacer()
            Text("\(model.doc.widthMM) × \(model.doc.lengthMM) mm")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .help(showInspector ? "Hide the inspector" : "Show the inspector")
        }
        .padding(10)
    }
}

// MARK: - canvas

struct CanvasView: View {
    @ObservedObject var model: AppModel
    @State private var dragStart: CGPoint?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let w = CGFloat(model.doc.lengthDots), h = CGFloat(model.doc.widthDots)
            let scale = max(1, min((geo.size.width - 80) / w, (geo.size.height - 80) / h, 8))
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture { model.endEditing(); model.selection = nil; focused = true }
                label(scale: scale)
                    .frame(width: w * scale, height: h * scale)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onMoveCommand { direction in
            switch direction {
            case .left: model.nudge(dx: -1, dy: 0)
            case .right: model.nudge(dx: 1, dy: 0)
            case .up: model.nudge(dx: 0, dy: -1)
            case .down: model.nudge(dx: 0, dy: 1)
            default: break
            }
        }
        .onDeleteCommand { model.deleteSelected() }
    }

    @ViewBuilder
    private func label(scale: CGFloat) -> some View {
        let bitmap = Renderer.render(model.doc)
        let h = CGFloat(model.doc.widthDots)
        let margin = CGFloat(Wire.marginColumns) * scale
        let cropped = max(0, (h - CGFloat(Wire.headDots)) / 2) * scale
        ZStack(alignment: .topLeading) {
            if let cg = bitmap.cgImage {
                Image(decorative: cg, scale: 1)
                    .interpolation(.none)
                    .resizable()
            } else {
                Color.white
            }
            // Areas the print head cannot reach.
            HStack(spacing: 0) {
                Color.red.opacity(0.10).frame(width: margin)
                Spacer(minLength: 0)
                Color.red.opacity(0.10).frame(width: margin)
            }
            .allowsHitTesting(false)
            if cropped > 0 {
                VStack(spacing: 0) {
                    Color.red.opacity(0.10).frame(height: cropped)
                    Spacer(minLength: 0)
                    Color.red.opacity(0.10).frame(height: cropped)
                }
                .allowsHitTesting(false)
            }
            if let id = model.editingID, let e = model.doc.elements.first(where: { $0.id == id }) {
                let b = Renderer.bounds(e)
                InlineTextEditor(model: model, e: model.binding(for: id), scale: scale)
                    .offset(x: b.minX.rounded() * scale - 5, y: b.minY.rounded() * scale - 3)
            } else if let e = model.selected {
                let b = Renderer.bounds(e)
                Rectangle()
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .frame(width: b.width * scale + 4, height: b.height * scale + 4)
                    .offset(x: b.minX.rounded() * scale - 2, y: b.minY.rounded() * scale - 2)
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil {
                        if model.editingID != nil { model.endEditing() }
                        focused = true
                        let p = CGPoint(x: g.startLocation.x / scale, y: g.startLocation.y / scale)
                        if let hit = model.element(at: p) {
                            model.selection = hit.id
                            dragStart = CGPoint(x: hit.x, y: hit.y)
                        } else {
                            model.selection = nil
                            dragStart = CGPoint(x: -1e9, y: -1e9)
                        }
                    }
                    guard let start = dragStart, start.x > -1e8, let i = model.selectedIndex else { return }
                    let nx = (start.x + g.translation.width / scale).rounded()
                    let ny = (start.y + g.translation.height / scale).rounded()
                    if model.doc.elements[i].x != nx || model.doc.elements[i].y != ny {
                        model.doc.elements[i].x = nx
                        model.doc.elements[i].y = ny
                    }
                }
                .onEnded { _ in dragStart = nil }
        )
        .simultaneousGesture(
            SpatialTapGesture(count: 2).onEnded { tap in
                let p = CGPoint(x: tap.location.x / scale, y: tap.location.y / scale)
                if let hit = model.element(at: p), hit.kind == .text { model.beginEditing(hit.id) }
            }
        )
    }
}

// MARK: - typing on the label

/// A text field laid over a text element so it can be typed into in place.
struct InlineTextEditor: View {
    @ObservedObject var model: AppModel
    @Binding var e: LabelElement
    let scale: CGFloat
    @FocusState private var focused: Bool

    var body: some View {
        let n = Renderer.naturalSize(e)
        // A text view, so Return starts a new line. Esc or a click elsewhere finishes.
        TextEditor(text: $e.text)
            .font(.custom(e.fontName, size: (e.fitSize ?? e.fontSize) * scale).weight(e.bold ? .bold : .regular))
            .italic(e.italic)
            .multilineTextAlignment(e.alignment == 0 ? .leading : (e.alignment == 2 ? .trailing : .center))
            .foregroundStyle(.black)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .scrollIndicators(.never)
            .frame(width: max(60, n.width * scale + 28), height: max(22, n.height * scale + 8))
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
            .focused($focused)
            .onKeyPress(.escape) { model.endEditing(); return .handled }
            .onExitCommand { model.endEditing() }
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onChange(of: focused) { _, isFocused in if !isFocused { model.endEditing() } }
    }
}

// MARK: - printer panel

struct PrinterPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var printer: PrinterLink

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Printer").font(.headline)
            connection
            Divider()
            Text("Print").font(.headline)
            Stepper("Copies: \(model.copies)", value: $model.copies, in: 1...50)
            VStack(alignment: .leading, spacing: 2) {
                Text("Darkness: \(model.density)")
                Slider(value: Binding(get: { Double(model.density) }, set: { model.density = Int($0.rounded()) }), in: 1...15, step: 1)
            }
            HStack {
                Button {
                    Task { await model.printNow() }
                } label: {
                    Label("Print", systemImage: "printer.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!printer.isConnected || printer.busy)
                if !printer.progress.isEmpty {
                    Button("Cancel") { printer.cancelPrint() }
                }
            }
            if !printer.progress.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(printer.progress).font(.caption)
                }
            }
            if let err = printer.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
    }

    @ViewBuilder
    private var connection: some View {
        switch printer.state {
        case .starting:
            Text("Starting Bluetooth…").foregroundStyle(.secondary)
        case .bluetoothOff:
            Label("Bluetooth is off.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .unauthorized:
            Text("Label Print needs Bluetooth access. Allow it in System Settings → Privacy & Security → Bluetooth.")
                .font(.callout)
                .foregroundStyle(.orange)
        case .scanning:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(printer.found.isEmpty ? "Looking for printers…" : "Printers nearby").foregroundStyle(.secondary)
            }
            ForEach(printer.found) { p in
                HStack {
                    VStack(alignment: .leading) {
                        Text(PrinterModel.name(forBluetoothName: p.name).map { "Katasymbol \($0)" } ?? p.name)
                            .font(.callout).lineLimit(1).truncationMode(.middle)
                        Text("\(p.name) · \(p.rssi) dBm").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect") { printer.connect(p.id) }
                }
            }
            if printer.found.isEmpty {
                Text("Switch the printer on and close the phone app if it is connected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .connecting(let name):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(name)…").lineLimit(1).truncationMode(.middle)
            }
        case .connected(let name):
            Label(PrinterModel.name(forBluetoothName: name).map { "Katasymbol \($0)" } ?? name, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(name).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                if let s = printer.status {
                    GridRow {
                        Text("Battery").foregroundStyle(.secondary)
                        if let pct = s.batteryPercent, let v = s.batteryVolts {
                            Text("about \(pct)% (\(String(format: "%.2f", v)) V)\(s.charging ? ", charging" : "")")
                        } else {
                            Text("unknown")
                        }
                    }
                }
                GridRow {
                    Text("Roll").foregroundStyle(.secondary)
                    if let m = printer.material {
                        Text("\(m.widthMM) × \(m.lengthMM) mm, \(m.remaining) left")
                    } else {
                        Text("not detected")
                    }
                }
            }
            .font(.callout)
            if let s = printer.status, !s.errors.isEmpty {
                Text(s.errors.joined(separator: " · ")).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Refresh") { Task { await printer.refresh() } }.disabled(printer.busy)
                Button("Disconnect") { printer.disconnect() }.disabled(printer.busy)
            }
        }
    }
}

// MARK: - inspector

struct InspectorPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var printer: PrinterLink

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let id = model.selection, model.selected != nil {
                    ElementInspector(model: model, e: model.binding(for: id))
                } else {
                    labelSettings
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var labelSettings: some View {
        Text("Label").font(.headline)
        if printer.material != nil {
            Text("\(model.doc.widthMM) × \(model.doc.lengthMM) mm").font(.title3).monospacedDigit()
            Text("Size comes from the roll loaded in the printer.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Stepper("Width: \(model.doc.widthMM) mm", value: $model.doc.widthMM, in: 6...15)
            Stepper("Length: \(model.doc.lengthMM) mm", value: $model.doc.lengthMM, in: 10...200)
            Text("Connect the printer and the label takes the size of its roll.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("The print head covers 12 mm. Shaded edges cannot be printed.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Divider()
        Text("Select an item on the label to edit it, or add one from the bar above. Double-click text to type on the label; Return starts a new line, Esc finishes. Drag to move; arrow keys nudge by one dot.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ElementInspector: View {
    @ObservedObject var model: AppModel
    @Binding var e: LabelElement

    private static let families = NSFontManager.shared.availableFontFamilies

    private var title: String {
        switch e.kind {
        case .text: return "Text"
        case .qr: return "QR Code"
        case .barcode: return "Barcode"
        case .image: return "Image"
        case .box: return "Box"
        }
    }

    var body: some View {
        Text(title).font(.headline)
        switch e.kind {
        case .text: textControls
        case .qr: qrControls
        case .barcode: barcodeControls
        case .image: imageControls
        case .box: boxControls
        }
        Divider()
        Text("Position").font(.subheadline).foregroundStyle(.secondary)
        HStack {
            mmField("X", $e.x)
            mmField("Y", $e.y)
        }
        Picker("Rotation", selection: $e.rotation) {
            Text("0°").tag(0); Text("90°").tag(90); Text("180°").tag(180); Text("270°").tag(270)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        HStack {
            Button("Centre ↔") { model.centerSelected(horizontally: true, vertically: false) }
            Button("Centre ↕") { model.centerSelected(horizontally: false, vertically: true) }
        }
        HStack {
            Button("To Front") { model.moveSelected(toFront: true) }
            Button("To Back") { model.moveSelected(toFront: false) }
        }
        Divider()
        HStack {
            Button("Duplicate") { model.duplicateSelected() }
            Button("Delete", role: .destructive) { model.deleteSelected() }
        }
    }

    private func mmField(_ label: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: Binding(get: { value.wrappedValue / 8 }, set: { value.wrappedValue = ($0 * 8).rounded() }),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 44)
            Text("mm").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, unit: String = "mm", perUnit: Double = 8) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label): \(String(format: perUnit == 1 ? "%.0f" : "%.1f", value.wrappedValue / perUnit)) \(unit)")
            Slider(value: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0.rounded() }), in: range)
        }
    }

    @ViewBuilder
    private var textControls: some View {
        TextEditor(text: $e.text)
            .font(.body)
            .frame(height: 70)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.4)))
        Picker("Font", selection: $e.fontName) {
            ForEach(Self.families, id: \.self) { Text($0).tag($0) }
        }
        slider("Size", $e.fontSize, 10...160)
        Toggle("Shrink to fit label", isOn: $e.autoShrink)
        if let fit = e.fitSize {
            Text("Shrunk to \(String(format: "%.1f", fit / 8)) mm to fit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        HStack {
            Toggle(isOn: $e.bold) { Image(systemName: "bold") }.toggleStyle(.button)
            Toggle(isOn: $e.italic) { Image(systemName: "italic") }.toggleStyle(.button)
            Picker("Alignment", selection: $e.alignment) {
                Image(systemName: "text.alignleft").tag(0)
                Image(systemName: "text.aligncenter").tag(1)
                Image(systemName: "text.alignright").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    @ViewBuilder
    private var qrControls: some View {
        TextField("Content", text: $e.text, axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
        slider("Size", $e.width, 21...240)
        Text("Snaps to whole dots per module so it scans cleanly.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var barcodeControls: some View {
        TextField("Content", text: $e.text)
            .textFieldStyle(.roundedBorder)
        Text("Code 128. Letters, digits and basic punctuation.")
            .font(.caption)
            .foregroundStyle(.secondary)
        slider("Bar width", $e.lineWidth, 1...5, unit: "dots", perUnit: 1)
        slider("Height", $e.height, 16...120)
    }

    @ViewBuilder
    private var imageControls: some View {
        Button("Choose Image…") { model.replaceImage() }
        VStack(alignment: .leading, spacing: 2) {
            Text("Size: \(String(format: "%.1f", e.width / 8)) × \(String(format: "%.1f", e.height / 8)) mm")
            Slider(value: Binding(
                get: { e.width },
                set: { new in
                    let ratio = e.width > 0 ? e.height / e.width : 1
                    e.width = new.rounded()
                    e.height = max(2, (new * ratio).rounded())
                }), in: 8...800)
        }
        Toggle("Dither (for photos)", isOn: $e.dither)
        Toggle("Invert", isOn: $e.invert)
    }

    @ViewBuilder
    private var boxControls: some View {
        slider("Width", $e.width, 8...1600)
        slider("Height", $e.height, 8...120)
        slider("Line", $e.lineWidth, 1...12, unit: "dots", perUnit: 1)
        slider("Corner radius", $e.cornerRadius, 0...48)
    }
}
