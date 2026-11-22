import Foundation

/// Type of outing. Strava's many sport types map onto these.
public enum ActivityKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case resortSki, skiTouring, nordicSki, snowboard, snowshoe
    case hike, ferrata, climbing, trailRun, run, bike, mtb, walk, other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .resortSki: return "Sci in pista"
        case .skiTouring: return "Scialpinismo"
        case .nordicSki: return "Sci di fondo"
        case .snowboard: return "Snowboard"
        case .snowshoe: return "Ciaspole"
        case .hike: return "Escursione"
        case .ferrata: return "Ferrata"
        case .climbing: return "Arrampicata"
        case .trailRun: return "Trail running"
        case .run: return "Corsa"
        case .bike: return "Bici"
        case .mtb: return "Mountain bike"
        case .walk: return "Camminata"
        case .other: return "Altro"
        }
    }

    /// SF Symbol name.
    public var icon: String {
        switch self {
        case .resortSki: return "figure.skiing.downhill"
        case .skiTouring: return "figure.skiing.crosscountry"
        case .nordicSki: return "figure.skiing.crosscountry"
        case .snowboard: return "figure.snowboarding"
        case .snowshoe: return "snowflake"
        case .hike: return "figure.hiking"
        case .ferrata: return "figure.climbing"
        case .climbing: return "figure.climbing"
        case .trailRun: return "figure.run"
        case .run: return "figure.run"
        case .bike: return "figure.outdoor.cycle"
        case .mtb: return "bicycle"
        case .walk: return "figure.walk"
        case .other: return "mountain.2.fill"
        }
    }

    /// Hex seed for the kind's tonal colors.
    public var colorHex: String {
        switch self {
        case .resortSki, .snowboard: return "#1e88e5"
        case .skiTouring, .nordicSki: return "#3949ab"
        case .snowshoe: return "#00acc1"
        case .hike, .walk: return "#43a047"
        case .ferrata, .climbing: return "#8d6e63"
        case .trailRun, .run: return "#f4511e"
        case .bike, .mtb: return "#fb8c00"
        case .other: return "#757575"
        }
    }

    public var isSnow: Bool { [.resortSki, .skiTouring, .nordicSki, .snowboard, .snowshoe].contains(self) }
    public var usesSkiGear: Bool { [.resortSki, .skiTouring, .nordicSki, .snowboard].contains(self) }

    /// Mode used for the summit stamp.
    public var summitMode: SummitMode {
        switch self {
        case .resortSki, .skiTouring, .nordicSki, .snowboard: return .ski
        case .snowshoe: return .snowshoe
        case .bike, .mtb: return .bike
        default: return .foot
        }
    }

    /// Strava `sport_type` / `type` (API, English) and activity type names in
    /// the export CSV (English or Italian).
    public static func fromStrava(_ raw: String) -> ActivityKind? {
        let key = raw.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "")
        switch key {
        case "alpineski", "sciinpista", "scialpino", "sci": return .resortSki
        case "backcountryski", "scialpinismo", "sciescursionismo", "scidaescursionismo": return .skiTouring
        case "nordicski", "scidifondo", "rollerski", "skiroll": return .nordicSki
        case "snowboard": return .snowboard
        case "snowshoe", "ciaspole", "racchettedaneve", "ciaspolata": return .snowshoe
        case "hike", "escursione", "escursionismo": return .hike
        case "rockclimbing", "arrampicata", "climbing": return .climbing
        case "trailrun", "trailrunning", "corsasusentiero", "corsainmontagna": return .trailRun
        case "run", "corsa", "virtualrun": return .run
        case "ride", "giroinbici", "ciclismosustrada", "ciclismosustrada", "bicidacorsa", "bici", "ciclismo", "roadbike", "gravelride", "ebikeride", "virtualride", "velomobile", "pedalata": return .bike
        case "mountainbikeride", "emountainbikeride", "mountainbike", "mtb": return .mtb
        case "walk", "camminata", "passeggiata": return .walk
        case "workout", "allenamentogenerico", "allenamento": return .other
        default: return nil
        }
    }
}

/// How a summit was reached.
public enum SummitMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case foot, ski, snowshoe, bike

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .foot: return "A piedi"
        case .ski: return "Sci"
        case .snowshoe: return "Ciaspole"
        case .bike: return "Bici"
        }
    }

    public var icon: String {
        switch self {
        case .foot: return "figure.hiking"
        case .ski: return "figure.skiing.crosscountry"
        case .snowshoe: return "snowflake"
        case .bike: return "bicycle"
        }
    }
}

/// Suggests the kind of an outing from its track, speed and date, when the
/// source does not say (GPX) or says something generic.
public enum ModeClassifier {
    public struct Suggestion: Equatable, Sendable {
        public var kind: ActivityKind
        /// 0…1, how sure the rules are.
        public var confidence: Double
        public var reason: String
    }

    public static func suggest(stats s: TrackStats, start: Date?, hint: ActivityKind? = nil,
                               calendar: Calendar = .current) -> Suggestion {
        let snowSeason = start.map { Season.isWinter(date: $0, calendar: calendar) } ?? false
        let avgKmh = s.averageMovingSpeed * 3.6
        let upKmh = s.ascentSpeed * 3.6
        let downKmh = s.descentSpeed * 3.6
        let maxKmh = s.maxSpeed * 3.6

        // Resort skiing: several lift rides, fast runs.
        if s.liftRides >= 2 && s.runs >= 2 && downKmh > 12 && downKmh > 1.5 * upKmh && (snowSeason || hint?.isSnow == true) {
            return Suggestion(kind: hint == .snowboard ? .snowboard : .resortSki, confidence: 0.9,
                              reason: "\(s.liftRides) risalite veloci e \(s.runs) discese")
        }
        // Bike: fast also uphill.
        if upKmh > 7 && avgKmh > 11 && (maxKmh > 30 || avgKmh > 16) && !(snowSeason && downKmh > 3 * max(upKmh, 1)) {
            let kind: ActivityKind = hint == .mtb ? .mtb : (hint == .bike ? .bike : (s.ascent > 600 ? .mtb : .bike))
            return Suggestion(kind: kind, confidence: 0.8, reason: "veloce anche in salita (\(Int(upKmh)) km/h)")
        }
        if snowSeason || hint?.isSnow == true {
            // Ski touring: slow up, much faster down.
            if s.ascent > 250 && downKmh > 10 && downKmh > 2.5 * max(upKmh, 0.5) {
                return Suggestion(kind: .skiTouring, confidence: 0.8, reason: "salita lenta e discesa veloce")
            }
            if s.ascent < 150 && avgKmh > 7 && avgKmh < 25 && s.distance > 5000 {
                return Suggestion(kind: .nordicSki, confidence: 0.5, reason: "tanta distanza in piano, passo regolare")
            }
            // Snowshoes only in the mountains: a winter walk in town is a walk.
            if avgKmh < 6 && downKmh < 7 && (s.ascent > 150 || (s.maxElevation ?? 0) > 1000) {
                return Suggestion(kind: .snowshoe, confidence: hint == .snowshoe ? 0.9 : 0.55, reason: "stagione invernale, andatura lenta anche in discesa")
            }
        }
        if let hint, hint != .other { return Suggestion(kind: hint, confidence: 0.7, reason: "tipo indicato dalla fonte") }
        if avgKmh > 7.5 && maxKmh < 30 {
            return Suggestion(kind: s.ascent > 300 ? .trailRun : .run, confidence: 0.6, reason: "passo di corsa (\(Int(avgKmh)) km/h)")
        }
        if s.ascent > 200 || (s.maxElevation ?? 0) > 1200 {
            return Suggestion(kind: .hike, confidence: 0.6, reason: "andatura a piedi con dislivello")
        }
        return Suggestion(kind: .walk, confidence: 0.4, reason: "andatura a piedi")
    }
}
