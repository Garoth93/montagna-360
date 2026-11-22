import Foundation

public enum ZipError: Error, Equatable {
    case notAZip
    case corrupted(String)
    case unsupportedCompression(UInt16)
    case encrypted
}

public struct ZipEntry: Equatable, Sendable {
    public let name: String
    public let compressedSize: Int
    public let size: Int
    public let method: UInt16
    let localHeaderOffset: Int
    let flags: UInt16

    public var isDirectory: Bool { name.hasSuffix("/") }
}

/// Reads ZIP archives (stored and deflated entries, ZIP64) one entry at a
/// time, without loading the archive in memory: Strava exports can be
/// several GB.
public final class ZipArchive {
    public let entries: [ZipEntry]
    private let handle: FileHandle
    public let url: URL

    public init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        let size = Int(try handle.seekToEnd())
        guard size >= 22 else { throw ZipError.notAZip }
        let tail = min(size, 65_535 + 22 + 20)
        try handle.seek(toOffset: UInt64(size - tail))
        let buf = [UInt8](try handle.read(upToCount: tail) ?? Data())
        guard let eocd = stride(from: buf.count - 22, through: 0, by: -1).first(where: { buf.le32($0) == 0x0605_4B50 }) else {
            throw ZipError.notAZip
        }
        var total = Int(buf.le16(eocd + 10))
        var cdSize = Int(buf.le32(eocd + 12))
        var cdOffset = Int(buf.le32(eocd + 16))
        // ZIP64 end of central directory locator just before the EOCD.
        if eocd >= 20, buf.le32(eocd - 20) == 0x0706_4B50 {
            let z64Offset = Int(buf.le64(eocd - 20 + 8))
            try handle.seek(toOffset: UInt64(z64Offset))
            let z = [UInt8](try handle.read(upToCount: 56) ?? Data())
            if z.count >= 56, z.le32(0) == 0x0606_4B50 {
                total = Int(z.le64(32))
                cdSize = Int(z.le64(40))
                cdOffset = Int(z.le64(48))
            }
        }
        guard cdOffset + cdSize <= size else { throw ZipError.corrupted("central directory") }
        try handle.seek(toOffset: UInt64(cdOffset))
        let cd = [UInt8](try handle.read(upToCount: cdSize) ?? Data())
        var list: [ZipEntry] = []
        list.reserveCapacity(total)
        var p = 0
        while p + 46 <= cd.count, cd.le32(p) == 0x0201_4B50 {
            let flags = cd.le16(p + 8)
            let method = cd.le16(p + 10)
            var csize = Int(cd.le32(p + 20))
            var usize = Int(cd.le32(p + 24))
            let nlen = Int(cd.le16(p + 28)), xlen = Int(cd.le16(p + 30)), clen = Int(cd.le16(p + 32))
            var local = Int(cd.le32(p + 42))
            guard p + 46 + nlen + xlen <= cd.count else { throw ZipError.corrupted("entry") }
            let name = String(decoding: cd[(p + 46)..<(p + 46 + nlen)], as: UTF8.self)
            // ZIP64 extra field.
            var x = p + 46 + nlen
            let xEnd = x + xlen
            while x + 4 <= xEnd {
                let id = cd.le16(x), len = Int(cd.le16(x + 2))
                if id == 1 {
                    var q = x + 4
                    if usize == 0xFFFF_FFFF, q + 8 <= x + 4 + len { usize = Int(cd.le64(q)); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= x + 4 + len { csize = Int(cd.le64(q)); q += 8 }
                    if local == 0xFFFF_FFFF, q + 8 <= x + 4 + len { local = Int(cd.le64(q)) }
                }
                x += 4 + len
            }
            list.append(ZipEntry(name: name, compressedSize: csize, size: usize, method: method, localHeaderOffset: local, flags: flags))
            p += 46 + nlen + xlen + clen
        }
        entries = list
    }

    deinit { try? handle.close() }

    public func entry(named name: String) -> ZipEntry? { entries.first { $0.name == name } }

    /// Entry by path relative to the archive root, ignoring a leading folder
    /// (some unzip/rezip tools add one).
    public func entry(path: String) -> ZipEntry? {
        if let e = entry(named: path) { return e }
        return entries.first { $0.name.hasSuffix("/" + path) }
    }

    public func data(for entry: ZipEntry) throws -> Data {
        guard entry.flags & 1 == 0 else { throw ZipError.encrypted }
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset))
        let header = [UInt8](try handle.read(upToCount: 30) ?? Data())
        guard header.count == 30, header.le32(0) == 0x0403_4B50 else { throw ZipError.corrupted(entry.name) }
        let skip = Int(header.le16(26)) + Int(header.le16(28))
        try handle.seek(toOffset: UInt64(entry.localHeaderOffset + 30 + skip))
        let raw = try handle.read(upToCount: entry.compressedSize) ?? Data()
        guard raw.count == entry.compressedSize else { throw ZipError.corrupted(entry.name) }
        switch entry.method {
        case 0: return raw
        case 8: return try Inflate.inflate(raw, expectedSize: entry.size)
        default: throw ZipError.unsupportedCompression(entry.method)
        }
    }
}

/// Minimal ZIP writer (stored entries) for backups and test fixtures.
public final class ZipWriter {
    private var out = Data()
    private var central = Data()
    private var count = 0

    public init() {}

    public func add(_ data: Data, as name: String) {
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(data)
        let offset = out.count
        out.le32(0x0403_4B50); out.le16(20); out.le16(0x0800); out.le16(0); out.le16(0); out.le16(0x21)
        out.le32(crc); out.le32(UInt32(data.count)); out.le32(UInt32(data.count)); out.le16(UInt16(nameData.count)); out.le16(0)
        out.append(nameData); out.append(data)
        central.le32(0x0201_4B50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(0); central.le16(0); central.le16(0x21)
        central.le32(crc); central.le32(UInt32(data.count)); central.le32(UInt32(data.count)); central.le16(UInt16(nameData.count))
        central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(0); central.le32(UInt32(offset))
        central.append(nameData)
        count += 1
    }

    /// Adds already-deflated bytes (method 8), used by tests.
    public func addDeflated(_ compressed: Data, originalSize: Int, crc: UInt32, as name: String) {
        let nameData = Data(name.utf8)
        let offset = out.count
        out.le32(0x0403_4B50); out.le16(20); out.le16(0x0800); out.le16(8); out.le16(0); out.le16(0x21)
        out.le32(crc); out.le32(UInt32(compressed.count)); out.le32(UInt32(originalSize)); out.le16(UInt16(nameData.count)); out.le16(0)
        out.append(nameData); out.append(compressed)
        central.le32(0x0201_4B50); central.le16(20); central.le16(20); central.le16(0x0800); central.le16(8); central.le16(0); central.le16(0x21)
        central.le32(crc); central.le32(UInt32(compressed.count)); central.le32(UInt32(originalSize)); central.le16(UInt16(nameData.count))
        central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(0); central.le32(UInt32(offset))
        central.append(nameData)
        count += 1
    }

    public func finish() -> Data {
        var d = out
        let cdOffset = d.count
        d.append(central)
        d.le32(0x0605_4B50); d.le16(0); d.le16(0); d.le16(UInt16(count)); d.le16(UInt16(count))
        d.le32(UInt32(central.count)); d.le32(UInt32(cdOffset)); d.le16(0)
        return d
    }
}

public enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return ~c
    }
}

extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for i in 0..<4 { append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
}

extension Array where Element == UInt8 {
    func le16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func le32(_ i: Int) -> UInt32 { UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24 }
    func le64(_ i: Int) -> UInt64 { UInt64(le32(i)) | UInt64(le32(i + 4)) << 32 }
}
