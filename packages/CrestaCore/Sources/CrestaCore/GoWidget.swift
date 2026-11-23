import Foundation

/// Time window evaluated by Go/No-Go: 8–16 of a day; after 15:00 the
/// default is tomorrow.
public struct GoDayWindow: Equatable, Sendable {
    public var from: Date
    public var to: Date
    public var label: String
    public var dayOffset: Int

    public static func forDay(offset: Int, now: Date = Date(), calendar: Calendar = .current) -> GoDayWindow {
        let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
        let from = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
        let to = calendar.date(bySettingHour: 16, minute: 0, second: 0, of: day)!
        let label = offset == 0 ? "oggi" : offset == 1 ? "domani" : Format.dayMonth(day, calendar: calendar)
        return GoDayWindow(from: from, to: to, label: label, dayOffset: offset)
    }

    public static func current(now: Date = Date(), calendar: Calendar = .current) -> GoDayWindow {
        forDay(offset: calendar.component(.hour, from: now) >= 15 ? 1 : 0, now: now, calendar: calendar)
    }

    /// When the default window changes (15:00 today, or midnight).
    public static func nextChange(after now: Date, calendar: Calendar = .current) -> Date {
        let threePM = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: now)!
        if now < threePM { return threePM }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
    }
}

/// What the app shares with the Go/No-Go widget (App Group file): the
/// place shown in "Oggi", its cached data, the enabled factors. The widget
/// recomputes the score itself, so it stays right as the day goes on.
public struct GoWidgetSnapshot: Codable, Equatable, Sendable {
    public static let fileName = "go-widget.json"

    public var target: GoTarget?
    public var forecast: Data?
    public var avalanche: AvalancheReport?
    public var fetchedAt: Date?
    public var factors: Set<GoFactor>
    public var winter: Bool
    public var seed: String
    public var webcam: WebcamRating?

    public init(target: GoTarget?, forecast: Data?, avalanche: AvalancheReport?, fetchedAt: Date?,
                factors: Set<GoFactor>, winter: Bool, seed: String, webcam: WebcamRating? = nil) {
        self.target = target
        self.forecast = forecast
        self.avalanche = avalanche
        self.fetchedAt = fetchedAt
        self.factors = factors
        self.winter = winter
        self.seed = seed
        self.webcam = webcam
    }

    public struct Evaluation: Equatable, Sendable {
        public var result: GoNoGoResult
        public var window: GoDayWindow
        public var hasData: Bool
    }

    public func evaluate(now: Date = Date(), calendar: Calendar = .current) -> Evaluation? {
        guard let t = target else { return nil }
        let w = GoDayWindow.current(now: now, calendar: calendar)
        let r = forecast.flatMap { try? OpenMeteo.decode($0) }
        let input = GoNoGoInput(targetElevation: t.elevation, isWinterOuting: winter,
                                avalanche: avalanche?.level(at: t.elevation),
                                weather: r.map { OpenMeteo.window($0, from: w.from, to: w.to) },
                                daysSinceSnowfall: r.flatMap { OpenMeteo.daysSinceSnowfall($0, before: w.from) },
                                webcam: webcam)
        return Evaluation(result: GoNoGo.evaluate(input, enabled: factors), window: w, hasData: r != nil)
    }

    /// Data older than this is refreshed by the widget when it can.
    public func isStale(now: Date = Date(), maxAge: TimeInterval = 3 * 3600) -> Bool {
        guard let f = fetchedAt else { return true }
        return now.timeIntervalSince(f) > maxAge
    }

    public func encoded() throws -> Data { try JSONFileStore<GoWidgetSnapshot>.encoder(compact: true).encode(self) }

    public static func decode(_ data: Data) -> GoWidgetSnapshot? {
        try? JSONFileStore<GoWidgetSnapshot>.decoder.decode(GoWidgetSnapshot.self, from: data)
    }
}
