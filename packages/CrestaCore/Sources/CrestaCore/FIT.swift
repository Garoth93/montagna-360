import Foundation

/// Minimal Garmin FIT decoder: reads `record` messages (position, altitude,
/// speed, heart rate, time) and the sport of `session`/`sport` messages.
public enum FITParser {
    struct FieldDef { let num: UInt8; let size: Int; let baseType: UInt8 }
    struct MessageDef { let global: UInt16; let bigEndian: Bool; let fields: [FieldDef]; let devSize: Int }

    static let fitEpoch: TimeInterval = 631_065_600 // 1989-12-31T00:00:00Z
    static let semicircle = 180.0 / 2_147_483_648.0

    public static func parse(_ data: Data) throws -> ParsedTrack {
        let b = [UInt8](data)
        guard b.count >= 12 else { throw TrackFileError.invalid("FIT troppo corto") }
        let headerSize = Int(b[0])
        guard headerSize >= 12, b.count > headerSize, b[8] == 0x2E, b[9] == 0x46, b[10] == 0x49, b[11] == 0x54 else {
            throw TrackFileError.invalid("intestazione FIT")
        }
        let dataSize = Int(b[4]) | Int(b[5]) << 8 | Int(b[6]) << 16 | Int(b[7]) << 24
        let end = min(b.count, headerSize + dataSize)
        var p = headerSize
        var defs: [UInt8: MessageDef] = [:]
        var points: [TrackPoint] = []
        var sport: String?
        var lastTimestamp: UInt32 = 0

        func read(_ off: Int, _ size: Int, _ big: Bool) -> UInt64 {
            var v: UInt64 = 0
            for k in 0..<size {
                let byte = UInt64(b[off + k])
                v |= big ? byte << UInt64(8 * (size - 1 - k)) : byte << UInt64(8 * k)
            }
            return v
        }

        while p < end {
            let header = b[p]
            p += 1
            if header & 0x80 != 0 {
                // Compressed timestamp header.
                let local = (header >> 5) & 0x03
                let offset = UInt32(header & 0x1F)
                var ts = (lastTimestamp & 0xFFFF_FFE0) | offset
                if ts < lastTimestamp { ts += 0x20 }
                lastTimestamp = ts
                guard let def = defs[local] else { throw TrackFileError.invalid("definizione mancante") }
                let size = def.fields.reduce(0) { $0 + $1.size } + def.devSize
                guard p + size <= end else { break }
                if def.global == 20, var pt = record(b, p, def, read) { pt.time = Date(timeIntervalSince1970: fitEpoch + Double(ts)); points.append(pt) }
                p += size
                continue
            }
            let local = header & 0x0F
            if header & 0x40 != 0 {
                // Definition message.
                guard p + 5 <= end else { break }
                let big = b[p + 1] == 1
                let global = UInt16(read(p + 2, 2, big))
                let n = Int(b[p + 4])
                p += 5
                var fields: [FieldDef] = []
                for _ in 0..<n {
                    guard p + 3 <= end else { break }
                    fields.append(FieldDef(num: b[p], size: Int(b[p + 1]), baseType: b[p + 2]))
                    p += 3
                }
                var devSize = 0
                if header & 0x20 != 0, p < end {
                    let nd = Int(b[p]); p += 1
                    for _ in 0..<nd { if p + 3 <= end { devSize += Int(b[p + 1]) }; p += 3 }
                }
                defs[local] = MessageDef(global: global, bigEndian: big, fields: fields, devSize: devSize)
            } else {
                guard let def = defs[local] else { throw TrackFileError.invalid("definizione mancante") }
                let size = def.fields.reduce(0) { $0 + $1.size } + def.devSize
                guard p + size <= end else { break }
                // Timestamp (field 253) is common to all messages.
                var off = p
                for f in def.fields {
                    if f.num == 253, f.size == 4 {
                        let ts = UInt32(read(off, 4, def.bigEndian))
                        if ts != 0xFFFF_FFFF { lastTimestamp = ts }
                    }
                    off += f.size
                }
                if def.global == 20 {
                    if let pt = record(b, p, def, read) { points.append(pt) }
                } else if def.global == 18 || def.global == 12 {
                    var o = p
                    for f in def.fields {
                        if f.num == 5, f.size == 1, b[o] != 0xFF, sport == nil { sport = sportName(b[o]) }
                        o += f.size
                    }
                }
                p += size
            }
        }
        return ParsedTrack(track: Track(points: points), name: nil, sport: sport)
    }

    static func record(_ b: [UInt8], _ start: Int, _ def: MessageDef, _ read: (Int, Int, Bool) -> UInt64) -> TrackPoint? {
        var lat: Double?, lon: Double?, ele: Double?, time: Date?, speed: Double?, hr: Int?
        var off = start
        for f in def.fields {
            let v = read(off, f.size, def.bigEndian)
            switch (f.num, f.size) {
            case (253, 4): if v != 0xFFFF_FFFF { time = Date(timeIntervalSince1970: fitEpoch + Double(v)) }
            case (0, 4): if v != 0x7FFF_FFFF { lat = Double(Int32(bitPattern: UInt32(v))) * semicircle }
            case (1, 4): if v != 0x7FFF_FFFF { lon = Double(Int32(bitPattern: UInt32(v))) * semicircle }
            case (2, 2): if v != 0xFFFF, ele == nil { ele = Double(v) / 5 - 500 }
            case (78, 4): if v != 0xFFFF_FFFF { ele = Double(v) / 5 - 500 }
            case (6, 2): if v != 0xFFFF, speed == nil { speed = Double(v) / 1000 }
            case (73, 4): if v != 0xFFFF_FFFF { speed = Double(v) / 1000 }
            case (3, 1): if v != 0xFF { hr = Int(v) }
            default: break
            }
            off += f.size
        }
        guard let lat, let lon else { return nil }
        return TrackPoint(lat: lat, lon: lon, ele: ele, time: time, speed: speed, heartRate: hr)
    }

    /// FIT `sport` enum values that matter here.
    static func sportName(_ v: UInt8) -> String {
        switch v {
        case 1: return "Run"
        case 2: return "Ride"
        case 11: return "Walk"
        case 12: return "NordicSki"
        case 13: return "AlpineSki"
        case 14: return "Snowboard"
        case 17: return "Hike"
        case 31: return "RockClimbing"
        case 35: return "Snowshoe"
        default: return "Other"
        }
    }

    /// Builds a FIT file (definition + records), used by tests to produce
    /// synthetic input.
    public static func encode(points: [TrackPoint], sport: UInt8? = nil) -> Data {
        var body = Data()
        // Definition: local 0, global 20 (record), little endian.
        body.append(0x40); body.append(0); body.append(0); body.le16(20); body.append(5)
        for (num, size, type) in [(253, 4, 0x86), (0, 4, 0x85), (1, 4, 0x85), (2, 2, 0x84), (6, 2, 0x84)] as [(UInt8, UInt8, UInt8)] {
            body.append(num); body.append(size); body.append(type)
        }
        for pt in points {
            body.append(0x00)
            let ts = UInt32(max(0, (pt.time?.timeIntervalSince1970 ?? fitEpoch) - fitEpoch))
            body.le32(ts)
            body.le32(UInt32(bitPattern: Int32(pt.lat / semicircle)))
            body.le32(UInt32(bitPattern: Int32(pt.lon / semicircle)))
            body.le16(pt.ele.map { UInt16(max(0, ($0 + 500) * 5)) } ?? 0xFFFF)
            body.le16(pt.speed.map { UInt16(max(0, $0 * 1000)) } ?? 0xFFFF)
        }
        if let sport {
            body.append(0x41); body.append(0); body.append(0); body.le16(18); body.append(1)
            body.append(5); body.append(1); body.append(0)
            body.append(0x01); body.append(sport)
        }
        var d = Data([14, 0x10, 0x00, 0x08])
        d.le32(UInt32(body.count))
        d.append(contentsOf: Array(".FIT".utf8))
        d.le16(0)
        d.append(body)
        d.le16(0)
        return d
    }
}
