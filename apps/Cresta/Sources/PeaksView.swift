import SwiftUI
import MapKit
import CrestaCore

/// "Cime": the album of summits reached, a map of all peaks, search.
struct PeaksView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @State private var mode = 0
    @State private var query = ""
    @State private var modeFilter: SummitMode?

    var body: some View {
        VStack(spacing: 0) {
            SegmentedPills(options: [(0, "Cime", "mountain.2.fill"), (1, "Passi", "road.lanes.curved.right"), (2, "Mappa", "map.fill")], selection: $mode)
                .padding(.horizontal, 16).padding(.vertical, 8)
            if mode == 2 { PeakMapView() } else { album }
        }
        .background(m3.surface)
        .navigationTitle(mode == 1 ? "Passi" : "Cime")
        .searchable(text: $query, prompt: mode == 1 ? "Cerca tra \(Format.number(Double(model.peakIndex.count(of: .pass)))) passi"
                    : "Cerca tra \(Format.number(Double(model.peakIndex.count(of: .peak)))) vette")
        .navigationDestination(for: String.self) { PeakDetailView(peakID: $0) }
        .navigationDestination(for: UUID.self) { OutingDetailView(outingID: $0) }
    }

    private var kind: PeakKind { mode == 1 ? .pass : .peak }

    @ViewBuilder
    private var album: some View {
        ScreenScroll {
            if !query.isEmpty {
                let results = model.peakIndex.search(query, kind: kind)
                ForEach(results) { p in
                    NavigationLink(value: p.id) { PeakRow(peak: p, count: model.data.stamps(for: p.id).count) }.buttonStyle(PressableStyle())
                }
                if results.isEmpty {
                    EmptyStateView(icon: "magnifyingglass", title: kind == .pass ? "Nessun passo" : "Nessuna vetta",
                                   message: model.peakIndex.count(of: kind) == 0
                                   ? "L'archivio è vuoto: scarica la zona dalla mappa." : "Prova un altro nome.")
                }
            } else {
                let collected = model.collectedPeaks.filter { c in
                    c.stamps.first?.kind == kind && (modeFilter == nil || c.stamps.contains { $0.mode == modeFilter })
                }
                header(collected.count)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Chip(title: "Tutte", selected: modeFilter == nil) { modeFilter = nil }
                        ForEach(SummitMode.allCases) { m in Chip(title: m.title, icon: m.icon, selected: modeFilter == m) { modeFilter = modeFilter == m ? nil : m } }
                    }
                }
                if collected.isEmpty {
                    EmptyStateView(icon: kind == .pass ? "road.lanes.curved.right" : "flag.fill",
                                   title: kind == .pass ? "Ancora nessun passo" : "Ancora nessuna cima",
                                   message: kind == .pass
                                   ? "I passi vengono timbrati da soli quando una traccia ci passa sopra, in bici o a piedi. Puoi anche cercarne uno e timbrarlo a mano."
                                   : "Le vette vengono timbrate da sole quando importi tracce che passano in cima. Puoi anche cercarne una e timbrarla a mano.")
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(collected, id: \.peakID) { c in
                            NavigationLink(value: c.peakID) { StampCard(stamps: c.stamps) }.buttonStyle(PressableStyle())
                        }
                    }
                }
            }
        }
    }

    private func header(_ count: Int) -> some View {
        let mine = model.data.stamps.filter { $0.kind == kind }
        let highest = mine.compactMap(\.elevation).max()
        let total = mine.count
        return HStack(spacing: 10) {
            StatTile(value: "\(count)", label: kind == .pass ? "passi diversi" : "cime diverse", icon: kind.icon, tones: m3.tertiaryTones)
            StatTile(value: "\(total)", label: "timbri", icon: "seal.fill")
            StatTile(value: highest.map { Format.meters($0) } ?? "—", label: "la più alta", icon: "triangle.fill")
        }
    }
}

/// The "stamp": cookie-shaped badge with name, altitude and date.
struct StampCard: View {
    @Environment(\.m3) private var m3
    let stamps: [SummitStamp]

    var body: some View {
        let s = stamps[0]
        let t = m3.tones(stampColor(s))
        VStack(spacing: 10) {
            ZStack {
                CookieShape(lobes: 14, depth: 0.05).fill(t.container)
                CookieShape(lobes: 14, depth: 0.05).stroke(t.accent, style: StrokeStyle(lineWidth: 2, dash: [4, 3])).padding(6)
                VStack(spacing: 2) {
                    Image(systemName: s.kind == .pass ? "road.lanes.curved.right" : s.mode.icon).font(.system(size: 20, weight: .bold))
                    Text(s.elevation.map { "\(Int($0))" } ?? "—").font(.m3TitleLarge)
                    Text("m").font(.m3LabelSmall)
                }
                .foregroundStyle(t.onContainer)
                if stamps.count > 1 {
                    Text("×\(stamps.count)").font(.m3LabelMedium).foregroundStyle(t.onAccent)
                        .padding(.horizontal, 8).padding(.vertical, 3).background(t.accent, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            .frame(width: 118, height: 118)
            .rotationEffect(.degrees(Double(abs(s.peakID.hashValue % 9)) - 4))
            Text(s.peakName).font(.m3TitleSmall).foregroundStyle(m3.onSurface).lineLimit(2).multilineTextAlignment(.center)
            Text(Format.dayMonthYear(s.date)).font(.m3LabelMedium).foregroundStyle(m3.onSurfaceVariant)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func stampColor(_ s: SummitStamp) -> String {
        switch s.mode {
        case .foot: return "#2e7d32"
        case .ski: return "#1565c0"
        case .snowshoe: return "#00838f"
        case .bike: return "#ef6c00"
        }
    }
}

struct PeakRow: View {
    @Environment(\.m3) private var m3
    let peak: Peak
    var count = 0

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(icon: count > 0 ? "flag.fill" : peak.kind.icon, tones: count > 0 ? m3.tertiaryTones : m3.neutral, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(peak.name).font(.m3TitleSmall).foregroundStyle(m3.onSurface).lineLimit(1)
                Text(count > 0 ? "Raggiunto \(count == 1 ? "una volta" : "\(count) volte")" : (peak.kind == .pass ? "Passo · non ancora raggiunto" : "Non ancora salita"))
                    .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
            }
            Spacer()
            if let e = peak.elevation { Text(Format.meters(e)).font(.m3TitleMedium).foregroundStyle(m3.onSurface) }
        }
        .padding(12)
        .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct StampRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    let stamp: SummitStamp
    var showDate = true

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(SummitMode.allCases) { m in
                    Button { model.setStampMode(m, stamp: stamp.id) } label: { Label(m.title, systemImage: m.icon) }
                }
            } label: {
                IconBadge(icon: stamp.mode.icon, tones: m3.tertiaryTones, size: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(showDate ? Format.dayMonthYear(stamp.date).capitalized : stamp.peakName).font(.m3TitleSmall).foregroundStyle(m3.onSurface)
                HStack(spacing: 6) {
                    Text("\(stamp.mode.title)\(stamp.modeIsManual ? "" : " (auto)") · \(Format.time(stamp.date))")
                    if let w = stamp.weather {
                        Image(systemName: w.icon).symbolRenderingMode(.multicolor)
                        Text(w.temperature.map { "\(Int($0.rounded()))°" } ?? w.title)
                    }
                }
                .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
            }
            Spacer()
            if let e = stamp.elevation, !showDate { Text("\(Int(e)) m").font(.m3LabelLarge).foregroundStyle(m3.onSurfaceVariant) }
        }
        .padding(12)
        .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contextMenu {
            Button(role: .destructive) { model.deleteStamp(stamp.id) } label: { Label("Rimuovi timbro", systemImage: "trash") }
        }
    }
}

struct PeakDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    let peakID: String
    @State private var showStamp = false
    @State private var stampDate = Date()
    @State private var stampMode: SummitMode = .foot

    var body: some View {
        let stamps = model.data.stamps(for: peakID)
        let peak = model.peakIndex.peak(id: peakID) ?? stamps.first.map {
            Peak(id: $0.peakID, name: $0.peakName, lat: $0.coordinate.lat, lon: $0.coordinate.lon, elevation: $0.elevation, kind: $0.kind)
        }
        ScreenScroll {
            if let peak {
                Map(initialPosition: .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: peak.lat, longitude: peak.lon),
                                                       distance: 6000, heading: 0, pitch: 60))) {
                    Marker(peak.name, systemImage: "flag.fill", coordinate: CLLocationCoordinate2D(latitude: peak.lat, longitude: peak.lon))
                        .tint(m3.tertiary)
                }
                .mapStyle(.hybrid(elevation: .realistic))
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(peak.name).font(.m3HeadlineLarge).foregroundStyle(m3.onSurface)
                    Text([peak.elevation.map { Format.meters($0) }, String(format: "%.4f, %.4f", peak.lat, peak.lon)].compactMap { $0 }.joined(separator: " · "))
                        .font(.m3BodyMedium).foregroundStyle(m3.onSurfaceVariant)
                }
                PillButton(title: "Timbra oggi", icon: "flag.fill", tones: m3.tertiaryTones) {
                    stampMode = peak.kind == .pass ? .bike : model.seasonKind == .winter ? .ski : .foot
                    stampDate = Date()
                    showStamp = true
                }
                NavigationLink(value: Tool.lastLight) {
                    Label("Calcola l'Ultima Luce", systemImage: "sunset.fill").font(.m3LabelLarge).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                SectionTitle("Timbri", trailing: stamps.isEmpty ? nil : "\(stamps.count)")
                if stamps.isEmpty {
                    Text(peak.kind == .pass ? "Non ci sei ancora passato." : "Non l'hai ancora salita.").font(.m3BodyMedium).foregroundStyle(m3.onSurfaceVariant)
                }
                ForEach(stamps) { s in
                    if let oid = s.outingID {
                        NavigationLink(value: oid) { StampRow(stamp: s) }.buttonStyle(PressableStyle())
                    } else {
                        StampRow(stamp: s)
                    }
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Tool.self) { _ in LastLightView(initialPeakID: peakID) }
        .sheet(isPresented: $showStamp) {
            NavigationStack {
                Form {
                    DatePicker("Quando", selection: $stampDate)
                    Picker("Modalità", selection: $stampMode) {
                        ForEach(SummitMode.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                .navigationTitle("Nuovo timbro")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Annulla") { showStamp = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Timbra") {
                            if let peak { model.addStamp(peak: peak, date: stampDate, mode: stampMode) }
                            showStamp = false
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }
}

/// All peaks on a map (offline database) with the visited ones highlighted.
struct PeakMapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @State private var region: MKCoordinateRegion?
    @State private var position: MapCameraPosition = .automatic
    @State private var downloading = false
    @State private var selected: String?

    var body: some View {
        let visited = Set(model.data.stamps.map(\.peakID))
        let visible: [Peak] = region.map { r in
            let box = BoundingBox(minLat: r.center.latitude - r.span.latitudeDelta / 2, minLon: r.center.longitude - r.span.longitudeDelta / 2,
                                  maxLat: r.center.latitude + r.span.latitudeDelta / 2, maxLon: r.center.longitude + r.span.longitudeDelta / 2)
            return model.peakIndex.peaks(in: box, limit: 150)
        } ?? []
        ZStack(alignment: .bottom) {
            Map(position: $position, selection: $selected) {
                ForEach(visible) { p in
                    Marker(p.name, systemImage: visited.contains(p.id) ? "flag.fill" : p.kind.icon,
                           coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
                        .tint(visited.contains(p.id) ? m3.tertiary : m3.outline)
                        .tag(p.id)
                }
                UserAnnotation()
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls { MapUserLocationButton(); MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .onEnd) { ctx in region = ctx.region }
            .onAppear {
                if let last = model.data.stamps.max(by: { $0.date < $1.date }) {
                    position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: last.coordinate.lat, longitude: last.coordinate.lon),
                                                          span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)))
                } else {
                    position = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 46.3, longitude: 11.5),
                                                          span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2)))
                }
            }

            if let r = region, r.span.latitudeDelta < 1.5 {
                Button {
                    downloading = true
                    let box = BoundingBox(minLat: r.center.latitude - r.span.latitudeDelta / 2, minLon: r.center.longitude - r.span.longitudeDelta / 2,
                                          maxLat: r.center.latitude + r.span.latitudeDelta / 2, maxLon: r.center.longitude + r.span.longitudeDelta / 2)
                    Task { await model.downloadPeaks(in: box); downloading = false }
                } label: {
                    HStack(spacing: 8) {
                        if downloading { ProgressView().tint(m3.onPrimary) } else { Image(systemName: "arrow.down.circle.fill") }
                        Text("Scarica cime e passi di questa zona").font(.m3LabelLarge)
                    }
                    .padding(.horizontal, 18).frame(height: 48)
                    .foregroundStyle(m3.onPrimary).background(m3.primary, in: Capsule())
                }
                .disabled(downloading)
                .padding(.bottom, 16)
            }
        }
        .navigationDestination(item: $selected) { PeakDetailView(peakID: $0) }
    }
}
