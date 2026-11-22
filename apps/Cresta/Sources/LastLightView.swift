import SwiftUI
import CrestaCore

/// "Ultima Luce": sunset, dark and the latest time to turn back.
struct LastLightView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    var initialPeakID: String?
    @State private var peak: Peak?
    @State private var departure = Date()
    @State private var startElevation = 1200.0
    @State private var distanceKm = 5.0
    @State private var mode: SummitMode = .foot
    @State private var showPicker = false
    @State private var useLearned = true
    @State private var notified = false

    private var pace: LastLight.Pace {
        guard useLearned else { return .default(for: mode) }
        let stats = model.data.outings.filter { $0.kind.summitMode == mode && $0.stats.ascent > 200 }.map(\.stats)
        return .learned(from: stats, mode: mode)
    }

    private var plan: LastLightPlan? {
        guard let peak else { return nil }
        return LastLight.plan(peak: peak, departure: departure, startElevation: startElevation, distanceKm: distanceKm, mode: mode, pace: pace,
                              safetyMargin: model.data.settings.lastLightMargin * 60)
    }

    var body: some View {
        ScreenScroll {
            Button { showPicker = true } label: {
                HStack(spacing: 14) {
                    IconBadge(icon: "mountain.2.fill", tones: m3.tertiaryTones, size: 52, cookie: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(peak?.name ?? "Scegli la vetta").font(.m3TitleLarge).foregroundStyle(m3.onSurface)
                        Text(peak?.elevation.map { Format.meters($0) } ?? "Tocca per cercare").font(.m3BodyMedium).foregroundStyle(m3.onSurfaceVariant)
                    }
                    Spacer()
                    Image(systemName: "magnifyingglass").foregroundStyle(m3.onSurfaceVariant)
                }
                .padding(16)
                .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
            .buttonStyle(PressableStyle())

            M3Card {
                VStack(spacing: 12) {
                    DatePicker("Partenza", selection: $departure).font(.m3BodyLarge)
                    HStack {
                        Text("Modalità").font(.m3BodyLarge)
                        Spacer()
                        Picker("", selection: $mode) {
                            ForEach(SummitMode.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                        }
                    }
                    Stepper("Quota di partenza: \(Int(startElevation)) m", value: $startElevation, in: 0...4000, step: 50)
                    Stepper("Distanza fino in vetta: \(Format.number(distanceKm, decimals: 1)) km", value: $distanceKm, in: 0.5...40, step: 0.5)
                    Toggle("Usa il tuo passo dalle uscite passate", isOn: $useLearned)
                    Text("Salita \(Int(pace.upRate)) m/h · discesa \(Int(pace.downRate)) m/h")
                        .font(.m3LabelMedium).foregroundStyle(m3.onSurfaceVariant).frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let plan, let peak {
                result(plan, peak)
            }
        }
        .navigationTitle("Ultima Luce")
        .sheet(isPresented: $showPicker) {
            PeakSearchSheet { p in
                peak = p
                if let e = p.elevation { startElevation = max(0, (e - 1000).rounded(to: 50)) }
            }
            .presentationCornerRadius(32)
        }
        .onAppear {
            if peak == nil, let id = initialPeakID { peak = model.peakIndex.peak(id: id) }
            mode = model.seasonKind == .winter ? .ski : .foot
        }
    }

    @ViewBuilder
    private func result(_ plan: LastLightPlan, _ peak: Peak) -> some View {
        let ok = (plan.slack ?? 0) >= 0
        let tones = ok ? m3.successTones : m3.errorTones
        VStack(alignment: .leading, spacing: 14) {
            Text(ok ? "Ce la fai con la luce" : "Rischi di rientrare al buio").font(.m3HeadlineSmall)
            if let turn = plan.turnaround {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ora limite per scendere").font(.m3LabelLarge)
                    Text(Format.time(turn)).font(.m3DisplayLarge).contentTransition(.numericText())
                }
            }
            if let slack = plan.slack {
                Text(slack >= 0 ? "Margine di \(Format.duration(slack)) sull'arrivo in vetta previsto"
                     : "Arriveresti in vetta \(Format.duration(-slack)) dopo l'ora limite")
                    .font(.m3BodyMedium)
            }
        }
        .foregroundStyle(tones.onContainer)
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tones.container, in: ExpressiveShape(corner: 40))
        .animation(.m3Spatial, value: ok)

        SunTimeline(plan: plan)

        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatTile(value: Format.time(plan.summitArrival), label: "arrivo in vetta (\(Format.duration(plan.ascentDuration)))", icon: "flag.fill")
            StatTile(value: Format.time(plan.expectedReturn), label: "rientro previsto (\(Format.duration(plan.descentDuration)) di discesa)", icon: "car.fill")
            StatTile(value: plan.sunset.map { Format.time($0) } ?? "—", label: "tramonto", icon: "sunset.fill", tones: m3.warningTones)
            StatTile(value: plan.civilDusk.map { Format.time($0) } ?? "—", label: "buio (fine crepuscolo)", icon: "moon.stars.fill", tones: m3.tertiaryTones)
        }

        PillButton(title: notified ? "Avviso impostato" : "Avvisami prima dell'ora limite", icon: notified ? "bell.badge.fill" : "bell.fill",
                   tones: m3.primaryTones) {
            Task { notified = await model.scheduleLastLight(plan, peakName: peak.name) }
        }
        if notified {
            Button("Annulla avviso") { model.cancelLastLight(); notified = false }.frame(maxWidth: .infinity)
        }
        Text("Stime basate su passo medio e margine di sicurezza di \(Int(model.data.settings.lastLightMargin)) minuti. Valuta sempre le condizioni reali.")
            .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
    }
}

/// Horizontal timeline: departure → summit → turnaround → sunset → dusk.
struct SunTimeline: View {
    @Environment(\.m3) private var m3
    let plan: LastLightPlan

    var body: some View {
        let events: [(Date, String, String, Color)] = [
            (plan.departure, "Partenza", "figure.walk", m3.primary),
            (plan.summitArrival, "Vetta", "flag.fill", m3.tertiary),
            plan.turnaround.map { ($0, "Limite", "exclamationmark.triangle.fill", m3.error) },
            plan.sunset.map { ($0, "Tramonto", "sunset.fill", m3.warning) },
            plan.civilDusk.map { ($0, "Buio", "moon.fill", m3.onSurfaceVariant) }
        ].compactMap { $0 }.sorted { $0.0 < $1.0 }
        let start = events.first?.0 ?? plan.departure
        let end = events.last?.0 ?? plan.departure.addingTimeInterval(3600)
        let span = max(1, end.timeIntervalSince(start))
        M3Card {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(colors: [Color.yellow.opacity(0.5), Color.orange.opacity(0.6), Color.indigo.opacity(0.7)],
                                                  startPoint: .leading, endPoint: .trailing)).frame(height: 10)
                    ForEach(Array(events.enumerated()), id: \.offset) { i, e in
                        let x = g.size.width * e.0.timeIntervalSince(start) / span
                        VStack(spacing: 4) {
                            if i % 2 == 0 { label(e) }
                            Image(systemName: e.2).font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 26, height: 26).background(e.3, in: Circle())
                            if i % 2 == 1 { label(e) }
                        }
                        .fixedSize()
                        .position(x: min(max(x, 24), g.size.width - 24), y: g.size.height / 2 + (i % 2 == 0 ? -14 : 14))
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 110)
        }
    }

    private func label(_ e: (Date, String, String, Color)) -> some View {
        VStack(spacing: 0) {
            Text(e.1).font(.m3LabelSmall)
            Text(Format.time(e.0)).font(.m3LabelMedium)
        }
        .foregroundStyle(m3.onSurface)
    }
}

/// Search in the offline peak database.
struct PeakSearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @Environment(\.dismiss) private var dismiss
    let onPick: (Peak) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    let recent = model.collectedPeaks.prefix(20).compactMap { c in model.peakIndex.peak(id: c.peakID) }
                    if !recent.isEmpty {
                        Section("Le tue cime") { ForEach(recent) { row($0) } }
                    }
                } else {
                    ForEach(model.peakIndex.search(query)) { row($0) }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Nome della vetta")
            .navigationTitle("Vetta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } } }
        }
    }

    private func row(_ p: Peak) -> some View {
        Button { onPick(p); dismiss() } label: {
            HStack {
                Text(p.name).foregroundStyle(m3.onSurface)
                Spacer()
                if let e = p.elevation { Text(Format.meters(e)).foregroundStyle(m3.onSurfaceVariant) }
            }
        }
    }
}

extension Double {
    func rounded(to step: Double) -> Double { (self / step).rounded() * step }
}
