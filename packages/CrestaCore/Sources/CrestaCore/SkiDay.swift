import Foundation

/// Slopes-style breakdown of a resort ski day: every run, lift time vs
/// skiing time.
public struct SkiRun: Equatable, Sendable, Identifiable {
    public var index: Int
    public var start: Date?
    public var duration: TimeInterval
    public var vertical: Double
    public var distance: Double
    public var maxSpeed: Double
    public var averageSpeed: Double
    public var topElevation: Double
    /// Point indexes in the track (to colour the map).
    public var startIndex: Int
    public var endIndex: Int

    public var id: Int { index }
}

public struct SkiDayAnalysis: Equatable, Sendable {
    public var runs: [SkiRun]
    /// Point index ranges of the lift rides (and slow climbs).
    public var lifts: [ClosedRange<Int>]
    public var runTime: TimeInterval
    public var liftTime: TimeInterval
    public var otherTime: TimeInterval

    public var totalVertical: Double { runs.reduce(0) { $0 + $1.vertical } }
    public var runDistance: Double { runs.reduce(0) { $0 + $1.distance } }
    public var longestRun: SkiRun? { runs.max { $0.vertical < $1.vertical } }
    public var fastestRun: SkiRun? { runs.max { $0.maxSpeed < $1.maxSpeed } }

    /// Share of moving time spent skiing (0…1).
    public var skiingShare: Double {
        let t = runTime + liftTime
        return t > 0 ? runTime / t : 0
    }
}

public enum SkiDay {
    public static func analyze(_ track: Track) -> SkiDayAnalysis? {
        let pts = track.points
        guard pts.count > 10, let eles = TrackStats.smoothedElevations(pts) else { return nil }
        let segs = ClimbSegmenter.segments(points: pts, elevations: eles)
        var runs: [SkiRun] = []
        var lifts: [ClosedRange<Int>] = []
        var runTime = 0.0, liftTime = 0.0
        for seg in segs {
            switch seg.kind {
            case .run:
                let speeds = segmentSpeeds(pts, seg.startIndex, seg.endIndex)
                let top = eles[seg.startIndex...seg.endIndex].max() ?? eles[seg.startIndex]
                runs.append(SkiRun(index: runs.count + 1, start: pts[seg.startIndex].time, duration: seg.duration,
                                   vertical: -seg.verticalChange, distance: seg.distance, maxSpeed: speeds.max,
                                   averageSpeed: seg.duration > 0 ? seg.distance / seg.duration : 0, topElevation: top,
                                   startIndex: seg.startIndex, endIndex: seg.endIndex))
                runTime += seg.duration
            case .lift, .climb:
                lifts.append(seg.startIndex...seg.endIndex)
                liftTime += seg.duration
            case .flat:
                break
            }
        }
        let total = track.start.flatMap { s in track.end.map { $0.timeIntervalSince(s) } } ?? 0
        return SkiDayAnalysis(runs: runs, lifts: lifts, runTime: runTime, liftTime: liftTime,
                              otherTime: max(0, total - runTime - liftTime))
    }

    /// Max speed (median of 5 against GPS spikes) on a segment.
    static func segmentSpeeds(_ pts: [TrackPoint], _ a: Int, _ b: Int) -> (max: Double, list: [Double]) {
        var list: [Double] = []
        guard b > a else { return (0, []) }
        for i in (a + 1)...b {
            guard let t0 = pts[i - 1].time, let t1 = pts[i].time else { continue }
            let dt = t1.timeIntervalSince(t0)
            guard dt > 0, dt <= 30 else { continue }
            list.append(Geo.fastDistance(pts[i - 1].coordinate, pts[i].coordinate) / dt)
        }
        guard list.count >= 5 else { return (min(list.max() ?? 0, 55.5), list) }
        var best = 0.0
        for i in 2..<(list.count - 2) { best = max(best, list[(i - 2)...(i + 2)].sorted()[2]) }
        return (min(best, 55.5), list)
    }
}

extension LastLight {
    /// Your own times on a summit, from past outings that stamped it.
    public struct History: Equatable, Sendable {
        public var date: Date
        public var ascent: TimeInterval
        public var descent: TimeInterval
        public var mode: SummitMode
        public var count: Int
    }

    /// Most recent outing that reached `peakID` (with a timed stamp), in the
    /// given mode if any such outing exists.
    public static func history(peakID: String, mode: SummitMode? = nil, stamps: [SummitStamp], outings: [Outing]) -> History? {
        let timed = stamps.filter { $0.peakID == peakID }.compactMap { s -> (SummitStamp, Outing)? in
            guard let oid = s.outingID, let o = outings.first(where: { $0.id == oid }), o.hasTrack, o.stats.elapsed > 0 else { return nil }
            let up = s.date.timeIntervalSince(o.start)
            let down = o.end.timeIntervalSince(s.date)
            guard up > 300, down > 300 else { return nil }
            return (s, o)
        }
        let pool = mode.map { m in timed.filter { $0.0.mode == m } }.flatMap { $0.isEmpty ? nil : $0 } ?? timed
        guard let last = pool.max(by: { $0.0.date < $1.0.date }) else { return nil }
        return History(date: last.0.date, ascent: last.0.date.timeIntervalSince(last.1.start),
                       descent: last.1.end.timeIntervalSince(last.0.date), mode: last.0.mode, count: pool.count)
    }

    /// Plan with known durations (your own times on this summit).
    public static func plan(peak: Peak, departure: Date, ascent: TimeInterval, descent: TimeInterval,
                            summitStop: TimeInterval = 20 * 60, safetyMargin: TimeInterval = 30 * 60,
                            timeZone: TimeZone = .current) -> LastLightPlan {
        let arrival = departure.addingTimeInterval(ascent)
        let sunset = Sun.time(.sunset, on: departure, at: peak.coordinate, elevation: 0, timeZone: timeZone)
        let dusk = Sun.time(.civilDusk, on: departure, at: peak.coordinate, elevation: 0, timeZone: timeZone)
        return LastLightPlan(departure: departure, summitArrival: arrival, sunset: sunset, civilDusk: dusk,
                             turnaround: dusk.map { $0.addingTimeInterval(-descent - safetyMargin) },
                             expectedReturn: arrival.addingTimeInterval(summitStop + descent),
                             ascentDuration: ascent, descentDuration: descent)
    }
}
