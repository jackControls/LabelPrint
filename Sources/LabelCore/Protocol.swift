import CLzma
import Foundation

/// Wire protocol for Supvan / Katasymbol E-series label printers over BLE.
/// Written from the protocol notes in heeen/supvan-cups (MIT), docs/PROTOCOL.md,
/// and verified against a Katasymbol unit advertising as "T0224…".
public enum Cmd {
    public static let bufFull: UInt8 = 0x10
    public static let status: UInt8 = 0x11
    public static let checkDevice: UInt8 = 0x12
    public static let startPrint: UInt8 = 0x13
    public static let stopPrint: UInt8 = 0x14
    public static let deviceName: UInt8 = 0x16
    public static let material: UInt8 = 0x30
    public static let nextBlock: UInt8 = 0x5C
}

public enum Wire {
    public static let dotsPerMM = 8
    public static let headDots = 96
    public static let bytesPerColumn = 12
    /// Columns at each end of a label that the printer skips (1 mm).
    public static let marginColumns = 8
    static let bufferSize = 4096
    static let headerSize = 14
    static let maxColumnsPerBuffer = (4096 - 14 - 8) / 12

    /// 16-byte command frame.
    public static func command(_ cmd: UInt8, _ a: Int = 0, _ b: Int = 0) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 16)
        f[0] = 0x7E; f[1] = 0x5A; f[2] = 12; f[4] = 0x10; f[5] = 0x01; f[6] = 0xAA; f[7] = cmd
        f[11] = 0x01
        f[12] = UInt8(a & 0xFF); f[13] = UInt8((a >> 8) & 0xFF)
        f[14] = UInt8(b & 0xFF); f[15] = UInt8((b >> 8) & 0xFF)
        let sum = f[10...].reduce(0) { $0 + Int($1) }
        f[8] = UInt8(sum & 0xFF); f[9] = UInt8((sum >> 8) & 0xFF)
        return f
    }

    /// Split a compressed block into 512-byte data frames carrying 500 payload bytes each.
    public static func dataFrames(_ stream: [UInt8]) -> [[UInt8]] {
        let total = max(1, (stream.count + 499) / 500)
        return (0..<total).map { i in
            var f = [UInt8](repeating: 0, count: 512)
            f.replaceSubrange(0..<8, with: [0x7E, 0x5A, 0xFC, 0x01, 0x10, 0x02, 0xAA, 0xBB])
            f[10] = UInt8(i & 0xFF); f[11] = UInt8(total & 0xFF)
            let lo = min(stream.count, i * 500), hi = min(stream.count, (i + 1) * 500)
            f.replaceSubrange(12..<(12 + hi - lo), with: stream[lo..<hi])
            let sum = f[10..<512].reduce(0) { $0 + Int($1) }
            f[8] = UInt8(sum & 0xFF); f[9] = UInt8((sum >> 8) & 0xFF)
            return f
        }
    }

    /// LZMA1 ".lzma alone" stream with an exact size and no end marker, as the firmware expects.
    public static func lzmaAlone(_ input: [UInt8]) -> [UInt8] {
        var opt = lzma_options_lzma()
        _ = lzma_lzma_preset(&opt, 6)
        opt.dict_size = 8192
        opt.lc = 3; opt.lp = 0; opt.pb = 2
        opt.nice_len = 128
        let capacity = input.count * 2 + 4096
        var out = [UInt8](repeating: 0, count: capacity)
        var outPos = 0
        let rc: lzma_ret = withUnsafeMutablePointer(to: &opt) { optPtr in
            var filters = [
                lzma_filter(id: 0x4000_0000_0000_0001, options: UnsafeMutableRawPointer(optPtr)),  // LZMA1
                lzma_filter(id: UInt64.max, options: nil),
            ]
            return lzma_raw_buffer_encode(&filters, nil, input, input.count, &out, &outPos, capacity)
        }
        precondition(rc == LZMA_OK, "LZMA encode failed")
        var header: [UInt8] = [0x5D]
        withUnsafeBytes(of: UInt32(8192).littleEndian) { header += $0 }
        withUnsafeBytes(of: UInt64(input.count).littleEndian) { header += $0 }
        return header + out[0..<outPos]
    }

    /// Feed speed for a block of the given compressed size; denser data prints slower.
    public static func speed(compressedBytes n: Int) -> Int {
        let steps: [(Int, Int)] = [(3000, 10), (2800, 15), (2500, 20), (2000, 25), (1500, 40), (1000, 45), (500, 55)]
        return steps.first { n > $0.0 }?.1 ?? 60
    }

    public struct Job {
        public var buffers: [[UInt8]] = []
        /// One compressed block per print buffer.
        public var blocks: [[UInt8]] = []
        public var speed = 60
    }

    /// Build a print job from printable head columns (12 bytes each, bit 0 of byte 0 = first dot).
    public static func buildJob(columns: [[UInt8]], density: Int) -> Job {
        let cols = columns.isEmpty ? [[UInt8](repeating: 0, count: bytesPerColumn)] : columns
        let d = max(0, min(15, density))
        var job = Job()
        var start = 0
        while start < cols.count {
            let n = min(maxColumnsPerBuffer, cols.count - start)
            let first = start == 0, last = start + n >= cols.count
            var buf = [UInt8](repeating: 0, count: bufferSize)
            buf[2] = (first ? 0x02 : 0) | (last ? 0x0C : 0)
            buf[3] = UInt8((d << 2) | 0x40)
            buf[4] = UInt8(n & 0xFF); buf[5] = UInt8(n >> 8)
            buf[6] = UInt8(bytesPerColumn)
            buf[8] = UInt8(marginColumns); buf[10] = UInt8(marginColumns)
            buf[12] = UInt8(d)
            for k in 0..<n {
                let o = headerSize + k * bytesPerColumn
                buf.replaceSubrange(o..<(o + bytesPerColumn), with: cols[start + k])
            }
            let end = n * bytesPerColumn + headerSize
            var sum = buf[2..<14].reduce(0) { $0 + Int($1) }
            if end >= 256 { for i in 1...(end / 256) { sum += Int(buf[i * 256 - 1]) } }
            buf[0] = UInt8(sum & 0xFF); buf[1] = UInt8((sum >> 8) & 0xFF)
            job.buffers.append(buf)
            job.blocks.append(lzmaAlone(buf))
            start += n
        }
        job.speed = job.blocks.map { speed(compressedBytes: $0.count) }.min() ?? 60
        return job
    }
}

public struct PrinterStatus: Equatable {
    public var bufferFull = false, busy = false, printing = false, charging = false
    public var batteryVolts: Double?
    public var errors: [String] = []

    public init(frame f: [UInt8]) {
        guard f.count >= 20 else { errors = ["Short status reply"]; return }
        bufferFull = f[14] & 0x01 != 0
        busy = f[15] & 0x04 != 0
        printing = f[16] & 0x40 != 0
        charging = f[16] & 0x10 != 0
        if f[16] & 0x08 != 0 { errors.append("Cover is open") }
        if f[17] & 0x01 != 0 { errors.append("No label roll installed") }
        if f[14] & 0x02 != 0 { errors.append("Label roll could not be read") }
        if f[14] & 0x04 != 0 { errors.append("Labels used up") }
        if f[14] & 0x08 != 0 { errors.append("Wrong label type") }
        if f[14] & 0x40 != 0 { errors.append("Battery is low") }
        if f[15] & 0x08 != 0 { errors.append("Print head is too hot") }
        if f.count >= 26 { batteryVolts = Double(Int(f[24]) | Int(f[25]) << 8) / 1000 }
    }

    /// Rough charge estimate from a single-cell lithium voltage.
    public var batteryPercent: Int? {
        guard let v = batteryVolts, v > 2.5, v < 4.6 else { return nil }
        return max(0, min(100, Int(((v - 3.4) / (4.15 - 3.4) * 100).rounded())))
    }
}

public struct Material: Equatable {
    public var type = 0, widthMM = 0, lengthMM = 0, gapMM = 0, remaining = 0

    public init?(frame f: [UInt8]) {
        guard f.count >= 47 else { return nil }
        type = Int(f[39]); widthMM = Int(f[40]); lengthMM = Int(f[41]); gapMM = Int(f[42])
        remaining = Int(f[43]) | Int(f[44]) << 8 | Int(f[45]) << 16 | Int(f[46]) << 24
        if widthMM == 0 { return nil }
    }
}
