import SwiftUI
import MapKit
import CrestaCore

/// Go/No-Go: all saved places in a vertical list with today's score.
struct GoNoGoView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @State private var dayOffset = 0
    @State private var showAdd = false
    @State private var editing: GoTarget?

    var body: some View {
        let w = GoWindow.forDay(offset: dayOffset)
        ScreenScroll {
            if model.data.goTargets.isEmpty {
                EmptyStateView(icon: "gauge.with.dots.needle.50percent", title: "Aggiungi una meta",
                               message: "Una località, un comprensorio sciistico o una vetta. Cresta mette insieme bollettino valanghe, meteo, vento, zero termico, webcam e ultima nevicata in un punteggio da 0 a 10.")
            } else {
                SegmentedPills(options: [(0, "Oggi", "sun.max"), (1, "Domani", "sunrise"), (2, GoWindow.forDay(offset: 2).label.capitalized, "calendar")],
                               selection: $dayOffset)
                ForEach(Array(model.data.goTargets.enumerated()), id: \.element.id) { i, t in
                    NavigationLink(value: GoRoute(targetID: t.id, dayOffset: dayOffset)) {
                        GoTargetRow(target: t, window: w, isHome: i == 0)
                    }
                    .buttonStyle(PressableStyle())
                    .contextMenu {
                        if i > 0 { Button { model.moveGoTargetToTop(t.id) } label: { Label("Usa in Oggi", systemImage: "pin.fill") } }
                        Button { editing = t } label: { Label("Modifica", systemImage: "pencil") }
                        Button(role: .destructive) { model.deleteGoTarget(t.id) } label: { Label("Elimina", systemImage: "trash") }
                    }
                }
                Text("Tieni premuto su una meta per modificarla o mostrarla in Oggi.")
                    .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
            }
            PillButton(title: "Aggiungi meta", icon: "plus", tones: m3.primaryTones, filled: model.data.goTargets.isEmpty) { showAdd = true }
        }
        .navigationTitle("Go/No-Go")
        .navigationDestination(for: GoRoute.self) { GoTargetDetailView(targetID: $0.targetID, dayOffset: $0.dayOffset) }
        .refreshable { await model.refreshAllGo(force: true) }
        .task { await model.refreshAllGo(force: false) }
        .sheet(isPresented: $showAdd) { GoTargetEditor(target: nil).presentationCornerRadius(32) }
        .sheet(item: $editing) { GoTargetEditor(target: $0).presentationCornerRadius(32) }
    }
}

struct GoRoute: Hashable {
    let targetID: UUID
    let dayOffset: Int
}

extension GoNoGoResult {
    @MainActor func tones(_ m3: M3Theme) -> Tones {
        switch verdict {
        case .go: return m3.successTones
        case .caution: return m3.warningTones
        case .noGo: return m3.errorTones
        }
    }
}

struct GoTargetRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    let target: GoTarget
    let window: GoWindow
    let isHome: Bool

    var body: some View {
        let hasData = model.goCache[target.id]?.forecast != nil
        let r = model.goResult(for: target, from: window.from, to: window.to)
        let t = r.tones(m3)
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(hasData ? t.container : m3.surfaceContainerHigh)
                if hasData {
                    Text(Format.number(r.score, decimals: 1)).font(.m3TitleLarge).foregroundStyle(t.onContainer)
                        .contentTransition(.numericText(value: r.score))
                } else {
                    ProgressView()
                }
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(target.name).font(.m3TitleMedium).foregroundStyle(m3.onSurface).lineLimit(1)
                    if isHome { Image(systemName: "pin.fill").font(.system(size: 11)).foregroundStyle(m3.primary) }
                }
                Text("\(Int(target.elevation)) m · \(hasData ? r.verdictTitle : "carico i dati…")")
                    .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(m3.onSurfaceVariant)
        }
        .padding(12)
        .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .animation(.m3Spatial, value: r.score)
    }
}

/// One place: gauge, factors, bulletin, webcams.
struct GoTargetDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    let targetID: UUID
    @State var dayOffset: Int
    @State private var loading = false
    @State private var editing: GoTarget?

    var body: some View {
        if let t = model.data.goTargets.first(where: { $0.id == targetID }) {
            ScreenScroll {
                SegmentedPills(options: [(0, "Oggi", "sun.max"), (1, "Domani", "sunrise"), (2, GoWindow.forDay(offset: 2).label.capitalized, "calendar")],
                               selection: $dayOffset)
                content(t)
            }
            .navigationTitle(t.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editing = t } label: { Image(systemName: "pencil.circle") }
                }
            }
            .refreshable { await model.refreshGo(t) }
            .task(id: t.id) {
                if (model.goCache[t.id]?.fetchedAt.timeIntervalSinceNow ?? -99_999) < -1800 {
                    loading = true
                    await model.refreshGo(t)
                    loading = false
                }
            }
            .sheet(item: $editing) { GoTargetEditor(target: $0).presentationCornerRadius(32) }
        }
    }

    @ViewBuilder
    private func content(_ t: GoTarget) -> some View {
        let w = GoWindow.forDay(offset: dayOffset)
        let r = model.goResult(for: t, from: w.from, to: w.to)
        let tones = r.tones(m3)
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
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(WebcamRating.allCases, id: \.self) { rating in
                    Chip(title: rating.title, selected: model.webcamRatings[t.id] == rating) {
                        model.webcamRatings[t.id] = model.webcamRatings[t.id] == rating ? nil : rating
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

/// Add/edit a place: by locality name, by peak, or by point on the map.
struct GoTargetEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: GoTarget?

    enum Source: Hashable { case place, peak, map }

    @State private var source: Source = .place
    @State private var name = ""
    @State private var coordinate: Coordinate?
    @State private var peakID: String?
    @State private var elevation = 2000.0
    @State private var loadingElevation = false
    @State private var region = "IT-34"
    @State private var webcams: [String] = []
    @State private var newWebcam = ""
    @State private var query = ""
    @State private var results: [PlaceResult] = []
    @State private var searching = false
    @State private var showPeakPicker = false
    @State private var showMapPicker = false

    static let regions: [(String, String)] = [
        ("IT-34", "Veneto (ARPAV)"), ("IT-32-TN", "Trentino"), ("IT-32-BZ", "Alto Adige"), ("IT-36", "Friuli Venezia Giulia"),
        ("IT-25", "Lombardia"), ("IT-21", "Piemonte"), ("IT-23", "Valle d'Aosta"), ("IT-57", "Marche"), ("IT-65", "Abruzzo")
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Cerca per", selection: $source) {
                        Text("Località").tag(Source.place)
                        Text("Vetta").tag(Source.peak)
                        Text("Mappa").tag(Source.map)
                    }
                    .pickerStyle(.segmented)
                    switch source {
                    case .place:
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Es. Passo San Pellegrino, Cortina…", text: $query)
                                .autocorrectionDisabled()
                            if searching { ProgressView() }
                        }
                        ForEach(results) { r in
                            Button { pick(name: r.name, coordinate: r.coordinate, peakID: nil, elevation: nil) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name).foregroundStyle(.primary)
                                    if !r.subtitle.isEmpty { Text(r.subtitle).font(.footnote).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    case .peak:
                        Button { showPeakPicker = true } label: { Label("Scegli una vetta", systemImage: "mountain.2") }
                    case .map:
                        Button { showMapPicker = true } label: { Label("Scegli un punto sulla mappa", systemImage: "map") }
                    }
                } footer: {
                    Text("Per una zona sciistica cerca il nome del comprensorio o del passo; poi regola la quota su quella delle piste.")
                }

                if coordinate != nil {
                    Section("Meta") {
                        TextField("Nome", text: $name)
                        HStack {
                            Stepper("Quota: \(Int(elevation)) m", value: $elevation, in: 0...4800, step: 50)
                            if loadingElevation { ProgressView() }
                        }
                        if let c = coordinate {
                            Text(String(format: "%.4f, %.4f", c.lat, c.lon)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Picker("Zona", selection: $region) {
                        ForEach(Self.regions, id: \.0) { Text($0.1).tag($0.0) }
                        if !Self.regions.contains(where: { $0.0 == region }) { Text(region).tag(region) }
                    }
                    TextField("Codice zona (es. IT-34-BL-01)", text: $region)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                } header: { Text("Bollettino valanghe") } footer: {
                    Text("Bollettino EAWS in formato CAAML. Con il codice della micro-zona il grado è più preciso. Se il servizio non risponde viene letta la pagina web indicata nelle Impostazioni.")
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
                    Button("Salva") { save() }.disabled(coordinate == nil)
                }
            }
            .task(id: query) {
                guard source == .place, query.count >= 3 else { results = []; return }
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                searching = true
                results = await PlaceSearch.search(query)
                searching = false
            }
            .sheet(isPresented: $showPeakPicker) {
                PeakSearchSheet { p in pick(name: p.name, coordinate: p.coordinate, peakID: p.id, elevation: p.elevation) }
            }
            .sheet(isPresented: $showMapPicker) {
                MapPointPicker(start: coordinate) { c in pick(name: name.nonEmpty ?? "Punto sulla mappa", coordinate: c, peakID: nil, elevation: nil) }
            }
            .onAppear {
                if let t = target {
                    name = t.name; elevation = t.elevation; region = t.avalancheRegion; webcams = t.webcams
                    coordinate = t.coordinate; peakID = t.peakID
                } else if let last = model.data.goTargets.last {
                    region = last.avalancheRegion
                }
            }
        }
    }

    private func pick(name newName: String, coordinate c: Coordinate, peakID id: String?, elevation e: Double?) {
        name = newName
        coordinate = c
        peakID = id
        query = ""
        results = []
        if let e {
            elevation = e
        } else {
            loadingElevation = true
            Task {
                if let data = try? await Net.get(OpenMeteo.elevationURL(c)), let ele = OpenMeteo.decodeElevation(data) {
                    elevation = ele.rounded(to: 10)
                }
                loadingElevation = false
            }
        }
    }

    private func save() {
        guard let coord = coordinate else { return }
        var t = target ?? GoTarget(name: name, coordinate: coord, elevation: elevation)
        t.name = name.nonEmpty ?? "Meta"
        t.coordinate = coord
        t.elevation = elevation
        t.avalancheRegion = region.trimmingCharacters(in: .whitespaces).uppercased()
        t.webcams = webcams
        t.peakID = peakID
        if target == nil { model.addGoTarget(t) } else { model.updateGoTarget(t) }
        let saved = t
        Task { await model.refreshGo(saved) }
        dismiss()
    }
}

struct PlaceResult: Identifiable {
    let id = UUID()
    let name: String
    let subtitle: String
    let coordinate: Coordinate
}

/// Apple Maps place search (localities, passes, ski areas).
enum PlaceSearch {
    @MainActor static func search(_ q: String) async -> [PlaceResult] {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = q
        req.resultTypes = [.address, .pointOfInterest]
        guard let resp = try? await MKLocalSearch(request: req).start() else { return [] }
        return resp.mapItems.prefix(12).map { item in
            let c = item.placemark.coordinate
            let sub = [item.placemark.locality, item.placemark.administrativeArea, item.placemark.country]
                .compactMap { $0 }.filter { $0 != item.name }.joined(separator: ", ")
            return PlaceResult(name: item.name ?? q, subtitle: sub, coordinate: Coordinate(lat: c.latitude, lon: c.longitude))
        }
    }
}

/// Move the map, the pin stays in the middle.
struct MapPointPicker: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.m3) private var m3
    let start: Coordinate?
    let onPick: (Coordinate) -> Void
    @State private var position: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            Map(position: $position) { UserAnnotation() }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls { MapUserLocationButton(); MapScaleView() }
                .onMapCameraChange(frequency: .continuous) { center = $0.region.center }
                .overlay {
                    Image(systemName: "mappin")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(m3.error)
                        .offset(y: -18)
                        .allowsHitTesting(false)
                }
                .onAppear {
                    let c = start.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } ?? CLLocationCoordinate2D(latitude: 46.4, longitude: 11.8)
                    position = .region(MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)))
                }
                .navigationTitle("Sposta la mappa")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Usa questo punto") {
                            if let c = center { onPick(Coordinate(lat: c.latitude, lon: c.longitude)) }
                            dismiss()
                        }
                        .disabled(center == nil)
                    }
                }
        }
    }
}
