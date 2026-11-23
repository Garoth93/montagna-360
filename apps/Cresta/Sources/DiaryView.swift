import SwiftUI
import PhotosUI
import CrestaCore

struct DiaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @State private var season: Season?
    @State private var kind: ActivityKind?
    @State private var query = ""
    @State private var showAdd = false
    @State private var mountainOnly = false

    private var filtered: [Outing] {
        let q = Search.fold(query)
        let minAscent = model.data.settings.mountainMinAscent
        return model.outingsSorted.filter { o in
            (!mountainOnly || MountainFilter.isMountain(o, minAscent: minAscent))
                && (season == nil || o.season == season) && (kind == nil || o.kind == kind)
                && (q.isEmpty || Search.fold(o.name).contains(q) || Search.fold(o.note).contains(q))
        }
    }

    private var groups: [(String, [Outing])] {
        var out: [(String, [Outing])] = []
        let cal = Calendar.current
        for o in filtered {
            let c = cal.dateComponents([.year, .month], from: o.start)
            let key = "\(Format.monthName(c.month ?? 1).capitalized) \(c.year ?? 0)"
            if out.last?.0 == key { out[out.count - 1].1.append(o) } else { out.append((key, [o])) }
        }
        return out
    }

    var body: some View {
        let seasons = StatsBuilder.seasons(model.data.outings)
        let kinds = Array(Set(model.data.outings.map(\.kind))).sorted { $0.title < $1.title }
        ScreenScroll {
            if model.data.outings.isEmpty {
                EmptyStateView(icon: "book.pages.fill", title: "Nessuna uscita", message: "Importa lo storico da Strava o un file GPX/FIT, oppure aggiungi un'uscita a mano.")
                NavigationLink(value: Tool.importHub) {
                    Label("Importa", systemImage: "square.and.arrow.down").font(.m3TitleMedium).frame(maxWidth: .infinity, minHeight: 52)
                        .background(m3.primary, in: Capsule()).foregroundStyle(m3.onPrimary)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Chip(title: "Tutte", selected: season == nil) { season = nil }
                        ForEach(seasons) { s in Chip(title: s.title, selected: season == s) { season = season == s ? nil : s } }
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Chip(title: "Solo montagna", icon: "mountain.2.fill", selected: mountainOnly) { mountainOnly.toggle() }
                        ForEach(kinds) { k in Chip(title: k.title, icon: k.icon, selected: kind == k) { kind = kind == k ? nil : k } }
                    }
                }
                if let season {
                    SeasonStatsStrip(season: season)
                }
                ForEach(groups, id: \.0) { g in
                    SectionTitle(g.0, trailing: Format.plural(g.1.count, "uscita", "uscite"))
                    ForEach(g.1) { o in
                        NavigationLink(value: o.id) { OutingRow(outing: o) }.buttonStyle(PressableStyle())
                    }
                }
                if filtered.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: "Nessun risultato", message: "Cambia i filtri o la ricerca.")
                }
            }
        }
        .searchable(text: $query, prompt: "Cerca uscite")
        .navigationTitle("Diario")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showAdd = true } label: { Label("Nuova uscita a mano", systemImage: "square.and.pencil") }
                    NavigationLink(value: Tool.importHub) { Label("Importa", systemImage: "square.and.arrow.down") }
                    NavigationLink(value: Tool.stats) { Label("Statistiche", systemImage: "chart.bar.fill") }
                    NavigationLink(value: Tool.wrapped) { Label("Riepilogo dell'anno", systemImage: "sparkles") }
                } label: { Image(systemName: "plus") }
            }
        }
        .navigationDestination(for: UUID.self) { OutingDetailView(outingID: $0) }
        .navigationDestination(for: Tool.self) { $0.destination }
        .sheet(isPresented: $showAdd) { ManualOutingSheet().presentationCornerRadius(32) }
    }
}

struct SeasonStatsStrip: View {
    @Environment(AppModel.self) private var model
    let season: Season

    var body: some View {
        let st = StatsBuilder.season(season, outings: model.data.outings, stamps: model.data.stamps)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatTile(value: "\(st.totals.days)", label: "giorni")
            StatTile(value: Format.km(st.totals.distance), label: "distanza")
            StatTile(value: Format.meters(st.totals.ascent), label: "dislivello +")
        }
    }
}

struct OutingDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @Environment(\.dismiss) private var dismiss
    let outingID: UUID
    @State private var track: Track?
    @State private var note = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var confirmDelete = false
    @State private var showSummitPicker = false
    @State private var showRename = false
    @State private var newName = ""
    @State private var gpx: DataFileDocument?
    @State private var loadingWeather = false

    var body: some View {
        if let o = model.outing(outingID) {
            content(o)
        } else {
            EmptyStateView(icon: "questionmark", title: "Uscita non trovata", message: "")
        }
    }

    @ViewBuilder
    private func content(_ o: Outing) -> some View {
        let t = m3.tones(for: o.kind)
        ScreenScroll {
            if o.hasTrack {
                TrackMapView(outingID: o.id)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(o.name).font(.m3HeadlineMedium).foregroundStyle(m3.onSurface)
                Text("\(Format.dayMonthYear(o.start).capitalized) · \(Format.time(o.start)) · \(o.source.title)")
                    .font(.m3BodyMedium).foregroundStyle(m3.onSurfaceVariant)
                KindMenu(outing: o)
            }
            statsGrid(o, t)
            if let track, track.points.contains(where: { $0.ele != nil }) {
                M3Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Profilo altimetrico").font(.m3TitleSmall).foregroundStyle(m3.onSurface)
                        ElevationProfile(track: track).frame(height: 120)
                    }
                }
            }
            if o.kind == .resortSki || o.kind == .snowboard, let track {
                SkiDaySection(track: track, area: o.area)
            }
            weatherCard(o)
            summitsSection(o)
            notesSection(o)
            photosSection(o)
            gearSection(o)
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Elimina uscita", systemImage: "trash").frame(maxWidth: .infinity, minHeight: 48)
            }
            .buttonStyle(.bordered)
            .tint(m3.error)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { newName = o.name; showRename = true } label: { Label("Rinomina", systemImage: "pencil") }
                    if let track, !track.isEmpty {
                        Button { gpx = DataFileDocument(data: Data(GPXWriter.gpx(track, name: o.name).utf8)) } label: {
                            Label("Esporta GPX", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button { model.resetBackpackChecks(for: o) } label: { Label("Prepara lo zaino per questa uscita", systemImage: "backpack") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .task(id: o.id) {
            note = o.note
            let id = o.id
            track = await Task.detached { TrackStore.load(id) }.value
        }
        .onChange(of: photoItems) { _, items in
            Task {
                for item in items {
                    if let d = try? await item.loadTransferable(type: Data.self) { model.addPhoto(d, to: o.id) }
                }
                photoItems = []
            }
        }
        .confirmationDialog("Eliminare l'uscita?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina", role: .destructive) { dismiss(); model.deleteOuting(o.id) }
        } message: { Text("Traccia, foto e timbri automatici verranno rimossi.") }
        .alert("Nome dell'uscita", isPresented: $showRename) {
            TextField("Nome", text: $newName)
            Button("Salva") { var c = o; c.name = newName.nonEmpty ?? o.name; model.update(c) }
            Button("Annulla", role: .cancel) {}
        }
        .sheet(isPresented: $showSummitPicker) { SummitPickerSheet(outing: o, track: track).presentationCornerRadius(32) }
        .fileExporter(isPresented: Binding(get: { gpx != nil }, set: { if !$0 { gpx = nil } }), document: gpx,
                      contentType: .xml, defaultFilename: "\(o.name).gpx") { _ in gpx = nil }
    }

    private func statsGrid(_ o: Outing, _ t: Tones) -> some View {
        let s = o.stats
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            StatTile(value: Format.km(s.distance), label: "distanza", icon: "point.topleft.down.to.point.bottomright.curvepath", tones: t)
            StatTile(value: Format.meters(s.ascent), label: "dislivello +", icon: "arrow.up.right", tones: t)
            StatTile(value: Format.meters(s.descent), label: "dislivello −", icon: "arrow.down.right", tones: t)
            StatTile(value: Format.clock(s.moving > 0 ? s.moving : s.elapsed), label: "in movimento", icon: "timer")
            StatTile(value: Format.clock(s.elapsed), label: "tempo totale", icon: "clock")
            StatTile(value: Format.speed(s.maxSpeed), label: "velocità max", icon: "gauge.with.dots.needle.67percent")
            if let maxE = s.maxElevation { StatTile(value: Format.meters(maxE), label: "quota max", icon: "mountain.2") }
            if s.runs > 0 { StatTile(value: "\(s.runs)", label: "discese", icon: "figure.skiing.downhill") }
            if let hr = s.averageHeartRate { StatTile(value: "\(hr)", label: "bpm medi", icon: "heart.fill") }
        }
    }

    @ViewBuilder
    private func weatherCard(_ o: Outing) -> some View {
        M3Card {
            HStack {
                if let w = o.weather {
                    Image(systemName: w.icon).symbolRenderingMode(.multicolor).font(.system(size: 34))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(w.title).font(.m3TitleMedium).foregroundStyle(m3.onSurface)
                        Text(w.summary).font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
                    }
                    Spacer()
                } else {
                    Label("Meteo non disponibile", systemImage: "cloud").font(.m3BodyMedium).foregroundStyle(m3.onSurfaceVariant)
                    Spacer()
                    if o.startCoordinate != nil {
                        Button {
                            loadingWeather = true
                            Task { await model.fetchWeather(outing: o.id); loadingWeather = false }
                        } label: {
                            if loadingWeather { ProgressView() } else { Text("Scarica") }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func summitsSection(_ o: Outing) -> some View {
        let stamps = model.data.stamps.filter { $0.outingID == o.id }
        SectionTitle("Cime e passi", trailing: stamps.isEmpty ? nil : "\(stamps.count)")
        ForEach(stamps) { s in StampRow(stamp: s, showDate: false) }
        Button { showSummitPicker = true } label: {
            Label("Timbra una cima o un passo", systemImage: "flag.badge.ellipsis").font(.m3LabelLarge).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func notesSection(_ o: Outing) -> some View {
        SectionTitle("Note")
        TextEditor(text: $note)
            .frame(minHeight: 100)
            .scrollContentBackground(.hidden)
            .padding(10)
            .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .onChange(of: note) { _, v in
                guard var c = model.outing(o.id), c.note != v else { return }
                c.note = v
                model.update(c)
            }
    }

    @ViewBuilder
    private func photosSection(_ o: Outing) -> some View {
        SectionTitle("Foto", trailing: o.photos.isEmpty ? nil : "\(o.photos.count)")
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .images) {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus").font(.system(size: 26))
                        Text("Aggiungi").font(.m3LabelMedium)
                    }
                    .frame(width: 110, height: 110)
                    .foregroundStyle(m3.onSecondaryContainer)
                    .background(m3.secondaryContainer, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }
                ForEach(o.photos, id: \.self) { name in
                    if let img = PhotoStore.image(name) {
                        Image(uiImage: img).resizable().scaledToFill().frame(width: 110, height: 110)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .contextMenu {
                                Button(role: .destructive) { model.removePhoto(name, from: o.id) } label: { Label("Rimuovi", systemImage: "trash") }
                            }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func gearSection(_ o: Outing) -> some View {
        let gear = model.data.gear.filter { !$0.retired }
        if !gear.isEmpty && (o.kind.usesSkiGear || !o.gearIDs.isEmpty) {
            SectionTitle("Attrezzatura usata")
            FlowChips(items: gear.map { ($0.id, $0.name, $0.type.icon) }, selected: Set(o.gearIDs)) { id in
                var c = o
                if c.gearIDs.contains(id) { c.gearIDs.removeAll { $0 == id } } else { c.gearIDs.append(id) }
                model.update(c)
                model.checkGarageAlerts()
            }
        }
    }
}

/// Kind of an outing, with the automatic proposal and manual override.
struct KindMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    let outing: Outing

    var body: some View {
        let t = m3.tones(for: outing.kind)
        HStack(spacing: 8) {
            Menu {
                ForEach(ActivityKind.allCases) { k in
                    Button { model.setKind(k, for: outing.id) } label: { Label(k.title, systemImage: k.icon) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: outing.kind.icon)
                    Text(outing.kind.title).font(.m3LabelLarge)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 14).frame(height: 36)
                .foregroundStyle(t.onContainer).background(t.container, in: Capsule())
            }
            if outing.kindIsManual {
                TagLabel(text: "scelto a mano", icon: "hand.tap.fill", tones: m3.neutral)
            } else {
                TagLabel(text: "automatico", icon: "wand.and.stars", tones: m3.neutral)
            }
            if let s = outing.suggestedKind, s != outing.kind {
                Button { model.setKind(s, for: outing.id) } label: {
                    TagLabel(text: "proposta: \(s.title)", icon: s.icon, tones: m3.tertiaryTones)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Wrapping multi-select chips.
struct FlowChips: View {
    let items: [(UUID, String, String)]
    let selected: Set<UUID>
    let toggle: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { item in
                    Chip(title: item.1, icon: item.2, selected: selected.contains(item.0)) { toggle(item.0) }
                }
            }
        }
    }
}

/// Peaks along the track (or nearby) to stamp by hand.
struct SummitPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @Environment(\.dismiss) private var dismiss
    let outing: Outing
    let track: Track?
    @State private var query = ""

    private var candidates: [Peak] {
        if !query.isEmpty { return model.peakIndex.search(query) }
        guard let track, let box = track.boundingBox?.expanded(meters: 300) else { return [] }
        let near = SummitMatcher.match(track: track, index: model.peakIndex, radius: 300, maxBelow: 400).map(\.peakID)
        let inBox = model.peakIndex.peaks(in: box, limit: 40)
        return near.compactMap { model.peakIndex.peak(id: $0) } + inBox.filter { !near.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { p in
                Button {
                    model.addStamp(peak: p, date: outing.start.addingTimeInterval(outing.stats.elapsed / 2), mode: outing.kind.summitMode, outingID: outing.id)
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: p.kind.icon).foregroundStyle(m3.tertiary)
                        Text(p.name).foregroundStyle(m3.onSurface)
                        Spacer()
                        if let e = p.elevation { Text(Format.meters(e)).foregroundStyle(m3.onSurfaceVariant) }
                    }
                }
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView("Nessuna cima o passo vicino", systemImage: "mountain.2", description: Text("Cerca per nome."))
                }
            }
            .searchable(text: $query, prompt: "Cerca una cima o un passo")
            .navigationTitle("Timbra")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Chiudi") { dismiss() } } }
        }
    }
}

struct ManualOutingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: ActivityKind = .hike
    @State private var start = Date()
    @State private var hours = 3.0
    @State private var km = 8.0
    @State private var ascent = 600.0

    var body: some View {
        NavigationStack {
            Form {
                TextField("Nome (facoltativo)", text: $name)
                Picker("Tipo", selection: $kind) {
                    ForEach(ActivityKind.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                DatePicker("Partenza", selection: $start)
                Stepper("Durata: \(Format.number(hours, decimals: 1)) h", value: $hours, in: 0.5...24, step: 0.5)
                Stepper("Distanza: \(Format.number(km, decimals: 1)) km", value: $km, in: 0...200, step: 0.5)
                Stepper("Dislivello: \(Int(ascent)) m", value: $ascent, in: 0...5000, step: 50)
            }
            .navigationTitle("Nuova uscita")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        _ = model.addManualOuting(name: name, kind: kind, start: start, duration: hours * 3600, distance: km * 1000, ascent: ascent)
                        dismiss()
                    }
                }
            }
        }
    }
}

enum GPXWriter {
    static func gpx(_ track: Track, name: String) -> String {
        let f = ISO8601DateFormatter()
        let esc = name.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        var s = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Cresta\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(esc)</name><trkseg>\n"
        for p in track.points {
            s += "<trkpt lat=\"\(p.lat)\" lon=\"\(p.lon)\">"
            if let e = p.ele { s += "<ele>\(e)</ele>" }
            if let t = p.time { s += "<time>\(f.string(from: t))</time>" }
            s += "</trkpt>\n"
        }
        return s + "</trkseg></trk></gpx>\n"
    }
}

/// Slopes-style breakdown of a resort ski day.
struct SkiDaySection: View {
    @Environment(\.m3) private var m3
    let track: Track
    let area: String?
    @State private var analysis: SkiDayAnalysis?
    @State private var showAll = false

    var body: some View {
        Group {
            if let a = analysis, !a.runs.isEmpty {
                SectionTitle("Giornata sugli sci", trailing: area)
                M3Card {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            StatTile(value: "\(a.runs.count)", label: "discese", icon: "figure.skiing.downhill", tones: m3.primaryTones)
                            StatTile(value: Format.meters(a.totalVertical), label: "dislivello in pista", icon: "arrow.down.right")
                        }
                        // Skiing vs lifts vs breaks.
                        let total = max(1, a.runTime + a.liftTime + a.otherTime)
                        GeometryReader { g in
                            HStack(spacing: 3) {
                                Capsule().fill(m3.primary).frame(width: max(8, g.size.width * a.runTime / total))
                                Capsule().fill(Color.gray.opacity(0.6)).frame(width: max(8, g.size.width * a.liftTime / total))
                                Capsule().fill(m3.surfaceContainerHighest)
                            }
                        }
                        .frame(height: 12)
                        HStack(spacing: 14) {
                            legend(m3.primary, "Sci \(Format.duration(a.runTime))")
                            legend(.gray, "Impianti \(Format.duration(a.liftTime))")
                            legend(m3.surfaceContainerHighest, "Pause \(Format.duration(a.otherTime))")
                        }
                        .font(.m3LabelMedium).foregroundStyle(m3.onSurfaceVariant)
                    }
                }
                let runs = showAll ? a.runs : Array(a.runs.prefix(5))
                ForEach(runs) { r in
                    HStack(spacing: 12) {
                        Text("\(r.index)").font(.m3TitleMedium).foregroundStyle(m3.onPrimaryContainer)
                            .frame(width: 34, height: 34).background(m3.primaryContainer, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Format.meters(r.vertical)) · \(Format.km(r.distance))").font(.m3TitleSmall).foregroundStyle(m3.onSurface)
                            Text([r.start.map { Format.time($0) }, Format.duration(r.duration), "da \(Int(r.topElevation)) m"].compactMap { $0 }.joined(separator: " · "))
                                .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(Int((r.maxSpeed * 3.6).rounded()))").font(.m3TitleLarge).foregroundStyle(r.id == a.fastestRun?.id ? m3.error : m3.onSurface)
                            Text("km/h").font(.m3LabelSmall).foregroundStyle(m3.onSurfaceVariant)
                        }
                    }
                    .padding(10)
                    .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                if a.runs.count > 5 {
                    Button(showAll ? "Mostra meno" : "Tutte le \(a.runs.count) discese") { withAnimation(.m3Spatial) { showAll.toggle() } }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .task(id: track.points.count) {
            let t = track
            analysis = await Task.detached { SkiDay.analyze(t) }.value
        }
    }

    private func legend(_ c: Color, _ text: String) -> some View {
        HStack(spacing: 4) { Circle().fill(c).frame(width: 8, height: 8); Text(text) }
    }
}
