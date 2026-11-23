import WidgetKit
import SwiftUI
import CrestaCore

@main
struct CrestaWidgets: WidgetBundle {
    var body: some Widget {
        GoNoGoWidget()
    }
}

struct GoEntry: TimelineEntry {
    let date: Date
    let snapshot: GoWidgetSnapshot?
    let evaluation: GoWidgetSnapshot.Evaluation?
}

/// Reads the snapshot written by the app; refreshes the forecast and the
/// avalanche bulletin itself when they are older than 3 hours.
struct GoProvider: TimelineProvider {
    func placeholder(in context: Context) -> GoEntry {
        let t = GoTarget(name: "La tua meta", coordinate: Coordinate(lat: 46, lon: 11), elevation: 2000)
        let snap = GoWidgetSnapshot(target: t, forecast: nil, avalanche: nil, fetchedAt: nil, factors: [], winter: true, seed: Palette.winterSeed)
        return GoEntry(date: Date(), snapshot: snap, evaluation: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (GoEntry) -> Void) {
        let snap = SharedStore.loadGo()
        completion(GoEntry(date: Date(), snapshot: snap, evaluation: snap?.evaluate()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GoEntry>) -> Void) {
        Task {
            var snap = SharedStore.loadGo()
            if var s = snap, let t = s.target, s.isStale() {
                if let data = await Self.fetch(OpenMeteo.forecastURL(t.coordinate, pastDays: 30, elevation: t.elevation)),
                   (try? OpenMeteo.decode(data)) != nil {
                    s.forecast = data
                    s.fetchedAt = Date()
                    let day = Format.isoDay(Date())
                    if let a = await Self.fetch(AvalancheBulletin.caamlURL(regionPrefix: t.avalancheRegion, day: day)),
                       let report = try? AvalancheBulletin.parseCAAML(a, regionID: t.avalancheRegion) {
                        s.avalanche = report
                    }
                    SharedStore.saveGo(s)
                    snap = s
                }
            }
            let now = Date()
            let change = GoDayWindow.nextChange(after: now)
            // Entry now, another when the day window switches (15:00 / midnight).
            let entries = [now, change].map { GoEntry(date: $0, snapshot: snap, evaluation: snap?.evaluate(now: $0)) }
            let next = min(change.addingTimeInterval(60), now.addingTimeInterval(3 * 3600))
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }

    static func fetch(_ url: URL) async -> Data? {
        var r = URLRequest(url: url)
        r.timeoutInterval = 12
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

struct GoNoGoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "GoNoGo", provider: GoProvider()) { entry in
            GoWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground(entry: entry) }
                .widgetURL(URL(string: "cresta://go"))
        }
        .configurationDisplayName("Go/No-Go")
        .description("Il punteggio della meta mostrata in Oggi: valanghe, meteo, vento, neve.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private func tones(_ e: GoWidgetSnapshot.Evaluation?, _ m3: M3Theme) -> Tones {
    guard let e, e.hasData else { return m3.neutral }
    switch e.result.verdict {
    case .go: return m3.successTones
    case .caution: return m3.warningTones
    case .noGo: return m3.errorTones
    }
}

struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme
    let entry: GoEntry

    var body: some View {
        let m3 = M3Theme(seed: entry.snapshot?.seed ?? Palette.defaultAccent, dark: scheme == .dark)
        tones(entry.evaluation, m3).container
    }
}

struct GoWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let entry: GoEntry

    var body: some View {
        let m3 = M3Theme(seed: entry.snapshot?.seed ?? Palette.defaultAccent, dark: scheme == .dark)
        let t = tones(entry.evaluation, m3)
        let e = entry.evaluation
        let score = e?.hasData == true ? e!.result.score : nil
        let name = entry.snapshot?.target?.name
        switch family {
        case .accessoryCircular:
            Gauge(value: score ?? 0, in: 0...10) {
                Image(systemName: "mountain.2.fill")
            } currentValueLabel: {
                Text(score.map { Format.number($0, decimals: 1) } ?? "–")
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryInline:
            Text(score.map { "\(e!.result.verdictTitle) \(Format.number($0, decimals: 1)) · \(name ?? "")" } ?? "Go/No-Go: apri Cresta")
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text(name ?? "Go/No-Go").font(.headline).lineLimit(1)
                Text(score.map { "\(Format.number($0, decimals: 1)) · \(e!.result.verdictTitle)" } ?? "Nessun dato").font(.body)
                if let e { Text(e.window.label.capitalized).font(.caption) }
            }
        case .systemMedium:
            HStack(spacing: 14) {
                gauge(score, t)
                VStack(alignment: .leading, spacing: 4) {
                    Text(name ?? "Nessuna meta").font(.system(size: 15, weight: .bold, design: .rounded)).lineLimit(1)
                    if let e, e.hasData {
                        ForEach(e.result.factors.filter { $0.score != nil }.sorted { ($0.score ?? 10) < ($1.score ?? 10) }.prefix(3)) { f in
                            HStack(spacing: 4) {
                                Image(systemName: f.factor.icon).frame(width: 14)
                                Text(f.detail).lineLimit(1)
                            }
                            .font(.system(size: 11, weight: .medium))
                        }
                    } else {
                        Text(entry.snapshot?.target == nil ? "Scegli una meta in Go/No-Go" : "Apri Cresta per scaricare i dati").font(.caption)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(t.onContainer)
        default:
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    gauge(score, t).frame(width: 64, height: 64)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                Text(score != nil ? e!.result.verdictTitle : "Go/No-Go").font(.system(size: 17, weight: .heavy, design: .rounded))
                Text([name, e?.window.label].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(t.onContainer)
        }
    }

    private func gauge(_ score: Double?, _ t: Tones) -> some View {
        ZStack {
            Circle().stroke(t.onContainer.opacity(0.15), lineWidth: 7)
            Circle().trim(from: 0, to: (score ?? 0) / 10)
                .stroke(t.accent, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(score.map { Format.number($0, decimals: 1) } ?? "–")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.6)
        }
        .padding(4)
        .frame(width: 76, height: 76)
    }
}
