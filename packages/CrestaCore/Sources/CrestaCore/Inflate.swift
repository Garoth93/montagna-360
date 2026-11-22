import Foundation
#if canImport(Compression)
import Compression
#endif

public enum InflateError: Error, Equatable {
    case invalidBlockType
    case invalidStoredLength
    case invalidCode
    case invalidDistance
    case truncated
    case notGzip
}

/// DEFLATE (RFC 1951) decoder in pure Swift, so that the same code runs on
/// Linux tests. On Apple platforms the system Compression framework is used
/// when the output size is known (ZIP entries, gzip trailer).
public enum Inflate {
    public static func inflate(_ data: Data, expectedSize: Int? = nil) throws -> Data {
        #if canImport(Compression)
        if let n = expectedSize, n > 0, let out = systemInflate(data, size: n) { return out }
        #endif
        return try swiftInflate(data, sizeHint: expectedSize)
    }

    #if canImport(Compression)
    static func systemInflate(_ data: Data, size: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? out : nil
    }
    #endif

    /// gzip (RFC 1952) member, as found in Strava's `.gpx.gz` / `.fit.gz`.
    public static func gunzip(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { throw InflateError.notGzip }
        let flags = b[3]
        var p = 10
        if flags & 4 != 0 { guard p + 2 <= b.count else { throw InflateError.truncated }; p += 2 + Int(b[p]) | Int(b[p + 1]) << 8 }
        if flags & 8 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }
        if flags & 16 != 0 { while p < b.count && b[p] != 0 { p += 1 }; p += 1 }
        if flags & 2 != 0 { p += 2 }
        guard p < b.count - 8 else { throw InflateError.truncated }
        let n = b.count
        let isize = Int(b[n - 4]) | Int(b[n - 3]) << 8 | Int(b[n - 2]) << 16 | Int(b[n - 1]) << 24
        return try inflate(Data(b[p..<(n - 8)]), expectedSize: isize > 0 ? isize : nil)
    }

    public static func isGzip(_ data: Data) -> Bool {
        data.count > 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    // MARK: - Pure Swift implementation

    struct Huffman {
        var count = [Int](repeating: 0, count: 16)
        var symbol: [Int]
        /// Fast table: index = next 9 bits (LSB first); value = symbol << 4 | length, or -1.
        var fast = [Int](repeating: -1, count: 512)

        init(lengths: [Int]) {
            symbol = [Int](repeating: 0, count: lengths.count)
            for l in lengths { count[l] += 1 }
            count[0] = 0
            var offs = [Int](repeating: 0, count: 16)
            for i in 1..<16 { offs[i] = offs[i - 1] + count[i - 1] }
            for (s, l) in lengths.enumerated() where l != 0 {
                symbol[offs[l]] = s
                offs[l] += 1
            }
            // Build the fast table from canonical codes.
            var code = 0
            var idx = 0
            for len in 1...15 {
                for _ in 0..<count[len] {
                    if len <= 9 {
                        // Reverse bits of `code` (len bits).
                        var r = 0
                        var c = code
                        for _ in 0..<len { r = (r << 1) | (c & 1); c >>= 1 }
                        var k = r
                        while k < 512 { fast[k] = symbol[idx] << 4 | len; k += 1 << len }
                    }
                    code += 1
                    idx += 1
                }
                code <<= 1
            }
        }
    }

    struct BitReader {
        let bytes: [UInt8]
        var pos = 0
        var bitBuf: UInt64 = 0
        var bitCount = 0

        init(_ b: [UInt8]) { bytes = b }

        @inline(__always) mutating func refill() {
            while bitCount <= 56 {
                let byte: UInt64 = pos < bytes.count ? UInt64(bytes[pos]) : 0
                pos += 1
                bitBuf |= byte << UInt64(bitCount)
                bitCount += 8
            }
        }

        @inline(__always) mutating func bits(_ n: Int) throws -> Int {
            if bitCount < n { refill() }
            if pos > bytes.count + 8 { throw InflateError.truncated }
            let v = Int(bitBuf & ((1 << UInt64(n)) - 1))
            bitBuf >>= UInt64(n)
            bitCount -= n
            return v
        }

        mutating func alignToByte() {
            let drop = bitCount % 8
            bitBuf >>= UInt64(drop)
            bitCount -= drop
        }

        @inline(__always) mutating func decode(_ h: Huffman) throws -> Int {
            if bitCount < 16 { refill() }
            let f = h.fast[Int(bitBuf & 511)]
            if f >= 0 {
                let len = f & 15
                bitBuf >>= UInt64(len)
                bitCount -= len
                return f >> 4
            }
            // Slow canonical decode for long codes.
            var code = 0, first = 0, index = 0
            for len in 1...15 {
                code |= Int(bitBuf & 1)
                bitBuf >>= 1
                bitCount -= 1
                let c = h.count[len]
                if code - c < first { return h.symbol[index + (code - first)] }
                index += c
                first += c
                first <<= 1
                code <<= 1
            }
            throw InflateError.invalidCode
        }
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    static let fixedLit: Huffman = {
        var l = [Int](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        return Huffman(lengths: l)
    }()
    static let fixedDist = Huffman(lengths: [Int](repeating: 5, count: 30))

    public static func swiftInflate(_ data: Data, sizeHint: Int? = nil) throws -> Data {
        var r = BitReader([UInt8](data))
        var out: [UInt8] = []
        out.reserveCapacity(sizeHint ?? data.count * 4)
        var last = false
        while !last {
            last = try r.bits(1) == 1
            let type = try r.bits(2)
            switch type {
            case 0:
                r.alignToByte()
                let len = try r.bits(16)
                let nlen = try r.bits(16)
                guard len == (~nlen & 0xFFFF) else { throw InflateError.invalidStoredLength }
                for _ in 0..<len { out.append(UInt8(try r.bits(8))) }
            case 1:
                try codes(&r, &out, fixedLit, fixedDist)
            case 2:
                let hlit = try r.bits(5) + 257
                let hdist = try r.bits(5) + 1
                let hclen = try r.bits(4) + 4
                let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
                var cl = [Int](repeating: 0, count: 19)
                for i in 0..<hclen { cl[order[i]] = try r.bits(3) }
                let clh = Huffman(lengths: cl)
                var lengths: [Int] = []
                while lengths.count < hlit + hdist {
                    let sym = try r.decode(clh)
                    switch sym {
                    case 0..<16: lengths.append(sym)
                    case 16:
                        guard let prev = lengths.last else { throw InflateError.invalidCode }
                        lengths += [Int](repeating: prev, count: 3 + (try r.bits(2)))
                    case 17: lengths += [Int](repeating: 0, count: 3 + (try r.bits(3)))
                    default: lengths += [Int](repeating: 0, count: 11 + (try r.bits(7)))
                    }
                }
                guard lengths.count == hlit + hdist else { throw InflateError.invalidCode }
                try codes(&r, &out, Huffman(lengths: Array(lengths[0..<hlit])), Huffman(lengths: Array(lengths[hlit...])))
            default:
                throw InflateError.invalidBlockType
            }
        }
        return Data(out)
    }

    static func codes(_ r: inout BitReader, _ out: inout [UInt8], _ lit: Huffman, _ dist: Huffman) throws {
        while true {
            let sym = try r.decode(lit)
            if sym < 256 {
                out.append(UInt8(sym))
            } else if sym == 256 {
                return
            } else {
                let li = sym - 257
                guard li < 29 else { throw InflateError.invalidCode }
                let len = lengthBase[li] + (try r.bits(lengthExtra[li]))
                let ds = try r.decode(dist)
                guard ds < 30 else { throw InflateError.invalidDistance }
                let d = distBase[ds] + (try r.bits(distExtra[ds]))
                guard d <= out.count else { throw InflateError.invalidDistance }
                let start = out.count - d
                if d >= len {
                    out.append(contentsOf: out[start..<(start + len)])
                } else {
                    for i in 0..<len { out.append(out[start + i]) }
                }
            }
        }
    }
}
