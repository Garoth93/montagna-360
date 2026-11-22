import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum TrackFileFormat: String, Sendable {
    case gpx, tcx, fit

    /// From a file name, ignoring a trailing ".gz".
    public init?(fileName: String) {
        var n = fileName.lowercased()
        if n.hasSuffix(".gz") { n = String(n.dropLast(3)) }
        if n.hasSuffix(".gpx") { self = .gpx } else if n.hasSuffix(".tcx") { self = .tcx } else if n.hasSuffix(".fit") { self = .fit } else { return nil }
    }
}

public enum TrackFileError: Error, Equatable, LocalizedError {
    case unknownFormat
    case invalid(String)
    case noPoints

    public var errorDescription: String? {
        switch self {
        case .unknownFormat: return "Formato non riconosciuto (servono file GPX, TCX o FIT)."
        case .invalid(let s): return "File non valido: \(s)"
        case .noPoints: return "Il file non contiene punti GPS."
        }
    }
}

/// What a track file says besides the points.
public struct ParsedTrack: Sendable {
    public var track: Track
    public var name: String?
    public var sport: String?

    public init(track: Track, name: String? = nil, sport: String? = nil) {
        self.track = track
        self.name = name
        self.sport = sport
    }
}

public enum TrackFileParser {
    /// Parses GPX / TCX / FIT data (gzip-compressed or not).
    public static func parse(_ data: Data, fileName: String) throws -> ParsedTrack {
        let raw = Inflate.isGzip(data) ? try Inflate.gunzip(data) : data
        let format = TrackFileFormat(fileName: fileName) ?? sniff(raw)
        guard let format else { throw TrackFileError.unknownFormat }
        let parsed: ParsedTrack
        switch format {
        case .gpx, .tcx: parsed = try XMLTrackParser.parse(raw)
        case .fit: parsed = try FITParser.parse(raw)
        }
        guard !parsed.track.isEmpty else { throw TrackFileError.noPoints }
        return parsed
    }

    static func sniff(_ d: Data) -> TrackFileFormat? {
        if d.count > 12, d[d.startIndex + 8] == 0x2E, d[d.startIndex + 9] == 0x46, d[d.startIndex + 10] == 0x49, d[d.startIndex + 11] == 0x54 { return .fit }
        let head = String(decoding: d.prefix(2048), as: UTF8.self)
        if head.contains("<gpx") { return .gpx }
        if head.contains("TrainingCenterDatabase") { return .tcx }
        return nil
    }
}

/// GPX and TCX share one SAX parser: both are lists of points with
/// lat/lon, elevation and time, under different tag names.
final class XMLTrackParser: NSObject, XMLParserDelegate {
    private var points: [TrackPoint] = []
    private var current: TrackPoint?
    private var text = ""
    private var name: String?
    private var trackNamed = false
    private var sport: String?
    private var path: [String] = []
    private var tcxLat: Double?
    private var tcxLon: Double?

    static func parse(_ data: Data) throws -> ParsedTrack {
        let delegate = XMLTrackParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        if !parser.parse(), delegate.points.isEmpty {
            throw TrackFileError.invalid(parser.parserError?.localizedDescription ?? "XML")
        }
        return ParsedTrack(track: Track(points: delegate.points), name: delegate.name, sport: delegate.sport)
    }

    private func local(_ n: String) -> String {
        if let i = n.lastIndex(of: ":") { return String(n[n.index(after: i)...]) }
        return n
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let n = local(elementName)
        path.append(n)
        text = ""
        switch n {
        case "trkpt", "rtept":
            if let la = attributes["lat"].flatMap(Double.init), let lo = attributes["lon"].flatMap(Double.init) {
                current = TrackPoint(lat: la, lon: lo)
            }
        case "Trackpoint":
            current = TrackPoint(lat: .nan, lon: .nan)
            tcxLat = nil; tcxLon = nil
        case "Activity":
            if let s = attributes["Sport"] { sport = s }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let n = local(elementName)
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { _ = path.popLast(); text = "" }
        switch n {
        case "ele", "AltitudeMeters":
            if current != nil { current?.ele = Double(t) }
        case "time", "Time":
            if current != nil { current?.time = ISOTime.parse(t) }
        case "speed":
            if current != nil { current?.speed = Double(t) }
        case "hr":
            if current != nil { current?.heartRate = Int(t) }
        case "Value":
            if path.dropLast().last == "HeartRateBpm", current != nil { current?.heartRate = Int(t) }
        case "LatitudeDegrees": tcxLat = Double(t)
        case "LongitudeDegrees": tcxLon = Double(t)
        case "name":
            if current == nil, !t.isEmpty {
                if path.dropLast().last == "trk", !trackNamed { name = t; trackNamed = true } else if name == nil { name = t }
            }
        case "type":
            if sport == nil, current == nil, path.contains("trk") { sport = t }
        case "trkpt", "rtept":
            if let c = current { points.append(c) }
            current = nil
        case "Trackpoint":
            if var c = current, let la = tcxLat, let lo = tcxLon {
                c.lat = la; c.lon = lo
                points.append(c)
            }
            current = nil
        default: break
        }
    }
}

/// ISO 8601 with or without fractional seconds and offset.
public enum ISOTime {
    public static func parse(_ s: String) -> Date? {
        // Fast manual path: yyyy-MM-ddTHH:mm:ss(.fff)(Z|±hh:mm)
        let b = Array(s.utf8)
        guard b.count >= 19 else { return nil }
        func num(_ i: Int, _ n: Int) -> Int? {
            var v = 0
            for k in i..<(i + n) {
                guard k < b.count, b[k] >= 48, b[k] <= 57 else { return nil }
                v = v * 10 + Int(b[k] - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2) else { return nil }
        var i = 19
        var frac = 0.0
        if i < b.count, b[i] == 46 { // "."
            var scale = 0.1
            i += 1
            while i < b.count, b[i] >= 48, b[i] <= 57 { frac += Double(b[i] - 48) * scale; scale /= 10; i += 1 }
        }
        var offset = 0
        if i < b.count, b[i] == 43 || b[i] == 45 { // + -
            let sign = b[i] == 45 ? -1 : 1
            if let oh = num(i + 1, 2) {
                let om = num(i + 4, 2) ?? num(i + 3, 2) ?? 0
                offset = sign * (oh * 3600 + om * 60)
            }
        }
        // Days from civil (Howard Hinnant).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let mp = (mo + 9) % 12
        let doy = (153 * mp + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let secs = Double(days * 86_400 + h * 3600 + mi * 60 + se - offset) + frac
        return Date(timeIntervalSince1970: secs)
    }
}
