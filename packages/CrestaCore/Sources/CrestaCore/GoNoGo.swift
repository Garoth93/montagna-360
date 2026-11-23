import Foundation

/// Factors of the Go/No-Go score. Each can be switched off.
public enum GoFactor: String, Codable, CaseIterable, Sendable, Identifiable {
    case avalanche, weather, wind, freezingLevel, webcam, freshSnow, snowDepth

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .avalanche: return "Bollettino valanghe"
        case .weather: return "Meteo"
        case .wind: return "Vento"
        case .freezingLevel: return "Zero termico"
        case .webcam: return "Webcam"
        case .freshSnow: return "Ultima nevicata"
        case .snowDepth: return "Neve al suolo"
        }
    }

    public var icon: String {
        switch self {
        case .avalanche: return "exclamationmark.triangle.fill"
        case .weather: return "cloud.sun.fill"
        case .wind: return "wind"
        case .freezingLevel: return "thermometer.snowflake"
        case .webcam: return "web.camera.fill"
        case .freshSnow: return "snowflake"
        case .snowDepth: return "ruler.fill"
        }
    }

    /// Relative weight in the final score.
    public var defaultWeight: Double {
        switch self {
        case .avalanche: return 3
        case .weather: return 2
        case .wind: return 1.5
        case .freezingLevel: return 1
        case .webcam: return 1
        case .freshSnow: return 1
        case .snowDepth: return 1
        }
    }

    public var winterOnly: Bool { self == .avalanche || self == .freshSnow || self == .snowDepth }
}

/// What the user saw on the webcam.
public enum WebcamRating: String, Codable, CaseIterable, Sendable {
    case clear, partly, cloudy, fog

    public var title: String {
        switch self {
        case .clear: return "Limpido"
        case .partly: return "Qualche nube"
        case .cloudy: return "Nuvoloso"
        case .fog: return "Nebbia / niente visibilità"
        }
    }

    var score: Double {
        switch self {
        case .clear: return 10
        case .partly: return 7.5
        case .cloudy: return 4.5
        case .fog: return 1.5
        }
    }
}

public struct GoNoGoInput: Equatable, Sendable {
    public var targetElevation: Double
    public var isWinterOuting: Bool
    public var avalanche: DangerLevel?
    public var weather: OpenMeteo.WindowSummary?
    public var daysSinceSnowfall: Int?
    public var webcam: WebcamRating?

    public init(targetElevation: Double, isWinterOuting: Bool, avalanche: DangerLevel? = nil,
                weather: OpenMeteo.WindowSummary? = nil, daysSinceSnowfall: Int? = nil, webcam: WebcamRating? = nil) {
        self.targetElevation = targetElevation
        self.isWinterOuting = isWinterOuting
        self.avalanche = avalanche
        self.weather = weather
        self.daysSinceSnowfall = daysSinceSnowfall
        self.webcam = webcam
    }
}

public struct FactorScore: Equatable, Sendable, Identifiable {
    public var factor: GoFactor
    /// 0…10, nil if data is missing.
    public var score: Double?
    public var detail: String
    /// A blocking factor caps the total (e.g. danger 4, storms).
    public var veto: Bool

    public var id: String { factor.rawValue }
}

public struct GoNoGoResult: Equatable, Sendable {
    public var score: Double
    public var factors: [FactorScore]

    public enum Verdict: String, Sendable { case go, caution, noGo }

    public var verdict: Verdict {
        if score >= 7 { return .go }
        if score >= 4.5 { return .caution }
        return .noGo
    }

    public var verdictTitle: String {
        switch verdict {
        case .go: return "Si va"
        case .caution: return "Con prudenza"
        case .noGo: return "Meglio di no"
        }
    }
}

public enum GoNoGo {
    public static func evaluate(_ input: GoNoGoInput, enabled: Set<GoFactor>) -> GoNoGoResult {
        var out: [FactorScore] = []
        for f in GoFactor.allCases where enabled.contains(f) {
            if f.winterOnly && !input.isWinterOuting { continue }
            out.append(score(f, input))
        }
        let valid = out.filter { $0.score != nil }
        var total = 5.0
        if !valid.isEmpty {
            let wsum = valid.reduce(0) { $0 + $1.factor.defaultWeight }
            total = valid.reduce(0) { $0 + $1.score! * $1.factor.defaultWeight } / wsum
            // A weak link pulls the whole score down.
            if let worst = valid.compactMap(\.score).min() { total = min(total, worst + 3) }
        }
        if out.contains(where: \.veto) { total = min(total, 2) }
        return GoNoGoResult(score: (total * 10).rounded() / 10, factors: out)
    }

    static func score(_ f: GoFactor, _ i: GoNoGoInput) -> FactorScore {
        switch f {
        case .avalanche:
            guard let lv = i.avalanche else { return FactorScore(factor: f, score: nil, detail: "Bollettino non disponibile", veto: false) }
            let s: Double = [10, 7, 3.5, 1, 0][lv.rawValue - 1]
            return FactorScore(factor: f, score: s, detail: "Pericolo \(lv.title)", veto: lv >= .high)
        case .weather:
            guard let w = i.weather, let code = w.worstCode else { return FactorScore(factor: f, score: nil, detail: "Meteo non disponibile", veto: false) }
            var s = 10.0
            if WMOCode.isStorm(code) { s = 0.5 } else if code >= 61 { s = 3 } else if code >= 51 { s = 5 } else if code == 45 || code == 48 { s = 5.5 } else if code == 3 { s = 7 } else if code == 2 { s = 8.5 }
            if w.precipitation > 5 { s = min(s, 3) }
            var detail = WMOCode.title(code)
            if w.precipitation > 0.2 { detail += String(format: " · %.0f mm", w.precipitation) }
            return FactorScore(factor: f, score: s, detail: detail, veto: WMOCode.isStorm(code))
        case .wind:
            guard let w = i.weather, let wind = w.maxWind else { return FactorScore(factor: f, score: nil, detail: "Vento non disponibile", veto: false) }
            let gust = w.maxGusts ?? wind
            // Valley-station wind underestimates ridges: weigh gusts more.
            let eff = max(wind, gust * 0.7)
            let s: Double = eff < 15 ? 10 : eff < 25 ? 8 : eff < 35 ? 6 : eff < 50 ? 3.5 : eff < 70 ? 1.5 : 0
            return FactorScore(factor: f, score: s, detail: "Vento \(Int(wind)) km/h, raffiche \(Int(gust))", veto: eff >= 70)
        case .freezingLevel:
            guard let w = i.weather, let lo = w.minFreezingLevel, let hi = w.maxFreezingLevel else {
                return FactorScore(factor: f, score: nil, detail: "Zero termico non disponibile", veto: false)
            }
            let s: Double
            if i.isWinterOuting {
                // Winter: a very high freezing level means wet, unstable snow.
                let margin = hi - i.targetElevation
                s = margin < -300 ? 10 : margin < 0 ? 8.5 : margin < 500 ? 6 : margin < 1000 ? 4 : 2.5
            } else {
                // Summer: ice/snow on the route if freezing level is below the target.
                let margin = lo - i.targetElevation
                s = margin > 500 ? 10 : margin > 0 ? 8 : margin > -300 ? 5 : 2.5
            }
            return FactorScore(factor: f, score: s, detail: "Zero termico \(Int(lo))–\(Int(hi)) m", veto: false)
        case .webcam:
            guard let r = i.webcam else { return FactorScore(factor: f, score: nil, detail: "Guarda una webcam e valuta", veto: false) }
            return FactorScore(factor: f, score: r.score, detail: r.title, veto: false)
        case .freshSnow:
            guard let d = i.daysSinceSnowfall else { return FactorScore(factor: f, score: nil, detail: "Nessuna nevicata recente", veto: false) }
            // Fresh snow in the last 1–2 days = most avalanche-prone.
            let s: Double = d <= 1 ? 3 : d <= 3 ? 5.5 : d <= 7 ? 8 : 9.5
            return FactorScore(factor: f, score: s, detail: d == 0 ? "Nevicato oggi" : d == 1 ? "Nevicato ieri" : "Nevicato \(d) giorni fa", veto: false)
        case .snowDepth:
            guard let w = i.weather, let depth = w.snowDepth else {
                return FactorScore(factor: f, score: nil, detail: "Neve al suolo non disponibile", veto: false)
            }
            // Enough snow to ski or walk on snow: more is better.
            let s: Double = depth < 0.1 ? 1.5 : depth < 0.3 ? 4 : depth < 0.6 ? 7 : depth < 1 ? 8.5 : 10
            var detail = "\(Int((depth * 100).rounded())) cm al suolo"
            if w.freshSnow72h >= 1 { detail += " · \(Int(w.freshSnow72h.rounded())) cm freschi in 3 giorni" }
            return FactorScore(factor: f, score: s, detail: detail, veto: false)
        }
    }
}
