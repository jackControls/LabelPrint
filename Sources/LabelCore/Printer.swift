import CoreBluetooth
import Foundation

public struct FoundPrinter: Identifiable, Equatable {
    public let id: UUID
    public var name: String
    public var rssi: Int
}

public enum LinkState: Equatable {
    case starting
    case bluetoothOff
    case unauthorized
    case scanning
    case connecting(String)
    case connected(String)
}

public struct PrinterError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Bluetooth LE link to one printer. All access happens on the main thread.
public final class PrinterLink: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published public private(set) var state: LinkState = .starting
    @Published public private(set) var found: [FoundPrinter] = []
    @Published public private(set) var deviceName = ""
    @Published public private(set) var status: PrinterStatus?
    @Published public private(set) var material: Material?
    @Published public private(set) var busy = false
    @Published public private(set) var progress = ""
    @Published public var lastError: String?

    public var onLog: ((String) -> Void)?
    public var autoConnect = true

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withoutResponse
    private var linkReady = false
    private var pending: [UInt8] = []
    private var frames: [[UInt8]] = []
    private var cancelRequested = false
    private var userDisconnected = false

    private static let lastPrinterKey = "lastPrinterID"
    /// (service, notify characteristic, write characteristic) layouts used by this printer family.
    private static let layouts: [(String, String, String)] = [
        ("FEE7", "FEC1", "FEC1"),
        ("0000E0FF-3C17-D293-8E48-14FE2E4DA212", "FFE1", "FFE9"),
        ("FF00", "FF01", "FF02"),
    ]

    public override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    public var isConnected: Bool { if case .connected = state { return true }; return false }

    /// The printer this Mac connected to most recently.
    public static var lastPrinterID: UUID? {
        UserDefaults.standard.string(forKey: lastPrinterKey).flatMap(UUID.init(uuidString:))
    }

    /// Bluetooth name of the connected printer, e.g. "T0224C…".
    public var bluetoothName: String? { if case .connected(let n) = state { return n }; return nil }

    private func log(_ s: String) { onLog?(s) }

    // MARK: scanning and connecting

    public static func looksLikePrinter(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.contains("supvan") || lower.contains("katasymbol") { return true }
        return name.range(of: #"^[TGDE]\d{2,4}[A-Z0-9]{6,}$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private func startScan() {
        guard central.state == .poweredOn else { return }
        found = []
        state = .scanning
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn: startScan()
        case .unauthorized: state = .unauthorized
        case .poweredOff, .unsupported: state = .bluetoothOff
        default: state = .starting
        }
    }

    public func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData ad: [String: Any], rssi: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        guard Self.looksLikePrinter(name) else { return }
        peripherals[p.identifier] = p
        if let i = found.firstIndex(where: { $0.id == p.identifier }) {
            found[i].rssi = rssi.intValue
        } else {
            found.append(FoundPrinter(id: p.identifier, name: name, rssi: rssi.intValue))
            log("found \(name)")
            if autoConnect, !userDisconnected, state == .scanning,
               UserDefaults.standard.string(forKey: Self.lastPrinterKey) == p.identifier.uuidString {
                connect(p.identifier)
            }
        }
    }

    public func connect(_ id: UUID) {
        guard let p = peripherals[id], state == .scanning else { return }
        let name = found.first { $0.id == id }?.name ?? p.name ?? "printer"
        userDisconnected = false
        lastError = nil
        central.stopScan()
        peripheral = p
        p.delegate = self
        linkReady = false
        state = .connecting(name)
        central.connect(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, case .connecting = self.state, self.peripheral === p else { return }
            self.lastError = "Could not connect to \(name). Is it switched on and not connected to a phone?"
            self.central.cancelPeripheralConnection(p)
            self.reset()
        }
    }

    public func disconnect() {
        userDisconnected = true
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        reset()
    }

    private func reset() {
        peripheral = nil; writeChar = nil; notifyChar = nil; linkReady = false
        deviceName = ""; status = nil; material = nil
        startScan()
    }

    public func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        p.discoverServices(nil)
    }

    public func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        lastError = "Connection failed: \(error?.localizedDescription ?? "unknown error")"
        reset()
    }

    public func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        log("disconnected")
        if error != nil, !userDisconnected { lastError = "The printer disconnected." }
        reset()
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] { p.discoverCharacteristics(nil, for: s) }
    }

    public func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard writeChar == nil else { return }
        for (svc, notify, write) in Self.layouts where s.uuid == CBUUID(string: svc) {
            let chars = s.characteristics ?? []
            guard let n = chars.first(where: { $0.uuid == CBUUID(string: notify) }),
                  let w = chars.first(where: { $0.uuid == CBUUID(string: write) }) else { continue }
            notifyChar = n; writeChar = w
            writeType = w.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
            p.setNotifyValue(true, for: n)
        }
    }

    public func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        guard ch === notifyChar, ch.isNotifying, !linkReady else { return }
        linkReady = true
        let name = found.first { $0.id == p.identifier }?.name ?? p.name ?? "printer"
        UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.lastPrinterKey)
        state = .connected(name)
        log("connected to \(name)")
        Task { @MainActor in await self.refresh() }
    }

    // MARK: frames

    public func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        var buf = pending + [UInt8](d)
        var i = 0
        while true {
            while i + 1 < buf.count && !(buf[i] == 0x7E && buf[i + 1] == 0x5A) { i += 1 }
            if i + 4 > buf.count { break }
            let total = (Int(buf[i + 2]) | Int(buf[i + 3]) << 8) + 4
            if total < 8 || total > 2048 { i += 1; continue }
            if i + total > buf.count { break }
            frames.append(Array(buf[i..<(i + total)]))
            i += total
        }
        buf.removeFirst(min(i, buf.count))
        pending = buf
    }

    private func takeFrame(_ cmd: UInt8?) -> [UInt8]? {
        while !frames.isEmpty {
            let f = frames.removeFirst()
            if cmd == nil || (f.count > 7 && f[7] == cmd) { return f }
        }
        return nil
    }

    private func sleep(ms: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    private func rawWrite(_ bytes: [UInt8]) throws {
        guard let p = peripheral, let w = writeChar, p.state == .connected else {
            throw PrinterError("The printer is not connected.")
        }
        p.writeValue(Data(bytes), for: w, type: writeType)
    }

    @MainActor
    @discardableResult
    private func command(_ cmd: UInt8, _ a: Int = 0, _ b: Int = 0, timeout: Double = 4) async throws -> [UInt8] {
        frames.removeAll(); pending.removeAll()
        try rawWrite(Wire.command(cmd, a, b))
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let f = takeFrame(cmd) { return f }
            try await sleep(ms: 5)
        }
        throw PrinterError(String(format: "The printer did not answer (command 0x%02X).", cmd))
    }

    @MainActor
    private func readStatus() async throws -> PrinterStatus {
        let s = PrinterStatus(frame: try await command(Cmd.status))
        status = s
        return s
    }

    // MARK: public operations

    /// Re-read name, status and the loaded roll.
    @MainActor
    public func refresh() async {
        guard isConnected, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let n = try await command(Cmd.deviceName)
            if n.count > 22 { deviceName = String(decoding: n[22...].prefix { $0 != 0 }, as: UTF8.self) }
            _ = try await readStatus()
            material = Material(frame: try await command(Cmd.material))
            if let m = material { log("roll \(m.widthMM)x\(m.lengthMM) mm, gap \(m.gapMM), \(m.remaining) left") }
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func cancelPrint() { cancelRequested = true }

    /// Print one label image `copies` times. `columns` are the printable head columns.
    @MainActor
    @discardableResult
    public func printLabel(columns: [[UInt8]], copies: Int, density: Int) async -> Bool {
        guard isConnected, !busy else { return false }
        busy = true
        cancelRequested = false
        lastError = nil
        var ok = true
        do {
            let job = Wire.buildJob(columns: columns, density: density)
            log("job: \(columns.count) columns, \(job.blocks.count) block(s), \(job.blocks.map(\.count)) bytes, speed \(job.speed)")
            for c in 1...max(1, copies) {
                progress = copies > 1 ? "Printing \(c) of \(copies)…" : "Printing…"
                try await run(job)
            }
        } catch {
            ok = false
            lastError = error.localizedDescription
            log("print failed: \(error.localizedDescription)")
        }
        progress = ""
        busy = false
        await refresh()
        return ok
    }

    @MainActor
    private func checkCancel() throws {
        if cancelRequested { throw PrinterError("Printing was cancelled.") }
    }

    @MainActor
    private func run(_ job: Wire.Job) async throws {
        try await command(Cmd.checkDevice)
        var s = try await readStatus()
        var tries = 0
        while (s.busy || s.printing) && tries < 100 {
            try await sleep(ms: 100); s = try await readStatus(); tries += 1
        }
        if let e = s.errors.first { throw PrinterError(e) }
        try await command(Cmd.startPrint)
        do {
            tries = 0
            repeat {
                try await sleep(ms: 100); s = try await readStatus(); tries += 1
                if let e = s.errors.first { throw PrinterError(e) }
            } while !s.printing && tries < 60
            if !s.printing { throw PrinterError("The printer did not start printing.") }

            for (i, block) in job.blocks.enumerated() {
                tries = 0
                repeat {
                    try checkCancel()
                    try await sleep(ms: 20); s = try await readStatus(); tries += 1
                    if let e = s.errors.first { throw PrinterError(e) }
                } while s.bufferFull && tries < 500
                if s.bufferFull { throw PrinterError("The printer's buffer stayed full.") }

                let dataFrames = Wire.dataFrames(block)
                try await command(Cmd.nextBlock, 512, dataFrames.count)
                for f in dataFrames {
                    frames.removeAll(); pending.removeAll()
                    for o in stride(from: 0, to: 512, by: 128) {
                        try rawWrite(Array(f[o..<(o + 128)]))
                        try await sleep(ms: 10)
                    }
                    let deadline = Date().addingTimeInterval(2)
                    var acked = false
                    while Date() < deadline {
                        if takeFrame(nil) != nil { acked = true; break }
                        try await sleep(ms: 5)
                    }
                    if !acked { throw PrinterError("The printer did not acknowledge the print data.") }
                }
                try await sleep(ms: 20)
                try await command(Cmd.bufFull, block.count, job.speed)
                log("block \(i + 1)/\(job.blocks.count) sent")
            }

            tries = 0
            repeat {
                try checkCancel()
                try await sleep(ms: 200); s = try await readStatus(); tries += 1
                if let e = s.errors.first { throw PrinterError(e) }
            } while (s.printing || s.busy) && tries < 300
            if s.printing { throw PrinterError("The printer did not finish the label.") }
        } catch {
            _ = try? await command(Cmd.stopPrint, timeout: 2)
            throw error
        }
    }
}
