import Foundation

public enum OutingSource: String, Codable, Sendable {
    case stravaExport, stravaAPI, file, manual, recorded

    public var title: String {
        switch self {
        case .stravaExport: return "Archivio Strava"
        case .stravaAPI: return "Strava"
        case .file: return "File"
        case .manual: return "Manuale"
        case .recorded: return "Registrata"
        }
    }
}

/// One outing (diary entry). The full track is stored separately
/// (`TrackStore`, one file per outing) to keep the main file small.
public struct Outing: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ActivityKind
    /// True when the user picked the kind by hand (automatic suggestions
    /// never overwrite it).
    public var kindIsManual: Bool
    public var suggestedKind: ActivityKind?
    public var start: Date
    public var stats: TrackStats
    public var hasTrack: Bool
    /// Small preview of the track for lists and maps (≤ 200 points).
    public var preview: [Coordinate]
    public var startCoordinate: Coordinate?
    public var source: OutingSource
    public var stravaID: Int64?
    public var weather: WeatherSnapshot?
    public var note: String
    public var photos: [String]
    public var gearIDs: [UUID]
    public var summitStampIDs: [UUID]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, kind: ActivityKind, kindIsManual: Bool = false, suggestedKind: ActivityKind? = nil,
                start: Date, stats: TrackStats, hasTrack: Bool, preview: [Coordinate] = [], startCoordinate: Coordinate? = nil,
                source: OutingSource, stravaID: Int64? = nil, weather: WeatherSnapshot? = nil, note: String = "",
                photos: [String] = [], gearIDs: [UUID] = [], summitStampIDs: [UUID] = [], createdAt: Date = Date()) {
        self.id = id; self.name = name; self.kind = kind; self.kindIsManual = kindIsManual; self.suggestedKind = suggestedKind
        self.start = start; self.stats = stats; self.hasTrack = hasTrack; self.preview = preview
        self.startCoordinate = startCoordinate; self.source = source; self.stravaID = stravaID; self.weather = weather
        self.note = note; self.photos = photos; self.gearIDs = gearIDs; self.summitStampIDs = summitStampIDs; self.createdAt = createdAt
    }

    public var end: Date { start.addingTimeInterval(stats.elapsed) }
    public var season: Season { Season.of(start) }
}

/// The "timbro": a summit reached on a given day.
public struct SummitStamp: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var peakID: String
    public var peakName: String
    public var elevation: Double?
    public var coordinate: Coordinate
    public var date: Date
    public var mode: SummitMode
    public var modeIsManual: Bool
    public var weather: WeatherSnapshot?
    public var outingID: UUID?
    public var note: String
    /// Created by the automatic track matching (can be removed by the user).
    public var automatic: Bool

    public init(id: UUID = UUID(), peak: Peak, date: Date, mode: SummitMode, modeIsManual: Bool = false,
                weather: WeatherSnapshot? = nil, outingID: UUID? = nil, note: String = "", automatic: Bool = false) {
        self.id = id; self.peakID = peak.id; self.peakName = peak.name; self.elevation = peak.elevation
        self.coordinate = peak.coordinate; self.date = date; self.mode = mode; self.modeIsManual = modeIsManual
        self.weather = weather; self.outingID = outingID; self.note = note; self.automatic = automatic
    }
}

public enum Appearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark

    public var title: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Chiaro"
        case .dark: return "Scuro"
        }
    }
}

public enum ColorMode: String, Codable, CaseIterable, Sendable {
    /// Seed follows the season (ice blue in winter, green otherwise).
    case seasonal
    case custom

    public var title: String { self == .seasonal ? "Segue la stagione" : "Personalizzato" }
}

/// A place to evaluate for Go/No-Go.
public struct GoTarget: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var coordinate: Coordinate
    public var elevation: Double
    /// EAWS region (e.g. "IT-34-BL-01") or prefix ("IT-34").
    public var avalancheRegion: String
    public var webcams: [String]
    public var peakID: String?

    public init(id: UUID = UUID(), name: String, coordinate: Coordinate, elevation: Double, avalancheRegion: String = "IT-34",
                webcams: [String] = [], peakID: String? = nil) {
        self.id = id; self.name = name; self.coordinate = coordinate; self.elevation = elevation
        self.avalancheRegion = avalancheRegion; self.webcams = webcams; self.peakID = peakID
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public var appearance: Appearance = .system
    public var colorMode: ColorMode = .seasonal
    public var customSeed: String = Palette.defaultAccent
    public var seasonMode: SeasonMode = .automatic
    public var summitRadius: Double = 60
    public var autoMatchSummits = true
    public var fetchWeatherForImports = true
    public var goFactors: Set<GoFactor> = Set(GoFactor.allCases)
    public var avalancheFallbackURL = "https://www.arpa.veneto.it/previsioni/it/html/meteo_valanghe.php"
    public var lastLightMargin: Double = 30          // minutes
    public var lastLightNotifyBefore: Double = 30    // minutes
    public var importSports: Set<ActivityKind> = Set(ActivityKind.allCases)
    public var notificationsEnabled = true

    public init() {}

    public init(from decoder: Decoder) throws {
        // Tolerant decoding: missing keys keep the defaults.
        let d = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = (try? c.decode(Appearance.self, forKey: .appearance)) ?? d.appearance
        colorMode = (try? c.decode(ColorMode.self, forKey: .colorMode)) ?? d.colorMode
        customSeed = (try? c.decode(String.self, forKey: .customSeed)) ?? d.customSeed
        seasonMode = (try? c.decode(SeasonMode.self, forKey: .seasonMode)) ?? d.seasonMode
        summitRadius = (try? c.decode(Double.self, forKey: .summitRadius)) ?? d.summitRadius
        autoMatchSummits = (try? c.decode(Bool.self, forKey: .autoMatchSummits)) ?? d.autoMatchSummits
        fetchWeatherForImports = (try? c.decode(Bool.self, forKey: .fetchWeatherForImports)) ?? d.fetchWeatherForImports
        goFactors = (try? c.decode(Set<GoFactor>.self, forKey: .goFactors)) ?? d.goFactors
        avalancheFallbackURL = (try? c.decode(String.self, forKey: .avalancheFallbackURL)) ?? d.avalancheFallbackURL
        lastLightMargin = (try? c.decode(Double.self, forKey: .lastLightMargin)) ?? d.lastLightMargin
        lastLightNotifyBefore = (try? c.decode(Double.self, forKey: .lastLightNotifyBefore)) ?? d.lastLightNotifyBefore
        importSports = (try? c.decode(Set<ActivityKind>.self, forKey: .importSports)) ?? d.importSports
        notificationsEnabled = (try? c.decode(Bool.self, forKey: .notificationsEnabled)) ?? d.notificationsEnabled
    }
}

/// Everything the app stores (except tracks, photos and secrets).
public struct AppData: Codable, Equatable, Sendable {
    public var version = 1
    public var outings: [Outing] = []
    public var stamps: [SummitStamp] = []
    public var userPeaks: [Peak] = []
    public var gear: [GearItem] = []
    public var backpacks: [Backpack] = Backpack.defaults
    public var goTargets: [GoTarget] = []
    public var settings = Settings()
    public var strava = StravaSyncState()
    public var onboardingDone = false
    public var revision = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        outings = (try? c.decode([Outing].self, forKey: .outings)) ?? []
        stamps = (try? c.decode([SummitStamp].self, forKey: .stamps)) ?? []
        userPeaks = (try? c.decode([Peak].self, forKey: .userPeaks)) ?? []
        gear = (try? c.decode([GearItem].self, forKey: .gear)) ?? []
        backpacks = (try? c.decode([Backpack].self, forKey: .backpacks)) ?? Backpack.defaults
        goTargets = (try? c.decode([GoTarget].self, forKey: .goTargets)) ?? []
        settings = (try? c.decode(Settings.self, forKey: .settings)) ?? Settings()
        strava = (try? c.decode(StravaSyncState.self, forKey: .strava)) ?? StravaSyncState()
        onboardingDone = (try? c.decode(Bool.self, forKey: .onboardingDone)) ?? false
        revision = (try? c.decode(Int.self, forKey: .revision)) ?? 0
    }

    public var currentSeasonKind: Season.Kind { Season.resolve(settings.seasonMode) }

    public func outing(_ id: UUID?) -> Outing? { id.flatMap { i in outings.first { $0.id == i } } }

    public func stamps(for peakID: String) -> [SummitStamp] {
        stamps.filter { $0.peakID == peakID }.sorted { $0.date > $1.date }
    }
}
