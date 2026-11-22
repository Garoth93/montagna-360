import Foundation

/// Weather at a given time and place (Open-Meteo).
public struct WeatherSnapshot: Codable, Equatable, Sendable {
    public var code: Int
    public var temperature: Double?
    public var windSpeed: Double?      // km/h
    public var windGusts: Double?      // km/h
    public var freezingLevel: Double?  // m
    public var cloudCover: Double?     // %

    public init(code: Int, temperature: Double? = nil, windSpeed: Double? = nil, windGusts: Double? = nil,
                freezingLevel: Double? = nil, cloudCover: Double? = nil) {
        self.code = code
        self.temperature = temperature
        self.windSpeed = windSpeed
        self.windGusts = windGusts
        self.freezingLevel = freezingLevel
        self.cloudCover = cloudCover
    }

    public var title: String { WMOCode.title(code) }
    public var icon: String { WMOCode.icon(code) }

    public var summary: String {
        var parts = [title]
        if let t = temperature { parts.append("\(Int(t.rounded()))°") }
        if let w = windSpeed, w >= 1 { parts.append("vento \(Int(w.rounded())) km/h") }
        return parts.joined(separator: " · ")
    }
}

public enum WMOCode {
    public static func title(_ code: Int) -> String {
        switch code {
        case 0: return "Sereno"
        case 1: return "Poco nuvoloso"
        case 2: return "Parzialmente nuvoloso"
        case 3: return "Coperto"
        case 45, 48: return "Nebbia"
        case 51, 53, 55, 56, 57: return "Pioviggine"
        case 61, 63, 65, 66, 67: return "Pioggia"
        case 71, 73, 75, 77: return "Neve"
        case 80, 81, 82: return "Rovesci"
        case 85, 86: return "Rovesci di neve"
        case 95, 96, 99: return "Temporale"
        default: return "—"
        }
    }

    public static func icon(_ code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "questionmark.circle"
        }
    }

    public static func isPrecipitation(_ code: Int) -> Bool { code >= 51 }
    public static func isStorm(_ code: Int) -> Bool { code >= 95 }
}

/// Builds Open-Meteo URLs and parses its JSON. No key needed.
public enum OpenMeteo {
    static let hourlyVars = "temperature_2m,weather_code,wind_speed_10m,wind_gusts_10m,freezing_level_height,cloud_cover,precipitation,snowfall"

    /// Forecast for the next days plus `pastDays` of history (for the last snowfall).
    public static func forecastURL(_ c: Coordinate, pastDays: Int = 30, elevation: Double? = nil) -> URL {
        var s = "https://api.open-meteo.com/v1/forecast?latitude=\(fmt(c.lat))&longitude=\(fmt(c.lon))"
        s += "&hourly=\(hourlyVars)&daily=snowfall_sum,weather_code,sunrise,sunset"
        s += "&past_days=\(pastDays)&forecast_days=7&timezone=auto&wind_speed_unit=kmh"
        if let elevation { s += "&elevation=\(Int(elevation))" }
        return URL(string: s)!
    }

    /// Historical weather for one day (for summit stamps of past outings).
    public static func archiveURL(_ c: Coordinate, day: String, elevation: Double? = nil) -> URL {
        var s = "https://archive-api.open-meteo.com/v1/archive?latitude=\(fmt(c.lat))&longitude=\(fmt(c.lon))"
        s += "&start_date=\(day)&end_date=\(day)&hourly=temperature_2m,weather_code,wind_speed_10m,wind_gusts_10m,cloud_cover"
        s += "&timezone=GMT&wind_speed_unit=kmh"
        if let elevation { s += "&elevation=\(Int(elevation))" }
        return URL(string: s)!
    }

    static func fmt(_ v: Double) -> String { String(format: "%.4f", v) }

    public struct Hourly: Decodable, Sendable {
        public var time: [String]
        public var temperature_2m: [Double?]?
        public var weather_code: [Int?]?
        public var wind_speed_10m: [Double?]?
        public var wind_gusts_10m: [Double?]?
        public var freezing_level_height: [Double?]?
        public var cloud_cover: [Double?]?
        public var precipitation: [Double?]?
        public var snowfall: [Double?]?
    }

    public struct Daily: Decodable, Sendable {
        public var time: [String]
        public var snowfall_sum: [Double?]?
        public var weather_code: [Int?]?
        public var sunrise: [String]?
        public var sunset: [String]?
    }

    public struct Response: Decodable, Sendable {
        public var utc_offset_seconds: Int?
        public var hourly: Hourly?
        public var daily: Daily?
    }

    public static func decode(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }

    /// Parses Open-Meteo local "yyyy-MM-ddTHH:mm" with the response offset.
    public static func date(_ s: String, offset: Int) -> Date? {
        let parts = s.split(separator: "T")
        guard parts.count == 2 else { return nil }
        let d = parts[0].split(separator: "-").compactMap { Int($0) }
        let t = parts[1].split(separator: ":").compactMap { Int($0) }
        guard d.count == 3, t.count >= 2 else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: offset) ?? TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: d[0], month: d[1], day: d[2], hour: t[0], minute: t[1]))
    }

    /// Weather at the hour nearest to `date`.
    public static func snapshot(_ r: Response, at date: Date) -> WeatherSnapshot? {
        guard let h = r.hourly, !h.time.isEmpty else { return nil }
        let off = r.utc_offset_seconds ?? 0
        var best = -1
        var bestGap = Double.infinity
        for (i, s) in h.time.enumerated() {
            guard let d = Self.date(s, offset: off) else { continue }
            let gap = abs(d.timeIntervalSince(date))
            if gap < bestGap { bestGap = gap; best = i }
        }
        guard best >= 0, bestGap <= 3 * 3600 else { return nil }
        func v<T>(_ a: [T?]?) -> T? { a.flatMap { best < $0.count ? $0[best] : nil } }
        guard let code = v(h.weather_code) else { return nil }
        return WeatherSnapshot(code: code, temperature: v(h.temperature_2m), windSpeed: v(h.wind_speed_10m),
                               windGusts: v(h.wind_gusts_10m), freezingLevel: v(h.freezing_level_height),
                               cloudCover: v(h.cloud_cover))
    }

    /// Days between `date` and the last day with ≥ `minimumCm` of snowfall.
    public static func daysSinceSnowfall(_ r: Response, before date: Date, minimumCm: Double = 5) -> Int? {
        guard let d = r.daily, let snow = d.snowfall_sum else { return nil }
        let off = r.utc_offset_seconds ?? 0
        var last: Date?
        for (i, s) in d.time.enumerated() where i < snow.count {
            guard let day = Self.date(s + "T12:00", offset: off), day <= date.addingTimeInterval(12 * 3600) else { continue }
            if let cm = snow[i], cm >= minimumCm { last = day }
        }
        guard let last else { return nil }
        return max(0, Int((date.timeIntervalSince(last) / 86_400).rounded()))
    }

    /// Worst values over a time window (the hours of the outing).
    public struct WindowSummary: Equatable, Sendable {
        public var maxWind: Double?
        public var maxGusts: Double?
        public var minFreezingLevel: Double?
        public var maxFreezingLevel: Double?
        public var precipitation: Double
        public var worstCode: Int?
        public var meanCloudCover: Double?
    }

    public static func window(_ r: Response, from: Date, to: Date) -> WindowSummary {
        var w = WindowSummary(precipitation: 0)
        guard let h = r.hourly else { return w }
        let off = r.utc_offset_seconds ?? 0
        var clouds: [Double] = []
        for (i, s) in h.time.enumerated() {
            guard let d = Self.date(s, offset: off), d >= from.addingTimeInterval(-1800), d <= to.addingTimeInterval(1800) else { continue }
            func v<T>(_ a: [T?]?) -> T? { a.flatMap { i < $0.count ? $0[i] : nil } }
            if let x = v(h.wind_speed_10m) { w.maxWind = max(w.maxWind ?? 0, x) }
            if let x = v(h.wind_gusts_10m) { w.maxGusts = max(w.maxGusts ?? 0, x) }
            if let x = v(h.freezing_level_height) {
                w.minFreezingLevel = min(w.minFreezingLevel ?? .infinity, x)
                w.maxFreezingLevel = max(w.maxFreezingLevel ?? -.infinity, x)
            }
            if let x = v(h.precipitation) { w.precipitation += x }
            if let x = v(h.weather_code) { w.worstCode = max(w.worstCode ?? 0, x) }
            if let x = v(h.cloud_cover) { clouds.append(x) }
        }
        if !clouds.isEmpty { w.meanCloudCover = clouds.reduce(0, +) / Double(clouds.count) }
        return w
    }
}
