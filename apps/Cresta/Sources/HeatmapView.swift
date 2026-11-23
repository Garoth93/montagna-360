import SwiftUI
import MapKit
import CrestaCore

/// All tracks on one map: overlapping lines build up where you go most.
struct HeatmapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3

    enum Filter: String, CaseIterable, Identifiable {
        case mountain, snow, foot, bike, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .mountain: return "Montagna"
            case .snow: return "Neve"
            case .foot: return "A piedi"
            case .bike: return "Bici"
            case .all: return "Tutte"
            }
        }

        func includes(_ o: Outing, minAscent: Double) -> Bool {
            switch self {
            case .mountain: return MountainFilter.isMountain(o, minAscent: minAscent)
            case .snow: return o.kind.isSnow
            case .foot: return [.hike, .walk, .run, .trailRun, .ferrata, .climbing].contains(o.kind)
            case .bike: return o.kind == .bike || o.kind == .mtb
            case .all: return true
            }
        }
    }

    @State private var filter: Filter = .mountain
    @State private var lines: [[CLLocationCoordinate2D]] = []
    @State private var loading = false
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        ZStack(alignment: .top) {
            Map(position: $position) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    MapPolyline(coordinates: line)
                        .stroke(Color(red: 1, green: 0.32, blue: 0.1).opacity(lines.count > 200 ? 0.22 : 0.4),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
            .mapControls { MapCompass(); MapScaleView() }

            VStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases) { f in
                            Chip(title: f.title, selected: filter == f) { filter = f }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                HStack(spacing: 8) {
                    if loading { ProgressView() }
                    Text(loading ? "Carico le tracce…" : "\(lines.count) tracce").font(.m3LabelLarge)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
            }
            .padding(.top, 8)
        }
        .navigationTitle("Mappa di calore")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: filter) { await load() }
    }

    private func load() async {
        loading = true
        let minAscent = model.data.settings.mountainMinAscent
        let ids = model.data.outings.filter { $0.hasTrack && filter.includes($0, minAscent: minAscent) }
            .sorted { $0.start > $1.start }.prefix(800).map(\.id)
        let result = await Task.detached(priority: .userInitiated) { () -> [[Coordinate]] in
            ids.compactMap { id in
                guard let t = TrackStore.load(id), !t.isEmpty else { return nil }
                return t.thinned(maxPoints: 150).coordinates
            }
        }.value
        lines = result.map { $0.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) } }
        let all = result.flatMap { $0 }
        if let box = BoundingBox(coordinates: all) {
            // Centre on where most tracks are (median), not on far-away trips.
            let lats = all.map(\.lat).sorted(), lons = all.map(\.lon).sorted()
            let c = CLLocationCoordinate2D(latitude: lats[lats.count / 2], longitude: lons[lons.count / 2])
            let span = MKCoordinateSpan(latitudeDelta: min(2, max(0.05, (box.maxLat - box.minLat) * 0.6)),
                                        longitudeDelta: min(2, max(0.05, (box.maxLon - box.minLon) * 0.6)))
            position = .region(MKCoordinateRegion(center: c, span: span))
        }
        loading = false
    }
}
