import Foundation

/// Totals for a set of outings (a season, a year, a kind).
public struct Totals: Equatable, Sendable {
    public var outings = 0
    public var days = 0
    public var distance = 0.0
    public var ascent = 0.0
    public var descent = 0.0
    public var moving: TimeInterval = 0
    public var maxSpeed = 0.0
    public var maxElevation = 0.0
    public var runs = 0
    public var summits = 0
    public var newSummits = 0

    public init() {}
}

public struct SeasonStats: Equatable, Sendable {
    public var season: Season
    public var totals: Totals
    public var byKind: [(kind: ActivityKind, totals: Totals)]
    /// Days per month (1…12) for the chart.
    public var daysByMonth: [Int: Int]
    public var longest: Outing?
    public var biggestClimb: Outing?
    public var fastest: Outing?
    public var highest: Outing?

    public static func == (a: SeasonStats, b: SeasonStats) -> Bool {
        a.season == b.season && a.totals == b.totals && a.daysByMonth == b.daysByMonth
    }
}

public enum StatsBuilder {
    public static func totals(_ outings: [Outing], stamps: [SummitStamp] = [], allStamps: [SummitStamp] = [], calendar: Calendar = .current) -> Totals {
        var t = Totals()
        var days = Set<DateComponents>()
        for o in outings {
            t.outings += 1
            days.insert(calendar.dateComponents([.year, .month, .day], from: o.start))
            t.distance += o.stats.distance
            t.ascent += o.stats.ascent
            t.descent += o.stats.descent
            t.moving += o.stats.moving
            t.maxSpeed = max(t.maxSpeed, o.stats.maxSpeed)
            t.maxElevation = max(t.maxElevation, o.stats.maxElevation ?? 0)
            if o.kind == .resortSki || o.kind == .snowboard { t.runs += o.stats.runs }
        }
        t.days = days.count
        t.summits = stamps.count
        // A summit is "new" if no earlier stamp of the same peak exists.
        t.newSummits = stamps.filter { s in !allStamps.contains { $0.peakID == s.peakID && $0.date < s.date } }
            .reduce(into: Set<String>()) { $0.insert($1.peakID) }.count
        return t
    }

    /// Ski days grouped by ski area, most days first.
    public static func areas(_ outings: [Outing], calendar: Calendar = .current) -> [(name: String, days: Int, descent: Double)] {
        let ski = outings.filter { ($0.kind == .resortSki || $0.kind == .snowboard) && $0.area != nil }
        return Dictionary(grouping: ski, by: { $0.area! }).map { name, list in
            let days = Set(list.map { calendar.dateComponents([.year, .month, .day], from: $0.start) }).count
            return (name: name, days: days, descent: list.reduce(0) { $0 + $1.stats.descent })
        }.sorted { $0.days != $1.days ? $0.days > $1.days : $0.name < $1.name }
    }

    public static func seasons(_ outings: [Outing]) -> [Season] {
        Array(Set(outings.map(\.season))).sorted(by: >)
    }

    public static func season(_ season: Season, outings all: [Outing], stamps allStamps: [SummitStamp], calendar: Calendar = .current) -> SeasonStats {
        let outings = all.filter { Season.of($0.start, calendar: calendar) == season }
        let stamps = allStamps.filter { Season.of($0.date, calendar: calendar) == season }
        let kinds = Dictionary(grouping: outings, by: \.kind)
            .map { ($0.key, totals($0.value, calendar: calendar)) }
            .sorted { $0.1.days > $1.1.days }
        var byMonth: [Int: Set<Int>] = [:]
        for o in outings {
            let c = calendar.dateComponents([.month, .day], from: o.start)
            byMonth[c.month ?? 1, default: []].insert(c.day ?? 1)
        }
        return SeasonStats(season: season, totals: totals(outings, stamps: stamps, allStamps: allStamps, calendar: calendar),
                           byKind: kinds.map { (kind: $0.0, totals: $0.1) },
                           daysByMonth: byMonth.mapValues(\.count),
                           longest: outings.max { $0.stats.distance < $1.stats.distance },
                           biggestClimb: outings.max { $0.stats.ascent < $1.stats.ascent },
                           fastest: outings.max { $0.stats.maxSpeed < $1.stats.maxSpeed },
                           highest: outings.max { ($0.stats.maxElevation ?? 0) < ($1.stats.maxElevation ?? 0) })
    }
}

/// End-of-year recap ("Wrapped"): a sequence of story cards.
public struct WrappedCard: Equatable, Sendable, Identifiable {
    public var id: String
    public var icon: String
    public var eyebrow: String
    public var value: String
    public var caption: String
    public var colorHex: String
}

public enum Wrapped {
    public static func cards(year: Int, outings all: [Outing], stamps allStamps: [SummitStamp], calendar: Calendar = .current) -> [WrappedCard] {
        let outings = all.filter { calendar.component(.year, from: $0.start) == year }
        let stamps = allStamps.filter { calendar.component(.year, from: $0.date) == year }
        guard !outings.isEmpty || !stamps.isEmpty else { return [] }
        let t = StatsBuilder.totals(outings, stamps: stamps, allStamps: allStamps, calendar: calendar)
        var cards: [WrappedCard] = []
        cards.append(WrappedCard(id: "intro", icon: "mountain.2.fill", eyebrow: "Il tuo \(year)", value: "\(t.days)",
                                 caption: t.days == 1 ? "giorno in montagna" : "giorni in montagna", colorHex: "#1565c0"))
        cards.append(WrappedCard(id: "ascent", icon: "arrow.up.right", eyebrow: "Dislivello positivo", value: Format.meters(t.ascent),
                                 caption: everestCaption(t.ascent), colorHex: "#e65100"))
        cards.append(WrappedCard(id: "distance", icon: "point.topleft.down.to.point.bottomright.curvepath.fill", eyebrow: "Distanza",
                                 value: Format.km(t.distance), caption: "in \(Format.duration(t.moving)) di movimento", colorHex: "#2e7d32"))
        if t.summits > 0 {
            cards.append(WrappedCard(id: "summits", icon: "flag.fill", eyebrow: "Cime e passi timbrati", value: "\(t.summits)",
                                     caption: t.newSummits > 0 ? "\(t.newSummits) mai salite prima" : "vecchie amiche", colorHex: "#6a1b9a"))
            if let top = stamps.max(by: { ($0.elevation ?? 0) < ($1.elevation ?? 0) }) {
                cards.append(WrappedCard(id: "highest", icon: "triangle.fill", eyebrow: "La più alta", value: top.peakName,
                                         caption: top.elevation.map { Format.meters($0) } ?? "", colorHex: "#455a64"))
            }
            let counts = Dictionary(grouping: stamps, by: \.peakID).mapValues(\.count)
            if let fav = counts.max(by: { $0.value < $1.value }), fav.value > 1, let s = stamps.first(where: { $0.peakID == fav.key }) {
                cards.append(WrappedCard(id: "favourite", icon: "heart.fill", eyebrow: "La tua preferita", value: s.peakName,
                                         caption: "salita \(fav.value) volte", colorHex: "#c2185b"))
            }
        }
        let snow = outings.filter { $0.kind.isSnow }
        if !snow.isEmpty {
            let st = StatsBuilder.totals(snow, calendar: calendar)
            cards.append(WrappedCard(id: "snow", icon: "snowflake", eyebrow: "Sulla neve", value: "\(st.days) giorni",
                                     caption: st.runs > 0 ? "\(st.runs) discese, \(Format.meters(st.descent)) in giù" : "\(Format.meters(st.descent)) di discesa",
                                     colorHex: "#0277bd"))
            if st.maxSpeed > 0 {
                cards.append(WrappedCard(id: "speed", icon: "gauge.with.dots.needle.67percent", eyebrow: "Velocità massima",
                                         value: Format.speed(st.maxSpeed), caption: "il tuo momento più veloce", colorHex: "#d84315"))
            }
        }
        if let area = StatsBuilder.areas(outings, calendar: calendar).first, area.days > 1 {
            cards.append(WrappedCard(id: "area", icon: "figure.skiing.downhill", eyebrow: "Il tuo comprensorio", value: area.name,
                                     caption: "\(area.days) giornate sugli sci", colorHex: "#1565c0"))
        }
        let passes = stamps.filter { $0.kind == .pass }
        if !passes.isEmpty {
            cards.append(WrappedCard(id: "passes", icon: "road.lanes.curved.right", eyebrow: "Passi", value: "\(Set(passes.map(\.peakID)).count)",
                                     caption: "valichi conquistati", colorHex: "#ef6c00"))
        }
        let kinds = Dictionary(grouping: outings, by: \.kind).mapValues(\.count)
        if let top = kinds.max(by: { $0.value < $1.value }) {
            cards.append(WrappedCard(id: "kind", icon: top.key.icon, eyebrow: "L'attività del tuo anno", value: top.key.title,
                                     caption: "\(top.value) uscite", colorHex: top.key.colorHex))
        }
        let months = Dictionary(grouping: outings) { calendar.component(.month, from: $0.start) }.mapValues(\.count)
        if let m = months.max(by: { $0.value < $1.value }) {
            cards.append(WrappedCard(id: "month", icon: "calendar", eyebrow: "Il mese più attivo", value: Format.monthName(m.key).capitalized,
                                     caption: "\(m.value) uscite", colorHex: "#00838f"))
        }
        if let big = outings.max(by: { $0.stats.ascent < $1.stats.ascent }), big.stats.ascent > 0 {
            cards.append(WrappedCard(id: "big", icon: "star.fill", eyebrow: "La giornata più dura", value: big.name,
                                     caption: "\(Format.meters(big.stats.ascent)) di dislivello · \(Format.dayMonth(big.start))", colorHex: "#f9a825"))
        }
        cards.append(WrappedCard(id: "outro", icon: "sparkles", eyebrow: "Alla prossima stagione", value: "\(t.outings) uscite",
                                 caption: "Grazie per aver portato Cresta in quota", colorHex: "#1565c0"))
        return cards
    }

    static func everestCaption(_ ascent: Double) -> String {
        let e = ascent / 8849
        if e >= 1 { return String(format: "%.1f volte l'Everest", e).replacingOccurrences(of: ".", with: ",") }
        return "\(Int((e * 100).rounded()))% di un Everest"
    }
}
