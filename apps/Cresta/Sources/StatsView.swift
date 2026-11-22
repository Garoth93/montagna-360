import SwiftUI
import Charts
import CrestaCore

struct StatsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @State private var season: Season = Season.of(Date())

    var body: some View {
        let seasons = Array(Set(StatsBuilder.seasons(model.data.outings) + [Season.of(Date())])).sorted(by: >)
        let st = StatsBuilder.season(season, outings: model.data.outings, stamps: model.data.stamps)
        ScreenScroll {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons) { s in Chip(title: s.title, icon: s.kind == .winter ? "snowflake" : "sun.max", selected: s == season) { season = s } }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(st.totals.days)").font(.m3DisplayLarge).foregroundStyle(m3.onPrimaryContainer).contentTransition(.numericText())
                Text(st.totals.days == 1 ? "giorno in montagna" : "giorni in montagna").font(.m3TitleMedium).foregroundStyle(m3.onPrimaryContainer)
                Text("\(st.totals.outings) uscite · \(Format.duration(st.totals.moving)) in movimento").font(.m3BodyMedium).foregroundStyle(m3.onPrimaryContainer.opacity(0.8))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(m3.primaryContainer, in: ExpressiveShape(corner: 40))
            .animation(.m3Spatial, value: season)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(value: Format.km(st.totals.distance), label: "distanza", icon: "point.topleft.down.to.point.bottomright.curvepath")
                StatTile(value: Format.meters(st.totals.ascent), label: "dislivello positivo", icon: "arrow.up.right")
                StatTile(value: Format.meters(st.totals.descent), label: "dislivello negativo", icon: "arrow.down.right")
                StatTile(value: Format.speed(st.totals.maxSpeed), label: "velocità massima", icon: "gauge.with.dots.needle.67percent")
                StatTile(value: Format.meters(st.totals.maxElevation), label: "quota più alta", icon: "mountain.2.fill")
                if season.kind == .winter {
                    StatTile(value: "\(st.totals.runs)", label: "discese in pista", icon: "figure.skiing.downhill")
                }
                StatTile(value: "\(st.totals.summits)", label: "cime timbrate", icon: "flag.fill", tones: m3.tertiaryTones)
                StatTile(value: "\(st.totals.newSummits)", label: "cime nuove", icon: "sparkles", tones: m3.tertiaryTones)
            }

            if !st.daysByMonth.isEmpty {
                SectionTitle("Giorni per mese")
                M3Card {
                    Chart(months(for: season), id: \.self) { m in
                        BarMark(x: .value("Mese", String(Format.monthName(m).prefix(3)).capitalized), y: .value("Giorni", st.daysByMonth[m] ?? 0))
                            .foregroundStyle(m3.primary.gradient)
                            .cornerRadius(8)
                    }
                    .frame(height: 180)
                }
            }

            if !st.byKind.isEmpty {
                SectionTitle("Per attività")
                ForEach(st.byKind, id: \.kind) { k in
                    HStack(spacing: 12) {
                        IconBadge(icon: k.kind.icon, tones: m3.tones(for: k.kind), size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.kind.title).font(.m3TitleSmall).foregroundStyle(m3.onSurface)
                            Text("\(Format.km(k.totals.distance)) · \(Format.meters(k.totals.ascent)) D+").font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
                        }
                        Spacer()
                        Text(Format.plural(k.totals.days, "giorno", "giorni")).font(.m3LabelLarge).foregroundStyle(m3.onSurface)
                    }
                    .padding(12)
                    .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }

            let records: [(String, String, Outing?, String)] = [
                ("Più lunga", "point.topleft.down.to.point.bottomright.curvepath", st.longest, st.longest.map { Format.km($0.stats.distance) } ?? ""),
                ("Più dislivello", "arrow.up.right", st.biggestClimb, st.biggestClimb.map { Format.meters($0.stats.ascent) } ?? ""),
                ("Più veloce", "hare.fill", st.fastest, st.fastest.map { Format.speed($0.stats.maxSpeed) } ?? ""),
                ("Più in alto", "mountain.2.fill", st.highest, st.highest.flatMap { $0.stats.maxElevation }.map { Format.meters($0) } ?? "")
            ]
            if st.totals.outings > 0 {
                SectionTitle("Record di stagione")
                ForEach(records, id: \.0) { r in
                    if let o = r.2 {
                        NavigationLink(value: o.id) {
                            HStack(spacing: 12) {
                                Image(systemName: r.1).frame(width: 28).foregroundStyle(m3.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.0).font(.m3LabelMedium).foregroundStyle(m3.onSurfaceVariant)
                                    Text(o.name).font(.m3TitleSmall).foregroundStyle(m3.onSurface).lineLimit(1)
                                }
                                Spacer()
                                Text(r.3).font(.m3TitleMedium).foregroundStyle(m3.onSurface)
                            }
                            .padding(12)
                            .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            NavigationLink(value: Tool.wrapped) {
                Label("Riepilogo dell'anno", systemImage: "sparkles").frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
        }
        .navigationTitle("Statistiche")
    }

    private func months(for s: Season) -> [Int] { s.kind == .winter ? [11, 12, 1, 2, 3, 4] : [5, 6, 7, 8, 9, 10] }
}

/// End-of-year recap: full screen story cards.
struct WrappedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var page = 0
    @State private var appeared = false

    var body: some View {
        let years = Array(Set(model.data.outings.map { Calendar.current.component(.year, from: $0.start) })).sorted(by: >)
        let cards = Wrapped.cards(year: year, outings: model.data.outings, stamps: model.data.stamps)
        VStack(spacing: 12) {
            if years.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(years, id: \.self) { y in Chip(title: String(y), selected: y == year) { year = y; page = 0 } }
                    }
                    .padding(.horizontal, 16)
                }
            }
            if cards.isEmpty {
                EmptyStateView(icon: "sparkles", title: "Nessun dato per il \(year)", message: "Il riepilogo si riempie con le uscite dell'anno.")
                Spacer()
            } else {
                TabView(selection: $page) {
                    ForEach(Array(cards.enumerated()), id: \.element.id) { i, c in
                        WrappedCardView(card: c, visible: page == i)
                            .padding(.horizontal, 16)
                            .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }
        }
        .background(m3.surface)
        .navigationTitle("Il tuo \(String(year))")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !years.contains(year), let y = years.first { year = y }
        }
    }
}

struct WrappedCardView: View {
    let card: WrappedCard
    let visible: Bool
    @State private var shown = false

    var body: some View {
        let base = Color(rgb: RGBColor(hex: card.colorHex) ?? RGBColor(red: 0.2, green: 0.3, blue: 0.6))
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Image(systemName: card.icon)
                .font(.system(size: 64, weight: .bold))
                .scaleEffect(shown ? 1 : 0.3)
                .rotationEffect(.degrees(shown ? 0 : -30))
            Text(card.eyebrow.uppercased()).font(.m3LabelLarge).tracking(2).opacity(0.85)
            Text(card.value)
                .font(.system(size: card.value.count > 12 ? 44 : 72, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.4)
                .lineLimit(2)
                .offset(y: shown ? 0 : 40)
            Text(card.caption).font(.m3TitleLarge).opacity(0.9)
            Spacer()
            Spacer()
        }
        .foregroundStyle(.white)
        .opacity(shown ? 1 : 0)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            ZStack {
                LinearGradient(colors: [base, base.mix(with: .black, by: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                CookieShape(lobes: 10, depth: 0.08).fill(.white.opacity(0.08)).frame(width: 420, height: 420).offset(x: 140, y: -220)
                    .rotationEffect(.degrees(shown ? 20 : 0))
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .padding(.bottom, 36)
        .onChange(of: visible, initial: true) { _, v in
            if v { withAnimation(.spring(response: 0.6, dampingFraction: 0.65)) { shown = true } } else { shown = false }
        }
    }
}
