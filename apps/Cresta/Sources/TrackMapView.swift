import SwiftUI
import MapKit
import CrestaCore

/// Map of an outing's track, with start/end and the summits reached.
struct TrackMapView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    let outingID: UUID
    var interactive = true
    @State private var track: Track?

    var body: some View {
        let stamps = model.data.stamps.filter { $0.outingID == outingID }
        Group {
            if let track, !track.isEmpty {
                let coords = track.coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                Map(initialPosition: .rect(Self.rect(for: track)), interactionModes: interactive ? .all : []) {
                    MapPolyline(coordinates: coords)
                        .stroke(m3.primary, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    if let first = coords.first {
                        Annotation("Partenza", coordinate: first) {
                            Circle().fill(m3.success).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 3))
                        }
                    }
                    if let last = coords.last, coords.count > 1 {
                        Annotation("Arrivo", coordinate: last) {
                            Circle().fill(m3.error).frame(width: 14, height: 14).overlay(Circle().stroke(.white, lineWidth: 3))
                        }
                    }
                    ForEach(stamps) { s in
                        Annotation(s.peakName, coordinate: CLLocationCoordinate2D(latitude: s.coordinate.lat, longitude: s.coordinate.lon)) {
                            Image(systemName: "flag.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(m3.onTertiaryContainer)
                                .padding(6).background(m3.tertiaryContainer, in: Circle())
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
            } else {
                Rectangle().fill(m3.surfaceContainerHigh)
                    .overlay(ProgressView())
            }
        }
        .task(id: outingID) {
            let id = outingID
            track = await Task.detached { TrackStore.load(id) }.value ?? Track(points: [])
        }
    }

    static func rect(for track: Track) -> MKMapRect {
        guard let box = track.boundingBox?.expanded(meters: 150) else { return .world }
        let a = MKMapPoint(CLLocationCoordinate2D(latitude: box.maxLat, longitude: box.minLon))
        let b = MKMapPoint(CLLocationCoordinate2D(latitude: box.minLat, longitude: box.maxLon))
        return MKMapRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}

/// Altitude profile drawn from the stored track.
struct ElevationProfile: View {
    @Environment(\.m3) private var m3
    let track: Track

    var body: some View {
        let pts = track.thinned(maxPoints: 300).points
        let eles = pts.compactMap(\.ele)
        if eles.count > 2, let lo = eles.min(), let hi = eles.max(), hi - lo > 1 {
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let path = Path { p in
                    for (i, e) in eles.enumerated() {
                        let x = w * Double(i) / Double(eles.count - 1)
                        let y = h - (e - lo) / (hi - lo) * h * 0.9
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                ZStack(alignment: .topLeading) {
                    path.applying(.identity)
                        .stroke(m3.primary, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
                    Path { p in
                        p.addPath(path)
                        p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [m3.primary.opacity(0.35), m3.primary.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    VStack(alignment: .leading) {
                        Text("\(Int(hi)) m").font(.m3LabelSmall)
                        Spacer()
                        Text("\(Int(lo)) m").font(.m3LabelSmall)
                    }
                    .foregroundStyle(m3.onSurfaceVariant)
                }
            }
        }
    }
}
