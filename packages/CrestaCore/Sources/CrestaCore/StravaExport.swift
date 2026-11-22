import Foundation

/// RFC 4180 CSV (quoted fields with commas, quotes and newlines).
public enum CSV {
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var it = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?
        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return it.next()
        }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = it.next() {
                        if n == "\"" { field.unicodeScalars.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n":
                    row.append(field); field = ""
                    rows.append(row); row = []
                case "\r": break
                default: field.unicodeScalars.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}

/// One row of `activities.csv`.
public struct StravaExportActivity: Equatable, Sendable, Identifiable {
    public var activityID: Int64
    public var date: Date?
    public var name: String
    public var type: String
    public var kind: ActivityKind?
    public var description: String
    public var elapsed: TimeInterval?
    public var moving: TimeInterval?
    /// Meters.
    public var distance: Double?
    public var ascent: Double?
    public var maxSpeed: Double?
    /// Path inside the ZIP (e.g. "activities/123.gpx.gz"), empty if none.
    public var fileName: String

    public var id: Int64 { activityID }
    public var hasFile: Bool { !fileName.isEmpty }
}

public enum StravaCSV {
    /// Parses `activities.csv`. Columns are looked up by name (first
    /// occurrence: Strava repeats some names with different units).
    public static func activities(_ text: String) -> [StravaExportActivity] {
        let rows = CSV.parse(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard let header = rows.first else { return [] }
        var col: [String: Int] = [:]
        var allCols: [String: [Int]] = [:]
        for (i, h) in header.enumerated() {
            let k = h.trimmingCharacters(in: .whitespaces).lowercased()
            if col[k] == nil { col[k] = i }
            allCols[k, default: []].append(i)
        }
        func idx(_ names: [String]) -> Int? { names.lazy.compactMap { col[$0] }.first }
        let iID = idx(["activity id", "id attività", "id"])
        let iDate = idx(["activity date", "data attività", "data dell'attività"])
        let iName = idx(["activity name", "nome attività", "nome dell'attività"])
        let iType = idx(["activity type", "tipo attività", "tipo di attività"])
        let iDesc = idx(["activity description", "descrizione attività"])
        let iElapsed = idx(["elapsed time", "tempo trascorso"])
        let iFile = idx(["filename", "nome file"])
        // Second "Distance"/"Elapsed Time" columns are in meters/seconds.
        let iDistM = allCols["distance"].flatMap { $0.count > 1 ? $0[1] : nil }
        let iDistKm = idx(["distance", "distanza"])
        let iMoving = idx(["moving time", "tempo in movimento"])
        let iGain = idx(["elevation gain", "dislivello positivo"])
        let iMax = idx(["max speed", "velocità max", "velocità massima"])

        var out: [StravaExportActivity] = []
        for r in rows.dropFirst() {
            func v(_ i: Int?) -> String { i.flatMap { $0 < r.count ? r[$0] : nil }?.trimmingCharacters(in: .whitespaces) ?? "" }
            guard let id = Int64(v(iID)) else { continue }
            let type = v(iType)
            var dist: Double?
            if let m = number(v(iDistM)) { dist = m } else if let km = number(v(iDistKm)) { dist = km * 1000 }
            out.append(StravaExportActivity(
                activityID: id, date: date(v(iDate)), name: v(iName), type: type, kind: ActivityKind.fromStrava(type),
                description: v(iDesc), elapsed: number(v(iElapsed)), moving: number(v(iMoving)), distance: dist,
                ascent: number(v(iGain)), maxSpeed: number(v(iMax)), fileName: v(iFile)))
        }
        return out
    }

    static func number(_ s: String) -> Double? {
        guard !s.isEmpty else { return nil }
        if let d = Double(s) { return d }
        return Double(s.replacingOccurrences(of: ",", with: "."))
    }

    /// Strava export dates are UTC, English ("Dec 1, 2019, 9:13:11 AM") or
    /// localized ("1 dic 2019, 09:13:11").
    public static func date(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let formats = ["MMM d, yyyy, h:mm:ss a", "MMM d, yyyy, HH:mm:ss", "d MMM yyyy, HH:mm:ss", "d MMM yyyy, H:mm:ss",
                       "yyyy-MM-dd HH:mm:ss", "dd/MM/yyyy, HH:mm:ss", "d MMMM yyyy, HH:mm:ss"]
        let locales = [Locale(identifier: "en_US_POSIX"), Locale(identifier: "it_IT")]
        let cleaned = s.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
        for loc in locales {
            for f in formats {
                let df = DateFormatter()
                df.locale = loc
                df.timeZone = TimeZone(identifier: "UTC")
                df.dateFormat = f
                if let d = df.date(from: cleaned) { return d }
            }
        }
        return ISOTime.parse(s)
    }
}

/// Preview of an export before importing.
public struct ExportPreview: Sendable {
    public var activities: [StravaExportActivity]
    /// Activity IDs that are already in the diary.
    public var duplicates: Set<Int64>
    public var countsByKind: [ActivityKind?: Int]

    public func selection(kinds: Set<ActivityKind>, includeOther: Bool, skipDuplicates: Bool = true) -> [StravaExportActivity] {
        activities.filter { a in
            if skipDuplicates && duplicates.contains(a.activityID) { return false }
            if let k = a.kind { return kinds.contains(k) }
            return includeOther
        }
    }
}

public enum DuplicateDetector {
    /// Same Strava ID, or same start (±3 min) and similar distance (±10 %).
    public static func isDuplicate(stravaID: Int64?, start: Date?, distance: Double?, in outings: [Outing]) -> Bool {
        if let sid = stravaID, outings.contains(where: { $0.stravaID == sid }) { return true }
        guard let start else { return false }
        return outings.contains { o in
            guard abs(o.start.timeIntervalSince(start)) <= 180 else { return false }
            guard let d = distance, d > 0, o.stats.distance > 0 else { return true }
            return abs(o.stats.distance - d) / max(d, o.stats.distance) <= 0.1
        }
    }
}

/// Builds outings from parsed tracks (shared by export, single file and API).
public enum OutingBuilder {
    public static func build(parsed: ParsedTrack?, name: String?, sport: String?, start: Date?, source: OutingSource,
                             stravaID: Int64? = nil, fallback: TrackStats? = nil, description: String = "",
                             gear: [GearItem] = [], calendar: Calendar = .current) -> (outing: Outing, track: Track?)? {
        let track = parsed?.track
        var stats = track.map(TrackStats.compute) ?? TrackStats()
        if let f = fallback {
            if stats.distance == 0 { stats.distance = f.distance }
            if stats.ascent == 0 { stats.ascent = f.ascent }
            if stats.elapsed == 0 { stats.elapsed = f.elapsed }
            if stats.moving == 0 { stats.moving = f.moving }
            if stats.maxSpeed == 0 { stats.maxSpeed = f.maxSpeed }
        }
        guard let startDate = track?.start ?? start else { return nil }
        let hint = (sport ?? parsed?.sport).flatMap(ActivityKind.fromStrava)
        let suggestion = ModeClassifier.suggest(stats: stats, start: startDate, hint: hint, calendar: calendar)
        // Trust explicit specific types from the source; the classifier refines
        // generic ones (GPX without type, "Walk" in winter → snowshoe…).
        let kind: ActivityKind
        if let hint, hint != .walk, hint != .other, hint != .hike || !suggestion.kind.isSnow { kind = hint } else { kind = suggestion.kind }
        let simplified = track?.simplified(tolerance: 3)
        let preview = (simplified ?? Track(points: [])).thinned(maxPoints: 200).coordinates
        let title = (name?.isEmpty == false ? name! : parsed?.name) ?? defaultName(kind: kind, date: startDate, calendar: calendar)
        let outing = Outing(name: title, kind: kind, suggestedKind: suggestion.kind, start: startDate, stats: stats,
                            hasTrack: track?.isEmpty == false, preview: preview, startCoordinate: track?.points.first?.coordinate,
                            source: source, stravaID: stravaID, note: description,
                            gearIDs: GarageLogic.defaultGear(for: kind, gear: gear))
        return (outing, simplified)
    }

    public static func defaultName(kind: ActivityKind, date: Date, calendar: Calendar = .current) -> String {
        let h = calendar.component(.hour, from: date)
        let part = h < 12 ? "mattutina" : h < 18 ? "pomeridiana" : "serale"
        switch kind {
        case .resortSki: return "Giornata sugli sci"
        case .skiTouring: return "Gita scialpinistica"
        case .snowshoe: return "Ciaspolata \(part)"
        case .hike: return "Escursione \(part)"
        case .run, .trailRun: return "Corsa \(part)"
        case .bike, .mtb: return "Giro in bici"
        default: return "\(kind.title) \(part)"
        }
    }
}

/// Reads a Strava "Download your data" ZIP: preview, then import with
/// progress, one activity at a time.
public final class StravaExportReader {
    public let archive: ZipArchive
    public let activities: [StravaExportActivity]

    public init(url: URL) throws {
        archive = try ZipArchive(url: url)
        guard let csvEntry = archive.entry(path: "activities.csv") else {
            throw TrackFileError.invalid("activities.csv non trovato: è l'archivio esportato da Strava?")
        }
        let data = try archive.data(for: csvEntry)
        activities = StravaCSV.activities(String(decoding: data, as: UTF8.self))
    }

    public func preview(existing: [Outing]) -> ExportPreview {
        var dups = Set<Int64>()
        let ids = Set(existing.compactMap(\.stravaID))
        for a in activities {
            if ids.contains(a.activityID) || DuplicateDetector.isDuplicate(stravaID: nil, start: a.date, distance: a.distance, in: existing) {
                dups.insert(a.activityID)
            }
        }
        var counts: [ActivityKind?: Int] = [:]
        for a in activities { counts[a.kind, default: 0] += 1 }
        return ExportPreview(activities: activities, duplicates: dups, countsByKind: counts)
    }

    /// Reads and parses the track file of one activity (nil if it has none).
    public func track(for a: StravaExportActivity) throws -> ParsedTrack? {
        guard a.hasFile, let e = archive.entry(path: a.fileName) else { return nil }
        return try TrackFileParser.parse(try archive.data(for: e), fileName: a.fileName)
    }

    /// Outing for one activity. Activities without GPS file are kept with
    /// the numbers of the CSV.
    public func outing(for a: StravaExportActivity, gear: [GearItem] = []) -> (outing: Outing, track: Track?)? {
        let parsed = try? track(for: a)
        let fallback = TrackStats(distance: a.distance ?? 0, ascent: a.ascent ?? 0, elapsed: a.elapsed ?? 0,
                                  moving: a.moving ?? a.elapsed ?? 0, maxSpeed: a.maxSpeed ?? 0)
        return OutingBuilder.build(parsed: parsed, name: a.name, sport: a.type, start: a.date, source: .stravaExport,
                                   stravaID: a.activityID, fallback: fallback, description: a.description, gear: gear)
    }
}
