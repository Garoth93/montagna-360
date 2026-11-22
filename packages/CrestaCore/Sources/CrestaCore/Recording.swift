import Foundation

/// Phase 2 (GPS recording on the phone). The diary only depends on
/// `Track`; a recorder produces one, exactly like the importers do.
/// The app will implement this protocol with Core Location; nothing in the
/// rest of the code needs to change.
public protocol TrackRecorder: AnyObject {
    var isRecording: Bool { get }
    var points: [TrackPoint] { get }
    func start() throws
    func pause()
    func resume()
    /// Ends the recording and returns the track to store as an outing.
    func finish() -> Track
}

/// Live numbers while recording, computed incrementally from new points.
public struct LiveStats: Equatable, Sendable {
    public private(set) var stats = TrackStats()
    private var lastPoint: TrackPoint?
    private var ref: Double?

    public init() {}

    public mutating func add(_ p: TrackPoint) {
        defer { lastPoint = p }
        if let e = p.ele {
            if let r = ref {
                if e - r >= 3 { stats.ascent += e - r; ref = e } else if r - e >= 3 { stats.descent += r - e; ref = e }
            } else { ref = e }
            stats.maxElevation = max(stats.maxElevation ?? e, e)
            stats.minElevation = min(stats.minElevation ?? e, e)
        }
        guard let l = lastPoint else { return }
        let d = Geo.fastDistance(l.coordinate, p.coordinate)
        stats.distance += d
        if let t0 = l.time, let t1 = p.time {
            let dt = t1.timeIntervalSince(t0)
            if dt > 0 {
                stats.elapsed += dt
                let v = p.speed ?? d / dt
                if v > 0.5 && dt < 300 { stats.moving += dt }
                if dt <= 30 { stats.maxSpeed = max(stats.maxSpeed, min(v, 55.5)) }
            }
        }
    }
}

/// Where a track came from: the importers and (later) the recorder all
/// end in `OutingBuilder.build`.
public enum TrackOrigin: Sendable {
    case file(name: String)
    case stravaExport(activityID: Int64)
    case stravaAPI(activityID: Int64)
    case recorder
}
