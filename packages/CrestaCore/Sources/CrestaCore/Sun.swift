import Foundation

/// Sunrise / sunset / twilight from the NOAA solar equations. Offline,
/// accurate to about a minute at mid latitudes.
public enum Sun {
    public enum Event: Sendable {
        case sunrise, sunset, civilDawn, civilDusk, nauticalDusk

        var zenith: Double {
            switch self {
            case .sunrise, .sunset: return 90.833
            case .civilDawn, .civilDusk: return 96
            case .nauticalDusk: return 102
            }
        }

        var rising: Bool { self == .sunrise || self == .civilDawn }
    }

    /// Time of the event on the UTC day containing noon of `day` in `timeZone`.
    /// `elevation` (m) makes the horizon dip: sunset is later on a summit.
    public static func time(_ event: Event, on day: Date, at c: Coordinate, elevation: Double = 0,
                            timeZone: TimeZone = .current) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = cal.dateComponents([.year, .month, .day], from: day)
        guard let localNoon = cal.date(from: DateComponents(year: comps.year, month: comps.month, day: comps.day, hour: 12)) else { return nil }
        // Julian day at local noon.
        let jd = localNoon.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let dip = elevation > 0 ? 2.076 * elevation.squareRoot() / 60 : 0
        let zenith = event.zenith + dip
        // Iterate twice for accuracy.
        var t = jd
        var result: Date?
        for _ in 0..<2 {
            guard let minutes = utcMinutes(jd: t, lat: c.lat, lon: c.lon, zenith: zenith, rising: event.rising) else { return nil }
            let dayStartUTC = floor(t - 0.5) + 0.5
            let eventJD = dayStartUTC + minutes / 1440
            result = Date(timeIntervalSince1970: (eventJD - 2_440_587.5) * 86_400)
            t = eventJD
        }
        // Make sure the result belongs to the requested local day.
        if let r = result, !cal.isDate(r, inSameDayAs: localNoon) {
            let shift: Double = r < localNoon ? 1 : -1
            if let m = utcMinutes(jd: jd + shift, lat: c.lat, lon: c.lon, zenith: zenith, rising: event.rising) {
                let dayStartUTC = floor(jd + shift - 0.5) + 0.5
                let r2 = Date(timeIntervalSince1970: (dayStartUTC + m / 1440 - 2_440_587.5) * 86_400)
                if cal.isDate(r2, inSameDayAs: localNoon) { return r2 }
            }
        }
        return result
    }

    private static func rad(_ d: Double) -> Double { d * .pi / 180 }
    private static func deg(_ r: Double) -> Double { r * 180 / .pi }

    /// Minutes after 00:00 UTC of the event on the day of `jd`.
    static func utcMinutes(jd: Double, lat: Double, lon: Double, zenith: Double, rising: Bool) -> Double? {
        let tc = (jd - 2_451_545.0) / 36_525
        let l0 = (280.46646 + tc * (36_000.76983 + tc * 0.0003032)).truncatingRemainder(dividingBy: 360)
        let m = 357.52911 + tc * (35_999.05029 - 0.0001537 * tc)
        let e = 0.016708634 - tc * (0.000042037 + 0.0000001267 * tc)
        let c = sin(rad(m)) * (1.914602 - tc * (0.004817 + 0.000014 * tc)) + sin(rad(2 * m)) * (0.019993 - 0.000101 * tc) + sin(rad(3 * m)) * 0.000289
        let trueLong = l0 + c
        let omega = 125.04 - 1934.136 * tc
        let lambda = trueLong - 0.00569 - 0.00478 * sin(rad(omega))
        let eps0 = 23 + (26 + (21.448 - tc * (46.815 + tc * (0.00059 - tc * 0.001813))) / 60) / 60
        let eps = eps0 + 0.00256 * cos(rad(omega))
        let decl = deg(asin(sin(rad(eps)) * sin(rad(lambda))))
        let y = tan(rad(eps / 2)) * tan(rad(eps / 2))
        let eqTime = 4 * deg(y * sin(2 * rad(l0)) - 2 * e * sin(rad(m)) + 4 * e * y * sin(rad(m)) * cos(2 * rad(l0))
                             - 0.5 * y * y * sin(4 * rad(l0)) - 1.25 * e * e * sin(2 * rad(m)))
        let cosH = cos(rad(zenith)) / (cos(rad(lat)) * cos(rad(decl))) - tan(rad(lat)) * tan(rad(decl))
        guard cosH >= -1, cosH <= 1 else { return nil }
        let ha = deg(acos(cosH))
        let solarNoon = 720 - 4 * lon - eqTime
        return rising ? solarNoon - 4 * ha : solarNoon + 4 * ha
    }
}

/// "Ultima Luce": from a summit and a departure time, when the sun sets,
/// when it gets dark, and the latest time to turn back.
public struct LastLightPlan: Equatable, Sendable {
    public var departure: Date
    public var summitArrival: Date
    public var sunset: Date?
    public var civilDusk: Date?
    /// Latest time to leave the summit (or turn around) to be back at the
    /// car by dusk, safety margin included.
    public var turnaround: Date?
    public var expectedReturn: Date
    public var ascentDuration: TimeInterval
    public var descentDuration: TimeInterval

    /// Negative when you would arrive after the turnaround time.
    public var slack: TimeInterval? { turnaround.map { $0.timeIntervalSince(summitArrival) } }
    public var returnsInDaylight: Bool { civilDusk.map { expectedReturn <= $0 } ?? true }
}

public enum LastLight {
    /// Typical speeds by mode: vertical m/h up, m/h down, km/h on the flat.
    public struct Pace: Codable, Equatable, Sendable {
        public var upRate: Double
        public var downRate: Double
        public var flatKmh: Double

        public init(upRate: Double, downRate: Double, flatKmh: Double) {
            self.upRate = upRate
            self.downRate = downRate
            self.flatKmh = flatKmh
        }

        public static func `default`(for mode: SummitMode) -> Pace {
            switch mode {
            case .foot: return Pace(upRate: 350, downRate: 500, flatKmh: 4)
            case .ski: return Pace(upRate: 400, downRate: 2000, flatKmh: 4.5)
            case .snowshoe: return Pace(upRate: 300, downRate: 450, flatKmh: 3.2)
            case .bike: return Pace(upRate: 600, downRate: 1800, flatKmh: 14)
            }
        }

        /// Pace learned from the user's own past outings of that mode.
        public static func learned(from stats: [TrackStats], mode: SummitMode) -> Pace {
            let base = Pace.default(for: mode)
            let ups = stats.map(\.verticalUpRate).filter { $0 > 100 && $0 < 2000 }
            let downs = stats.map(\.verticalDownRate).filter { $0 > 100 && $0 < 6000 }
            func median(_ a: [Double]) -> Double? {
                guard !a.isEmpty else { return nil }
                let s = a.sorted(); return s[s.count / 2]
            }
            return Pace(upRate: median(ups).map { ($0 + base.upRate) / 2 } ?? base.upRate,
                        downRate: median(downs).map { ($0 + base.downRate) / 2 } ?? base.downRate,
                        flatKmh: base.flatKmh)
        }
    }

    /// Mountain-style time estimate: vertical time plus half of the flat time
    /// or vice versa (Swiss hiking rule), whichever is larger.
    public static func duration(vertical: Double, distanceKm: Double, verticalRate: Double, flatKmh: Double) -> TimeInterval {
        let v = max(0, vertical) / max(1, verticalRate)
        let h = max(0, distanceKm) / max(0.1, flatKmh)
        return (max(v, h) + min(v, h) / 2) * 3600
    }

    public static func plan(peak: Peak, departure: Date, startElevation: Double, distanceKm: Double,
                            mode: SummitMode, pace: Pace, summitStop: TimeInterval = 20 * 60,
                            safetyMargin: TimeInterval = 30 * 60, timeZone: TimeZone = .current) -> LastLightPlan {
        let gain = max(0, (peak.elevation ?? startElevation) - startElevation)
        let up = duration(vertical: gain, distanceKm: distanceKm, verticalRate: pace.upRate, flatKmh: pace.flatKmh)
        let down = duration(vertical: gain, distanceKm: distanceKm, verticalRate: pace.downRate, flatKmh: pace.flatKmh * (mode == .ski || mode == .bike ? 3 : 1.2))
        let arrival = departure.addingTimeInterval(up)
        let sunset = Sun.time(.sunset, on: departure, at: peak.coordinate, elevation: 0, timeZone: timeZone)
        let dusk = Sun.time(.civilDusk, on: departure, at: peak.coordinate, elevation: 0, timeZone: timeZone)
        let turnaround = dusk.map { $0.addingTimeInterval(-down - safetyMargin) }
        let ret = arrival.addingTimeInterval(summitStop + down)
        return LastLightPlan(departure: departure, summitArrival: arrival, sunset: sunset, civilDusk: dusk,
                             turnaround: turnaround, expectedReturn: ret, ascentDuration: up, descentDuration: down)
    }
}
