import SwiftUI
import CrestaCore

struct GoNoGoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @State private var selectedID: UUID?
    @State private var dayOffset = 0
    @State private var showAdd = false
    @State private var editing: GoTarget?
    @State private var loading = false

    private var target: GoTarget? {
        model.data.goTargets.first { $0.id == selectedID } ?? model.data.goTargets.first
    }

    var body: some View {
        ScreenScroll {
            if model.data.goTargets.isEmpty {
                EmptyStateView(icon: "gauge.with.dots.needle.50percent", title: "Aggiungi una meta",
                               message: "Scegli una vetta o una zona: Cresta mette insieme bollettino valanghe, meteo, vento, zero termico, webcam e ultima nevicata in un punteggio da 0 a 10.")
                PillButton(title: "Aggiungi meta", icon: "plus", tones: m3.primaryTones) { showAdd = true }
            } else if let t = target {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.data.goTargets) { g in
                            Chip(title: g.name, icon: "mappin", selected: g.id == t.id) { selectedID = g.id }
                        }
                        Chip(title: "Aggiungi", icon: "plus", selected: false) { showAdd = true }
                    }
                }
                SegmentedPills(options: [(0, "Oggi", "sun.max"), (1, "Domani", "sunrise"), (2, GoWindow.forDay(offset: 2).label.capitalized, "calendar")],
                               selection: $dayOffset)
                content(t)
            }
        }
        .navigationTitle("Go/No-Go")
        .toolbar {
            if let t = target {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { editing = t } label: { Label("Modifica meta", systemImage: "pencil") }
                        Button(role: .destructive) { model.deleteGoTarget(t.id); selectedID = nil } label: { Label("Elimina meta", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .refreshable { if let t = target { await model.refreshGo(t) } }
        .task(id: target?.id) {
            guard let t = target else { return }
            if (model.goCache[t.id]?.fetchedAt.timeIntervalSinceNow ?? -99_999) < -1800 {
                loading = true
                await model.refreshGo(t)
                loading = false
            }
        }
        .sheet(isPresented: $showAdd) { GoTargetEditor(target: nil).presentationCornerRadius(32) }
        .sheet(item: $editing) { GoTargetEditor(target: $0).presentationCornerRadius(32) }
    }

    @ViewBuilder
    private func content(_ t: GoTarget) -> some View {
        let w = GoWindow.forDay(offset: dayOffset)
        let r = model.goResult(for: t, from: w.from, to: w.to)
        let tones: Tones = r.verdict == .go ? m3.successTones : r.verdict == .caution ? m3.warningTones : m3.errorTones
        VStack(spacing: 14) {
            ScoreGauge(score: r.score, tones: tones, size: 200)
            Text(r.verdictTitle).font(.m3DisplaySmall).foregroundStyle(tones.onContainer)
            Text("\(t.name) · \(Int(t.elevation)) m · \(w.label) 8–16").font(.m3BodyMedium).foregroundStyle(tones.onContainer.opacity(0.8))
            if loading { ProgressView() }
            if let c = model.goCache[t.id] {
                Text("Aggiornato \(Format.dayMonth(c.fetchedAt)) alle \(Format.time(c.fetchedAt))").font(.m3LabelSmall).foregroundStyle(tones.onContainer.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(tones.container, in: ExpressiveShape(corner: 44))
        .animation(.m3Spatial, value: r.score)

        SectionTitle("Fattori", trailing: "tocca per includere/escludere")
        ForEach(GoFactor.allCases) { f in
            let enabled = model.data.settings.goFactors.contains(f)
            let fs = r.factors.first { $0.factor == f }
            FactorRow(factor: f, score: fs, enabled: enabled, winterOnlySkipped: f.winterOnly && model.seasonKind != .winter) {
                model.mutate { d in
                    if d.settings.goFactors.contains(f) { d.settings.goFactors.remove(f) } else { d.settings.goFactors.insert(f) }
                }
            }
        }

        if let a = model.goCache[t.id]?.avalanche {
            AvalancheCard(report: a)
        }

        if !t.webcams.isEmpty && model.data.settings.goFactors.contains(.webcam) {
            SectionTitle("Webcam")
            ForEach(t.webcams, id: \.self) { url in
                AsyncImage(url: URL(string: url)) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFit()
                    case .failure: Label("Immagine non disponibile", systemImage: "wifi.slash").frame(height: 120)
                    default: ProgressView().frame(height: 160)
                    }
                }
                .frame(maxWidth: .infinity)
                .background(m3.surfaceContainerHigh)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            }
            Text("Com'è la visibilità?").font(.m3TitleSmall).foregroundStyle(m3.onSurface)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WebcamRating.allCases, id: \.self) { rating in
                        Chip(title: rating.title, selected: model.webcamRatings[t.id] == rating) {
                            model.webcamRatings[t.id] = model.webcamRatings[t.id] == rating ? nil : rating
                        }
                    }
                }
            }
        }
        Text("Il punteggio è un aiuto alla decisione, non sostituisce la lettura completa del bollettino né la valutazione sul posto.")
            .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
    }
}

struct FactorRow: View {
    @Environment(\.m3) private var m3
    let factor: GoFactor
    let score: FactorScore?
    let enabled: Bool
    let winterOnlySkipped: Bool
    let toggle: () -> Void

    var body: some View {
        let tones: Tones = {
            guard enabled, let s = score?.score else { return m3.neutral }
            if score?.veto == true || s < 4 { return m3.errorTones }
            if s < 7 { return m3.warningTones }
            return m3.successTones
        }()
        Button(action: toggle) {
            HStack(spacing: 14) {
                IconBadge(icon: factor.icon, tones: tones, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(factor.title).font(.m3TitleSmall).foregroundStyle(m3.onSurface)
                    Text(!enabled ? "Escluso dal punteggio" : winterOnlySkipped ? "Solo in inverno" : score?.detail ?? "—")
                        .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant).lineLimit(2)
                }
                Spacer()
                if enabled, let s = score?.score {
                    Text(Format.number(s, decimals: 1)).font(.m3TitleLarge).foregroundStyle(tones.onContainer)
                        .padding(.horizontal, 10).padding(.vertical, 4).background(tones.container, in: Capsule())
                }
                Image(systemName: enabled ? "checkmark.circle.fill" : "circle").font(.system(size: 22))
                    .foregroundStyle(enabled ? m3.primary : m3.outline)
            }
            .padding(12)
            .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .opacity(enabled ? 1 : 0.6)
        }
        .buttonStyle(PressableStyle())
    }
}

struct AvalancheCard: View {
    @Environment(\.m3) private var m3
    let report: AvalancheReport

    var body: some View {
        M3Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Bollettino valanghe", systemImage: "exclamationmark.triangle.fill").font(.m3TitleSmall)
                    Spacer()
                    Text(report.source).font(.m3LabelSmall).foregroundStyle(m3.onSurfaceVariant)
                }
                if let lv = report.maxLevel {
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8).fill(Color(rgb: RGBColor(hex: lv.colorHex)!)).frame(width: 36, height: 36)
                            .overlay(Text("\(lv.rawValue)").font(.m3TitleMedium).foregroundStyle(lv == .veryHigh ? .white : .black))
                        VStack(alignment: .leading) {
                            Text(lv.title).font(.m3TitleMedium)
                            if let th = report.threshold, let a = report.levelAbove, let b = report.levelBelow {
                                Text("Sopra \(th) m: \(a.rawValue) · sotto: \(b.rawValue)").font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
                            }
                        }
                    }
                }
                if let name = report.regionName { Text(name).font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant) }
                if !report.problems.isEmpty {
                    Text("Problemi: " + report.problems.joined(separator: ", ")).font(.m3BodyMedium)
                }
                if let h = report.highlights, !h.isEmpty { Text(h).font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant) }
            }
            .foregroundStyle(m3.onSurface)
        }
    }
}

struct GoTargetEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: GoTarget?
    @State private var name = ""
    @State private var peak: Peak?
    @State private var elevation = 2000.0
    @State private var region = "IT-34"
    @State private var webcams: [String] = []
    @State private var newWebcam = ""
    @State private var showPicker = false

    static let regions: [(String, String)] = [
        ("IT-34", "Veneto (ARPAV)"), ("IT-32-TN", "Trentino"), ("IT-32-BZ", "Alto Adige"), ("IT-36", "Friuli Venezia Giulia"),
        ("IT-25", "Lombardia"), ("IT-21", "Piemonte"), ("IT-23", "Valle d'Aosta"), ("IT-57", "Marche"), ("IT-65", "Abruzzo")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Meta") {
                    Button { showPicker = true } label: {
                        HStack { Text("Vetta"); Spacer(); Text(peak?.name ?? "Scegli").foregroundStyle(.secondary) }
                    }
                    TextField("Nome", text: $name)
                    Stepper("Quota: \(Int(elevation)) m", value: $elevation, in: 0...4800, step: 50)
                }
                Section {
                    Picker("Zona", selection: $region) {
                        ForEach(Self.regions, id: \.0) { Text($0.1).tag($0.0) }
                        if !Self.regions.contains(where: { $0.0 == region }) { Text(region).tag(region) }
                    }
                    TextField("Codice zona (es. IT-34-BL-01)", text: $region)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                } header: { Text("Bollettino valanghe") } footer: {
                    Text("Bollettino EAWS in formato CAAML. Con il codice della micro-zona (es. IT-34-BL-01) il grado è più preciso. Se il servizio non risponde viene letta la pagina web indicata nelle Impostazioni.")
                }
                Section("Webcam (URL di un'immagine)") {
                    ForEach(webcams, id: \.self) { Text($0).lineLimit(1) }
                        .onDelete { webcams.remove(atOffsets: $0) }
                    HStack {
                        TextField("https://…/webcam.jpg", text: $newWebcam).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Aggiungi") {
                            if let u = newWebcam.nonEmpty { webcams.append(u); newWebcam = "" }
                        }
                    }
                }
            }
            .navigationTitle(target == nil ? "Nuova meta" : "Modifica meta")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") { save() }.disabled(peak == nil && target == nil)
                }
            }
            .sheet(isPresented: $showPicker) {
                PeakSearchSheet { p in
                    peak = p
                    if name.isEmpty || name == target?.name { name = p.name }
                    if let e = p.elevation { elevation = e }
                }
            }
            .onAppear {
                if let t = target {
                    name = t.name; elevation = t.elevation; region = t.avalancheRegion; webcams = t.webcams
                    peak = t.peakID.flatMap { model.peakIndex.peak(id: $0) }
                }
            }
        }
    }

    private func save() {
        let coord = peak?.coordinate ?? target?.coordinate ?? Coordinate(lat: 46, lon: 11)
        var t = target ?? GoTarget(name: name, coordinate: coord, elevation: elevation)
        t.name = name.nonEmpty ?? peak?.name ?? "Meta"
        t.coordinate = coord
        t.elevation = elevation
        t.avalancheRegion = region.trimmingCharacters(in: .whitespaces).uppercased()
        t.webcams = webcams
        t.peakID = peak?.id ?? t.peakID
        if target == nil { model.addGoTarget(t) } else { model.updateGoTarget(t) }
        let saved = t
        Task { await model.refreshGo(saved) }
        dismiss()
    }
}
