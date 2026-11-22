import SwiftUI
import CrestaCore

/// "Oggi": the dashboard. The season switch decides what comes first.
struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3

    enum Block: String, Identifiable {
        case go, season, garage, last, summits, lastLight, backpack, wrapped
        var id: String { rawValue }
    }

    private var blocks: [Block] {
        var b: [Block] = model.seasonKind == .winter
            ? [.go, .season, .garage, .last, .backpack, .summits, .lastLight]
            : [.summits, .lastLight, .season, .last, .backpack, .go]
        // Late in the year: the recap goes to the top.
        let month = Calendar.current.component(.month, from: Date())
        if month == 12 || month == 1, !model.data.outings.isEmpty { b.insert(.wrapped, at: 0) }
        if model.garageAlerts.isEmpty { b.removeAll { $0 == .garage } }
        return b
    }

    var body: some View {
        ScreenScroll {
            SeasonHero()
            ForEach(blocks) { block in
                Group {
                    switch block {
                    case .go: GoSummaryCard()
                    case .season: SeasonSummaryCard()
                    case .garage: GarageAlertCard()
                    case .last: LastOutingCard()
                    case .summits: SummitsSummaryCard()
                    case .lastLight: ToolLinkCard(tool: .lastLight)
                    case .backpack: ToolLinkCard(tool: .backpack)
                    case .wrapped: WrappedLinkCard()
                    }
                }
                .transition(.asymmetric(insertion: .scale(scale: 0.92).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.m3Spatial, value: model.seasonKind)
        .navigationTitle("Oggi")
        .navigationDestination(for: Tool.self) { $0.destination }
        .navigationDestination(for: UUID.self) { OutingDetailView(outingID: $0) }
    }
}

/// Big header with the Inverno / Non inverno switch.
struct SeasonHero: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3

    var body: some View {
        let winter = model.seasonKind == .winter
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Format.dayMonth(Date()).capitalized).font(.m3LabelLarge).foregroundStyle(m3.onPrimaryContainer.opacity(0.8))
                    Text(winter ? "Stagione\nbianca" : "Stagione\nverde")
                        .font(.m3DisplayMedium)
                        .foregroundStyle(m3.onPrimaryContainer)
                        .contentTransition(.opacity)
                }
                Spacer()
                IconBadge(icon: winter ? "snowflake" : "sun.max.fill", tones: m3.primaryTones, size: 72, cookie: true, filled: true)
                    .symbolEffect(.bounce, value: winter)
            }
            SegmentedPills(options: [(Season.Kind.winter, "Inverno", "snowflake"), (Season.Kind.summer, "Non inverno", "leaf.fill")],
                           selection: Binding(get: { model.seasonKind }, set: { k in
                               model.mutate { $0.settings.seasonMode = k == .winter ? .winter : .summer }
                           }))
            HStack(spacing: 6) {
                Image(systemName: model.data.settings.seasonMode == .automatic ? "calendar.badge.clock" : "hand.tap.fill")
                Text(model.data.settings.seasonMode == .automatic ? "Scelta automatica in base alla data" : "Scelta a mano")
                Spacer()
                if model.data.settings.seasonMode != .automatic {
                    Button("Automatica") { model.mutate { $0.settings.seasonMode = .automatic } }
                        .font(.m3LabelLarge)
                }
            }
            .font(.m3LabelMedium)
            .foregroundStyle(m3.onPrimaryContainer.opacity(0.8))
        }
        .padding(22)
        .background(m3.primaryContainer, in: ExpressiveShape(corner: 40))
        .padding(.top, 4)
    }
}

struct SeasonSummaryCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3

    var body: some View {
        let season = Season.of(Date())
        let st = StatsBuilder.season(season, outings: model.data.outings, stamps: model.data.stamps)
        NavigationLink(value: Tool.stats) {
            M3Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(season.title).font(.m3TitleLarge).foregroundStyle(m3.onSurface)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(m3.onSurfaceVariant)
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        StatTile(value: "\(st.totals.days)", label: "giorni", icon: "calendar")
                        StatTile(value: Format.meters(season.kind == .winter ? st.totals.descent : st.totals.ascent),
                                 label: season.kind == .winter ? "discesa" : "salita", icon: season.kind == .winter ? "arrow.down.right" : "arrow.up.right")
                        if season.kind == .winter {
                            StatTile(value: "\(st.totals.runs)", label: "discese", icon: "figure.skiing.downhill")
                        } else {
                            StatTile(value: "\(st.totals.summits)", label: "cime", icon: "flag.fill")
                        }
                    }
                }
            }
        }
        .buttonStyle(PressableStyle())
    }
}

struct LastOutingCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3

    var body: some View {
        if let o = model.outingsSorted.first {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Ultima uscita")
                NavigationLink(value: o.id) {
                    VStack(spacing: 0) {
                        if o.hasTrack {
                            TrackMapView(outingID: o.id, interactive: false)
                                .frame(height: 150)
                                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous))
                        }
                        OutingRow(outing: o)
                    }
                }
                .buttonStyle(PressableStyle())
            }
        } else {
            M3Card(color: m3.secondaryContainer) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Il diario è vuoto", systemImage: "book.closed.fill").font(.m3TitleMedium)
                    Text("Importa lo storico da Strava o un file GPX per vedere qui le tue uscite.").font(.m3BodyMedium)
                    NavigationLink(value: Tool.importHub) {
                        Text("Importa").font(.m3LabelLarge).padding(.horizontal, 18).frame(height: 40)
                            .background(m3.primary, in: Capsule()).foregroundStyle(m3.onPrimary)
                    }
                }
                .foregroundStyle(m3.onSecondaryContainer)
            }
        }
    }
}

struct SummitsSummaryCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3

    var body: some View {
        let collected = model.collectedPeaks
        Button { model.tab = .peaks } label: {
            M3Card(color: m3.tertiaryContainer) {
                HStack(spacing: 16) {
                    IconBadge(icon: "flag.fill", tones: m3.tertiaryTones, size: 64, cookie: true, filled: true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(collected.count)").font(.m3DisplaySmall).contentTransition(.numericText())
                        Text(collected.count == 1 ? "cima nell'album" : "cime nell'album").font(.m3LabelLarge)
                        if let last = model.data.stamps.max(by: { $0.date < $1.date }) {
                            Text("Ultima: \(last.peakName), \(Format.dayMonth(last.date))").font(.m3BodySmall).lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .foregroundStyle(m3.onTertiaryContainer)
            }
        }
        .buttonStyle(PressableStyle())
    }
}

struct GarageAlertCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3

    var body: some View {
        let alerts = model.garageAlerts
        NavigationLink(value: Tool.garage) {
            M3Card(color: m3.warningContainer) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Sci Garage", systemImage: "wrench.and.screwdriver.fill").font(.m3TitleMedium)
                    ForEach(Array(alerts.prefix(3).enumerated()), id: \.offset) { _, a in
                        HStack {
                            Image(systemName: a.status.task.icon)
                            Text("\(a.status.task.title) · \(a.item.name)").font(.m3BodyMedium)
                            Spacer()
                            Text(a.status.isDue ? "da fare" : "tra \(a.status.remaining) gg").font(.m3LabelLarge)
                        }
                    }
                }
                .foregroundStyle(m3.onWarningContainer)
            }
        }
        .buttonStyle(PressableStyle())
    }
}

struct GoSummaryCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3

    var body: some View {
        NavigationLink(value: Tool.goNoGo) {
            M3Card {
                if let t = model.data.goTargets.first {
                    let window = GoWindow.default
                    let r = model.goResult(for: t, from: window.from, to: window.to)
                    HStack(spacing: 16) {
                        ScoreGauge(score: r.score, tones: tones(r), size: 92)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Go/No-Go").font(.m3LabelLarge).foregroundStyle(m3.onSurfaceVariant)
                            Text(r.verdictTitle).font(.m3HeadlineSmall).foregroundStyle(m3.onSurface)
                            Text("\(t.name) · \(window.label)").font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
                        }
                        Spacer()
                    }
                    .task { if model.goCache[t.id] == nil { await model.refreshGo(t) } }
                } else {
                    HStack(spacing: 16) {
                        IconBadge(icon: "gauge.with.dots.needle.50percent", tones: m3.primaryTones, size: 56, cookie: true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Go/No-Go").font(.m3TitleMedium).foregroundStyle(m3.onSurface)
                            Text("Aggiungi una meta per avere il punteggio di oggi.").font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
                        }
                    }
                }
            }
        }
        .buttonStyle(PressableStyle())
    }

    func tones(_ r: GoNoGoResult) -> Tones {
        switch r.verdict {
        case .go: return m3.successTones
        case .caution: return m3.warningTones
        case .noGo: return m3.errorTones
        }
    }
}

struct WrappedLinkCard: View {
    @Environment(\.m3) private var m3

    var body: some View {
        NavigationLink(value: Tool.wrapped) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles").font(.system(size: 28, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Il tuo anno in montagna").font(.m3TitleMedium)
                    Text("Guarda il riepilogo").font(.m3BodySmall)
                }
                Spacer()
                Image(systemName: "play.circle.fill").font(.system(size: 32))
            }
            .foregroundStyle(.white)
            .padding(20)
            .background(LinearGradient(colors: [Color(rgb: RGBColor(hex: "#6a1b9a")!), Color(rgb: RGBColor(hex: "#e65100")!)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Time window used by Go/No-Go: today 8–16, or tomorrow after 15:00.
struct GoWindow {
    let from: Date
    let to: Date
    let label: String

    static var `default`: GoWindow { forDay(offset: Calendar.current.component(.hour, from: Date()) >= 15 ? 1 : 0) }

    static func forDay(offset: Int) -> GoWindow {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date()))!
        let from = cal.date(bySettingHour: 8, minute: 0, second: 0, of: day)!
        let to = cal.date(bySettingHour: 16, minute: 0, second: 0, of: day)!
        let label = offset == 0 ? "oggi" : offset == 1 ? "domani" : Format.dayMonth(day)
        return GoWindow(from: from, to: to, label: label)
    }
}
