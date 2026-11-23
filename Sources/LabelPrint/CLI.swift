import AppKit
import LabelCore

/// The `labelprint` command line tool. It is the app's own executable run with a command.
enum CLI {
    struct Failure: Error {
        let message: String
        var code: Int32 = 1
        static func usage(_ m: String) -> Failure { Failure(message: m + "\nRun 'labelprint help' for usage.", code: 2) }
    }

    static let commands: Set<String> = ["scan", "status", "print", "text", "qr", "barcode", "image", "render", "help", "version"]

    static func isCommand(_ arg: String) -> Bool {
        commands.contains(arg) || ["--help", "-h", "--version"].contains(arg)
    }

    static let help = """
    labelprint — print labels on a Katasymbol / Supvan Bluetooth label printer

    USAGE
      labelprint <command> [arguments] [options]

    COMMANDS
      scan                     List printers in range.
      status                   Show the printer's model, battery and loaded roll.
      print <file.label>       Print a label saved from the Label Print app.
      text <text>              Print text, sized to fill the label. Use \\n for a new line, or - to read stdin.
      qr <content>             Print a QR code, optionally with --caption beside it.
      barcode <content>        Print a Code 128 barcode, optionally with --caption under it.
      image <file>             Print a picture, scaled to fit.
      render <file.label>      Write the label as a PNG (needs -o). No printer involved.
      help, version

    PRINTING OPTIONS (print, text, qr, barcode, image)
      -n, --copies <n>         Number of labels (default 1).
      -d, --darkness <1-15>    Print darkness (default 4).
      -p, --printer <name>     Printer to use: part of its Bluetooth name, or its model (e.g. E11).
                               Default: the printer used last, else the nearest one.
          --timeout <seconds>  How long to look for the printer (default 15).
          --preview <out.png>  Write a PNG of the label instead of printing it.
          --save <out.label>   Also save the label so the app can open it.
          --no-print           Do not print (useful with --save).
          --width <mm>         Label width  \\ used only when not printing, or when the
          --length <mm>        Label length /  printer cannot read its roll (default 12 x 40).
      -v, --verbose            Show what is sent to the printer.

    CONTENT OPTIONS
      text:     --font <family>  --size <mm>  --bold  --italic  --align left|center|right  --rotate 0|90|180|270
      qr:       --caption <text>  (plus the text options, applied to the caption)
      barcode:  --caption <text>
      image:    --no-dither  --invert

    OTHER OPTIONS
      scan:     --seconds <n> (default 5)   --json
      status:   --json   -p, --printer   --timeout
      render:   -o, --output <out.png>   --scale <n> (default 4)

    When printing, the label always takes the size of the roll in the printer.

    EXAMPLES
      labelprint text "Spare keys"
      labelprint text "Line one\\nLine two" --bold -n 3
      labelprint qr "https://example.com" --caption "Scan me"
      labelprint barcode INV-00412 --caption INV-00412
      labelprint text "Draft" --preview draft.png --length 50
      labelprint print shelf.label --copies 5
    """

    // MARK: argument parsing

    struct Args {
        var positionals: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []

        func string(_ k: String) -> String? { values[k] }
        func has(_ k: String) -> Bool { flags.contains(k) }
        func int(_ k: String, _ range: ClosedRange<Int>) throws -> Int? {
            guard let raw = values[k] else { return nil }
            guard let v = Int(raw), range.contains(v) else {
                throw Failure.usage("--\(k) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
            }
            return v
        }
        func double(_ k: String, _ range: ClosedRange<Double>) throws -> Double? {
            guard let raw = values[k] else { return nil }
            guard let v = Double(raw), range.contains(v) else {
                throw Failure.usage("--\(k) must be a number from \(range.lowerBound) to \(range.upperBound).")
            }
            return v
        }
    }

    private static let valueOptions: Set<String> = [
        "copies", "darkness", "printer", "timeout", "preview", "save", "width", "length",
        "font", "size", "align", "rotate", "caption", "seconds", "output", "scale",
    ]
    private static let flagOptions: Set<String> = ["json", "bold", "italic", "no-dither", "invert", "verbose", "no-print", "help"]
    private static let shorts: [Character: String] = ["n": "copies", "d": "darkness", "p": "printer", "o": "output", "v": "verbose", "h": "help"]

    static func parse(_ raw: [String]) throws -> Args {
        var out = Args()
        var i = 0
        var onlyPositionals = false
        while i < raw.count {
            let a = raw[i]
            i += 1
            if onlyPositionals || a == "-" || !a.hasPrefix("-") { out.positionals.append(a); continue }
            if a == "--" { onlyPositionals = true; continue }
            var name: String
            var inline: String?
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    name = String(body[..<eq]); inline = String(body[body.index(after: eq)...])
                } else {
                    name = body
                }
            } else {
                guard a.count == 2, let long = shorts[a.last!] else { throw Failure.usage("Unknown option \(a).") }
                name = long
            }
            if flagOptions.contains(name) {
                out.flags.insert(name)
            } else if valueOptions.contains(name) {
                if let inline {
                    out.values[name] = inline
                } else {
                    guard i < raw.count else { throw Failure.usage("Option \(a) needs a value.") }
                    out.values[name] = raw[i]
                    i += 1
                }
            } else {
                throw Failure.usage("Unknown option \(a).")
            }
        }
        return out
    }

    // MARK: entry

    static func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    static func run(_ raw: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task { @MainActor in
            do {
                try await dispatch(raw)
                exit(0)
            } catch let f as Failure {
                err("labelprint: " + f.message)
                exit(f.code)
            } catch {
                err("labelprint: " + error.localizedDescription)
                exit(1)
            }
        }
        dispatchMain()
    }

    @MainActor
    private static func dispatch(_ raw: [String]) async throws {
        var raw = raw
        let command = raw.removeFirst()
        let args = try parse(raw)
        if command == "help" || command == "--help" || command == "-h" || args.has("help") {
            print(help)
            return
        }
        switch command {
        case "version", "--version":
            print("labelprint " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.0"))
        case "scan": try await scan(args)
        case "status": try await status(args)
        case "render": try render(args)
        case "print", "text", "qr", "barcode", "image": try await produce(command, args)
        default: throw Failure.usage("Unknown command '\(command)'.")
        }
    }

    // MARK: printer session

    private static func displayName(_ bluetoothName: String) -> String {
        PrinterModel.name(forBluetoothName: bluetoothName).map { "Katasymbol \($0)" } ?? bluetoothName
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    private static func makeLink(_ args: Args) async throws -> PrinterLink {
        let link = PrinterLink()
        link.autoConnect = false
        if args.has("verbose") { link.onLog = { err("  " + $0) } }
        let deadline = Date().addingTimeInterval(5)
        while link.state == .starting && Date() < deadline { await pause(0.05) }
        switch link.state {
        case .bluetoothOff: throw Failure(message: "Bluetooth is off.")
        case .unauthorized:
            throw Failure(message: "No Bluetooth access. Allow it for your terminal app (or Label Print) in System Settings → Privacy & Security → Bluetooth.")
        case .starting: throw Failure(message: "Bluetooth did not start.")
        default: return link
        }
    }

    private static func matches(_ p: FoundPrinter, _ wanted: String) -> Bool {
        let w = wanted.lowercased()
        if p.name.lowercased().contains(w) { return true }
        guard let model = PrinterModel.name(forBluetoothName: p.name)?.lowercased() else { return false }
        return model == w || "katasymbol \(model)" == w
    }

    @MainActor
    private static func connect(_ args: Args) async throws -> PrinterLink {
        let link = try await makeLink(args)
        let timeout = try args.double("timeout", 1...120) ?? 15
        let wanted = args.string("printer")
        let deadline = Date().addingTimeInterval(timeout)
        var chosen: FoundPrinter?
        var firstSeen: Date?
        while Date() < deadline && chosen == nil {
            if let wanted {
                chosen = link.found.first { matches($0, wanted) }
            } else if let last = PrinterLink.lastPrinterID, let hit = link.found.first(where: { $0.id == last }) {
                chosen = hit
            } else if !link.found.isEmpty {
                // No known printer in range: give the others a moment to show up, then take the nearest.
                if firstSeen == nil { firstSeen = Date() }
                if Date().timeIntervalSince(firstSeen!) > 1.5 { chosen = link.found.max { $0.rssi < $1.rssi } }
            }
            if chosen == nil { await pause(0.1) }
        }
        guard let printer = chosen else {
            throw Failure(message: wanted.map { "No printer matching '\($0)' found." }
                ?? "No printer found. Switch it on, and close the phone app if it is connected to the printer.")
        }
        link.connect(printer.id)
        let connectDeadline = Date().addingTimeInterval(14)
        while !link.isConnected && Date() < connectDeadline {
            if link.state == .scanning, let e = link.lastError { throw Failure(message: e) }
            await pause(0.05)
        }
        guard link.isConnected else { throw Failure(message: link.lastError ?? "Could not connect to \(printer.name).") }
        let ready = Date().addingTimeInterval(8)
        while (link.status == nil || link.busy) && Date() < ready { await pause(0.05) }
        guard link.status != nil else { throw Failure(message: link.lastError ?? "The printer connected but did not answer.") }
        return link
    }

    // MARK: scan / status

    @MainActor
    private static func scan(_ args: Args) async throws {
        let link = try await makeLink(args)
        await pause(try args.double("seconds", 1...60) ?? 5)
        let found = link.found.sorted { $0.rssi > $1.rssi }
        if args.has("json") {
            let list: [[String: Any]] = found.map {
                ["name": $0.name, "model": PrinterModel.name(forBluetoothName: $0.name) ?? NSNull(), "rssi": $0.rssi, "id": $0.id.uuidString]
            }
            printJSON(list)
        } else if found.isEmpty {
            print("No printers found.")
        } else {
            for p in found {
                let model = PrinterModel.name(forBluetoothName: p.name).map { "Katasymbol \($0)" } ?? "Unknown model"
                print("\(model.padding(toLength: 18, withPad: " ", startingAt: 0)) \(p.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(p.rssi) dBm")
            }
        }
    }

    private static func printJSON(_ object: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    }

    @MainActor
    private static func status(_ args: Args) async throws {
        let link = try await connect(args)
        defer { link.disconnect() }
        let name = link.bluetoothName ?? ""
        let s = link.status!
        if args.has("json") {
            var out: [String: Any] = [
                "name": name,
                "model": PrinterModel.name(forBluetoothName: name) ?? NSNull(),
                "protocolName": link.deviceName,
                "batteryVolts": s.batteryVolts.map { NSDecimalNumber(string: String(format: "%.2f", $0)) as Any } ?? NSNull(),
                "batteryPercent": s.batteryPercent ?? NSNull(),
                "charging": s.charging,
                "errors": s.errors,
            ]
            if let m = link.material {
                out["roll"] = ["widthMM": m.widthMM, "lengthMM": m.lengthMM, "gapMM": m.gapMM, "remaining": m.remaining]
            } else {
                out["roll"] = NSNull()
            }
            printJSON(out)
        } else {
            print("Printer:  \(displayName(name)) (\(name))")
            if let pct = s.batteryPercent, let v = s.batteryVolts {
                print("Battery:  about \(pct)% (\(String(format: "%.2f", v)) V)\(s.charging ? ", charging" : "")")
            }
            if let m = link.material {
                print("Roll:     \(m.widthMM) × \(m.lengthMM) mm, \(m.gapMM) mm gap, \(m.remaining) labels left")
            } else {
                print("Roll:     not detected")
            }
            print("State:    " + (s.errors.isEmpty ? "ready" : s.errors.joined(separator: "; ")))
        }
    }

    // MARK: documents

    private static func loadDocument(_ path: String) throws -> LabelDocument {
        do {
            return try JSONDecoder().decode(LabelDocument.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch let e as DecodingError {
            _ = e
            throw Failure(message: "\(path) is not a label file.")
        } catch {
            throw Failure(message: "Cannot read \(path): \(error.localizedDescription)")
        }
    }

    private static func writeFile(_ data: Data, _ path: String) throws {
        do { try data.write(to: URL(fileURLWithPath: path)) } catch {
            throw Failure(message: "Cannot write \(path): \(error.localizedDescription)")
        }
    }

    private static func render(_ args: Args) throws {
        guard args.positionals.count == 1 else { throw Failure.usage("render takes one label file.") }
        guard let out = args.string("output") else { throw Failure.usage("render needs -o <out.png>.") }
        let bmp = Renderer.render(try loadDocument(args.positionals[0]))
        guard let png = Renderer.pngData(bmp, scale: try args.int("scale", 1...16) ?? 4) else { throw Failure(message: "Could not render the label.") }
        try writeFile(png, out)
        print("Wrote \(out) (\(bmp.height / Wire.dotsPerMM) × \(bmp.width / Wire.dotsPerMM) mm)")
    }

    private static func style(_ args: Args) throws -> QuickLabel.Style {
        var s = QuickLabel.Style()
        if let font = args.string("font") {
            guard let family = NSFontManager.shared.availableFontFamilies.first(where: { $0.caseInsensitiveCompare(font) == .orderedSame }) else {
                throw Failure(message: "No font family named '\(font)' is installed.")
            }
            s.fontName = family
        }
        s.bold = args.has("bold"); s.italic = args.has("italic")
        s.sizeMM = try args.double("size", 1...50)
        if let a = args.string("align") {
            guard let i = ["left", "center", "right"].firstIndex(of: a.lowercased() == "centre" ? "center" : a.lowercased()) else {
                throw Failure.usage("--align must be left, center or right.")
            }
            s.alignment = i
        }
        if let r = args.string("rotate") {
            guard let v = Int(r), [0, 90, 180, 270].contains(v) else { throw Failure.usage("--rotate must be 0, 90, 180 or 270.") }
            s.rotation = v
        }
        return s
    }

    /// Build the label for a content command at the given size.
    private static func build(_ command: String, _ args: Args, widthMM: Int, lengthMM: Int) throws -> LabelDocument {
        func one(_ what: String) throws -> String {
            guard !args.positionals.isEmpty else { throw Failure.usage("\(command) needs \(what).") }
            return args.positionals.joined(separator: " ")
        }
        do {
            switch command {
            case "print":
                guard args.positionals.count == 1 else { throw Failure.usage("print takes one label file.") }
                var doc = try loadDocument(args.positionals[0])
                doc.widthMM = widthMM; doc.lengthMM = lengthMM
                return doc
            case "text":
                var text = try one("some text")
                if text == "-" {
                    text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    text = text.replacingOccurrences(of: "\\n", with: "\n")
                }
                guard !text.isEmpty else { throw Failure(message: "There is no text to print.") }
                return QuickLabel.text(text, style: try style(args), widthMM: widthMM, lengthMM: lengthMM)
            case "qr":
                return try QuickLabel.qr(try one("content"), caption: args.string("caption"), style: try style(args), widthMM: widthMM, lengthMM: lengthMM)
            case "barcode":
                return try QuickLabel.barcode(try one("content"), caption: args.string("caption"), style: try style(args), widthMM: widthMM, lengthMM: lengthMM)
            default:
                guard args.positionals.count == 1 else { throw Failure.usage("image takes one picture file.") }
                guard let data = FileManager.default.contents(atPath: args.positionals[0]) else {
                    throw Failure(message: "Cannot read \(args.positionals[0]).")
                }
                return try QuickLabel.image(data, dither: !args.has("no-dither"), invert: args.has("invert"), widthMM: widthMM, lengthMM: lengthMM)
            }
        } catch let e as QuickLabel.LayoutError {
            throw Failure(message: e.message)
        }
    }

    @MainActor
    private static func produce(_ command: String, _ args: Args) async throws {
        let copies = try args.int("copies", 1...200) ?? 1
        let darkness = try args.int("darkness", 1...15) ?? 4
        let manualWidth = try args.int("width", 6...15), manualLength = try args.int("length", 10...200)
        let printing = args.string("preview") == nil && !args.has("no-print")

        func finish(_ doc: LabelDocument) throws {
            if let path = args.string("save") {
                try writeFile(try JSONEncoder().encode(doc), path)
                print("Saved \(path)")
            }
            if let path = args.string("preview") {
                guard let png = Renderer.pngData(Renderer.render(doc), scale: 4) else { throw Failure(message: "Could not render the label.") }
                try writeFile(png, path)
                print("Wrote \(path) (\(doc.widthMM) × \(doc.lengthMM) mm)")
            }
        }

        guard printing else {
            // A saved label keeps its own size unless one is given.
            var width = manualWidth ?? 12, length = manualLength ?? 40
            if command == "print", args.positionals.count == 1 {
                let saved = try loadDocument(args.positionals[0])
                width = manualWidth ?? saved.widthMM; length = manualLength ?? saved.lengthMM
            }
            if args.string("preview") == nil && args.string("save") == nil {
                throw Failure.usage("--no-print needs --save or --preview, otherwise there is nothing to do.")
            }
            try finish(try build(command, args, widthMM: width, lengthMM: length))
            return
        }

        // Check the arguments before waking the radio.
        _ = try build(command, args, widthMM: manualWidth ?? 12, lengthMM: manualLength ?? 40)

        let link = try await connect(args)
        defer { link.disconnect() }
        let name = displayName(link.bluetoothName ?? "printer")
        if let e = link.status?.errors.first { throw Failure(message: "\(name): \(e)") }
        let width: Int, length: Int
        if let m = link.material {
            width = m.widthMM
            length = m.lengthMM > 0 ? m.lengthMM : (manualLength ?? 40)
        } else if let w = manualWidth, let l = manualLength {
            width = w; length = l
        } else {
            throw Failure(message: "\(name) could not read its roll. Give the label size with --width and --length.")
        }
        let doc = try build(command, args, widthMM: width, lengthMM: length)
        try finish(doc)

        // Ctrl-C stops the printer cleanly instead of leaving it mid-job.
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { link.cancelPrint() }
        interrupt.resume()

        let ok = await link.printLabel(columns: Renderer.columns(doc), copies: copies, density: darkness)
        guard ok else { throw Failure(message: link.lastError ?? "Printing failed.") }
        let left = link.material.map { " (\($0.remaining) left on the roll)" } ?? ""
        print("Printed \(copies) label\(copies == 1 ? "" : "s") on \(name)\(left)")
    }
}
