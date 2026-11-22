import XCTest
@testable import CrestaCore

final class LogicTests: XCTestCase {
    func testStatsAndClassifierSkiTouring() {
        let t = Synthetic.skiTouring()
        let s = TrackStats.compute(t)
        XCTAssertEqual(s.ascent, 1000, accuracy: 30)
        XCTAssertEqual(s.descent, 1000, accuracy: 30)
        XCTAssertEqual(s.maxElevation!, 2500, accuracy: 10)
        let sug = ModeClassifier.suggest(stats: s, start: t.start, calendar: Synthetic.utc)
        XCTAssertEqual(sug.kind, .skiTouring)
        XCTAssertEqual(sug.kind.summitMode, .ski)
    }

    func testClassifierResort() {
        let s = TrackStats.compute(Synthetic.resort())
        XCTAssertGreaterThanOrEqual(s.liftRides, 3)
        XCTAssertGreaterThanOrEqual(s.runs, 3)
        XCTAssertEqual(ModeClassifier.suggest(stats: s, start: Synthetic.t0, calendar: Synthetic.utc).kind, .resortSki)
    }

    func testClassifierBikeAndHike() {
        let b = TrackStats.compute(Synthetic.bike())
        XCTAssertTrue([.bike, .mtb].contains(ModeClassifier.suggest(stats: b, start: Synthetic.summer, calendar: Synthetic.utc).kind))
        let h = TrackStats.compute(Synthetic.hike())
        XCTAssertEqual(ModeClassifier.suggest(stats: h, start: Synthetic.summer, calendar: Synthetic.utc).kind, .hike)
        // The same slow track in winter becomes snowshoes.
        let w = TrackStats.compute(Synthetic.hike(start: Synthetic.t0))
        XCTAssertEqual(ModeClassifier.suggest(stats: w, start: Synthetic.t0, calendar: Synthetic.utc).kind, .snowshoe)
    }

    func testMaxSpeedIgnoresSpike() {
        var pts = Synthetic.line(start: Synthetic.t0, n: 30, dt: 10, dLat: 0.0001, dEle: 0) // ~1.1 m/s
        pts[15].lat += 0.01 // 1 km jump in 10 s
        let s = TrackStats.compute(Track(points: pts))
        XCTAssertLessThan(s.maxSpeed, 5)
    }

    func testSimplifyKeepsEnds() {
        let t = Synthetic.hike()
        let s = t.simplified(tolerance: 5)
        XCTAssertLessThan(s.points.count, t.points.count)
        XCTAssertEqual(s.points.first, t.points.first)
        XCTAssertEqual(s.points.last, t.points.last)
        XCTAssertEqual(TrackStats.compute(s).ascent, TrackStats.compute(t).ascent, accuracy: 40)
        XCTAssertEqual(t.thinned(maxPoints: 50).points.count, 50)
    }

    func testSummitMatcher() {
        let index = PeakIndex(peaks: [Synthetic.peak, Synthetic.farPeak, Synthetic.peak])
        XCTAssertEqual(index.count, 2)
        let matches = SummitMatcher.match(track: Synthetic.hike(), index: index, radius: 60)
        XCTAssertEqual(matches.map(\.peakID), ["osm:1"])
        XCTAssertNotNil(matches[0].time)
        // Too low on the track: no stamp.
        let low = Track(points: Synthetic.hike().points.map { p in var q = p; q.ele = (q.ele ?? 0) - 500; return q })
        XCTAssertTrue(SummitMatcher.match(track: low, index: index).isEmpty)
        XCTAssertEqual(index.search("cima").first?.id, "osm:1")
        XCTAssertEqual(index.search("púnta").first?.id, "osm:2")
        XCTAssertEqual(index.nearest(to: Coordinate(lat: 10.0601, lon: 20), within: 100).first?.peak.id, "osm:1")
    }

    func testSunEquinox() throws {
        // Equinox at 10°N 20°E: ~12 h of daylight, solar noon ≈ 10:47 UTC.
        let day = ISOTime.parse("2025-03-20T12:00:00Z")!
        let c = Coordinate(lat: 10, lon: 20)
        let utc = TimeZone(identifier: "UTC")!
        let rise = try XCTUnwrap(Sun.time(.sunrise, on: day, at: c, timeZone: utc))
        let set = try XCTUnwrap(Sun.time(.sunset, on: day, at: c, timeZone: utc))
        let dusk = try XCTUnwrap(Sun.time(.civilDusk, on: day, at: c, timeZone: utc))
        let noon = rise.addingTimeInterval(set.timeIntervalSince(rise) / 2)
        XCTAssertEqual(noon.timeIntervalSince(ISOTime.parse("2025-03-20T10:47:00Z")!), 0, accuracy: 180)
        XCTAssertEqual(set.timeIntervalSince(rise) / 3600, 12.1, accuracy: 0.15)
        XCTAssertEqual(dusk.timeIntervalSince(set) / 60, 21, accuracy: 4)
        // Polar night: no sunrise.
        XCTAssertNil(Sun.time(.sunrise, on: ISOTime.parse("2025-12-21T12:00:00Z")!, at: Coordinate(lat: 80, lon: 20), timeZone: utc))
    }

    func testLastLightPlan() {
        let utc = TimeZone(identifier: "UTC")!
        let dep = ISOTime.parse("2025-03-20T06:30:00Z")!
        let plan = LastLight.plan(peak: Synthetic.peak, departure: dep, startElevation: 1000, distanceKm: 6, mode: .foot,
                                  pace: LastLight.Pace.default(for: .foot), timeZone: utc)
        XCTAssertEqual(plan.ascentDuration / 3600, 4 + 1.5 / 2, accuracy: 0.01) // 1400/350 = 4 h, flat 1.5 h
        XCTAssertNotNil(plan.turnaround)
        XCTAssertTrue(plan.returnsInDaylight)
        XCTAssertGreaterThan(plan.slack!, 0)
        let late = LastLight.plan(peak: Synthetic.peak, departure: ISOTime.parse("2025-03-20T13:00:00Z")!, startElevation: 1000,
                                  distanceKm: 6, mode: .foot, pace: .default(for: .foot), timeZone: utc)
        XCTAssertFalse(late.returnsInDaylight)
        XCTAssertLessThan(late.slack!, 0)
        let learned = LastLight.Pace.learned(from: [TrackStats(verticalUpRate: 550, verticalDownRate: 700)], mode: .foot)
        XCTAssertEqual(learned.upRate, 450)
    }

    func testGoNoGo() {
        let good = OpenMeteo.WindowSummary(maxWind: 10, maxGusts: 20, minFreezingLevel: 1500, maxFreezingLevel: 1800,
                                           precipitation: 0, worstCode: 1, meanCloudCover: 10)
        let r = GoNoGo.evaluate(GoNoGoInput(targetElevation: 2400, isWinterOuting: true, avalanche: .low, weather: good,
                                            daysSinceSnowfall: 8, webcam: .clear), enabled: Set(GoFactor.allCases))
        XCTAssertEqual(r.verdict, .go)
        XCTAssertEqual(r.factors.count, 6)
        let bad = GoNoGo.evaluate(GoNoGoInput(targetElevation: 2400, isWinterOuting: true, avalanche: .high, weather: good),
                                  enabled: Set(GoFactor.allCases))
        XCTAssertEqual(bad.verdict, .noGo)
        // Switching the avalanche factor off removes the veto.
        let off = GoNoGo.evaluate(GoNoGoInput(targetElevation: 2400, isWinterOuting: true, avalanche: .high, weather: good),
                                  enabled: [.weather, .wind])
        XCTAssertEqual(off.verdict, .go)
        // Summer: winter-only factors are skipped.
        let summer = GoNoGo.evaluate(GoNoGoInput(targetElevation: 2400, isWinterOuting: false, avalanche: .high, weather: good),
                                     enabled: Set(GoFactor.allCases))
        XCTAssertFalse(summer.factors.contains { $0.factor == .avalanche })
        let storm = OpenMeteo.WindowSummary(maxWind: 30, maxGusts: 60, precipitation: 10, worstCode: 95)
        XCTAssertEqual(GoNoGo.evaluate(GoNoGoInput(targetElevation: 2000, isWinterOuting: false, weather: storm), enabled: Set(GoFactor.allCases)).verdict, .noGo)
    }

    func testAvalancheCAAML() throws {
        let json = """
        {"bulletins":[
          {"regions":[{"regionID":"IT-34-BL-01","name":"Zona A"}],"validTime":{"endTime":"2025-01-16T16:00:00Z"},
           "dangerRatings":[{"mainValue":"moderate","elevation":{"lowerBound":"2200"}},{"mainValue":"low","elevation":{"upperBound":"2200"}}],
           "avalancheProblems":[{"problemType":"wind_slab"},{"problemType":"wind_slab"}],"avalancheActivity":{"highlights":"<p>Attenzione</p>"}},
          {"regions":[{"regionID":"IT-34-VI-01","name":"Zona B"}],"dangerRatings":[{"mainValue":"considerable"}]}
        ]}
        """
        let a = try XCTUnwrap(AvalancheBulletin.parseCAAML(Data(json.utf8), regionID: "IT-34-BL-01"))
        XCTAssertEqual(a.maxLevel, .moderate)
        XCTAssertEqual(a.threshold, 2200)
        XCTAssertEqual(a.level(at: 2500), .moderate)
        XCTAssertEqual(a.level(at: 1500), .low)
        XCTAssertEqual(a.problems, ["Neve ventata"])
        XCTAssertEqual(a.highlights, "Attenzione")
        // Prefix → worst bulletin of the region.
        XCTAssertEqual(try AvalancheBulletin.parseCAAML(Data(json.utf8), regionID: "IT-34")?.maxLevel, .considerable)
        XCTAssertEqual(AvalancheBulletin.caamlURL(regionPrefix: "IT-34-BL-01", day: "2025-01-15").absoluteString,
                       "https://static.avalanche.report/eaws_bulletins/2025-01-15/2025-01-15-IT-34.json")
    }

    func testAvalancheHTMLFallback() {
        XCTAssertEqual(AvalancheBulletin.parseHTML("<div>Grado di pericolo: <b>3</b> marcato</div>", regionID: "x")?.maxLevel, .considerable)
        XCTAssertEqual(AvalancheBulletin.parseHTML("<p>Il pericolo valanghe è MODERATO in quota</p>", regionID: "x")?.maxLevel, .moderate)
        XCTAssertNil(AvalancheBulletin.parseHTML("<p>Nessuna informazione</p>", regionID: "x"))
    }

    func testOpenMeteoParsing() throws {
        let json = """
        {"utc_offset_seconds":3600,
         "hourly":{"time":["2025-01-15T09:00","2025-01-15T10:00","2025-01-15T11:00"],
           "temperature_2m":[-3.0,-1.5,0.5],"weather_code":[0,2,61],"wind_speed_10m":[5,12,30],
           "wind_gusts_10m":[10,20,55],"freezing_level_height":[1200,1400,1600],"cloud_cover":[0,40,90],"precipitation":[0,0,1.2],"snowfall":[0,0,0]},
         "daily":{"time":["2025-01-10","2025-01-11","2025-01-12","2025-01-15"],"snowfall_sum":[0,12.0,2.0,0]}}
        """
        let r = try OpenMeteo.decode(Data(json.utf8))
        let at = ISOTime.parse("2025-01-15T09:10:00Z")! // 10:10 local
        let s = try XCTUnwrap(OpenMeteo.snapshot(r, at: at))
        XCTAssertEqual(s.code, 2)
        XCTAssertEqual(s.temperature, -1.5)
        XCTAssertEqual(OpenMeteo.daysSinceSnowfall(r, before: ISOTime.parse("2025-01-15T11:00:00Z")!), 4)
        let w = OpenMeteo.window(r, from: ISOTime.parse("2025-01-15T08:00:00Z")!, to: ISOTime.parse("2025-01-15T10:00:00Z")!)
        XCTAssertEqual(w.maxWind, 30)
        XCTAssertEqual(w.worstCode, 61)
        XCTAssertEqual(w.minFreezingLevel, 1200)
        XCTAssertTrue(OpenMeteo.forecastURL(Coordinate(lat: 10, lon: 20)).absoluteString.contains("freezing_level_height"))
    }

    func testSeasons() {
        let cal = Synthetic.utc
        XCTAssertEqual(Season.of(ISOTime.parse("2025-01-15T09:00:00Z")!, calendar: cal), Season(kind: .winter, year: 2024))
        XCTAssertEqual(Season.of(ISOTime.parse("2025-11-02T09:00:00Z")!, calendar: cal).title, "Inverno 2025/26")
        XCTAssertEqual(Season.of(ISOTime.parse("2025-07-15T09:00:00Z")!, calendar: cal).title, "Estate 2025")
        XCTAssertTrue(Season.isWinter(date: ISOTime.parse("2025-11-20T09:00:00Z")!, calendar: cal))
        XCTAssertFalse(Season.isWinter(date: ISOTime.parse("2025-11-10T09:00:00Z")!, calendar: cal))
        XCTAssertEqual(Season.resolve(.summer, date: Synthetic.t0, calendar: cal), .summer)
        XCTAssertEqual(Season.resolve(.automatic, date: Synthetic.t0, calendar: cal), .winter)
    }

    func testGarage() {
        var ski = GearItem(name: "Sci test", type: .skis, defaultFor: [.skiTouring], intervals: [.waxing: 2])
        ski.history = [MaintenanceRecord(task: .waxing, date: Synthetic.t0)]
        let outings = (0..<4).map { i in
            Outing(name: "o\(i)", kind: .skiTouring, start: Synthetic.t0.addingTimeInterval(Double(i) * 86_400 + 3600),
                   stats: TrackStats(), hasTrack: false, source: .manual, gearIDs: [ski.id])
        } + [Outing(name: "same day", kind: .skiTouring, start: Synthetic.t0.addingTimeInterval(3 * 86_400 + 7200),
                    stats: TrackStats(), hasTrack: false, source: .manual, gearIDs: [ski.id])]
        let st = GarageLogic.status(ski, outings: outings, calendar: Synthetic.utc)
        let wax = st.first { $0.task == .waxing }!
        XCTAssertEqual(wax.daysUsed, 4)
        XCTAssertTrue(wax.isDue)
        XCTAssertEqual(st.first { $0.task == .sharpening }!.daysUsed, 4)
        XCTAssertEqual(GarageLogic.alerts(gear: [ski], outings: outings).first?.status.task, .waxing)
        XCTAssertEqual(GarageLogic.defaultGear(for: .skiTouring, gear: [ski]), [ski.id])
        XCTAssertTrue(GarageLogic.defaultGear(for: .hike, gear: [ski]).isEmpty)
    }

    func testBackpack() {
        XCTAssertEqual(Backpack.defaults.count, 6)
        var b = Backpack.defaults[0].duplicated()
        XCTAssertFalse(b.builtIn)
        XCTAssertEqual(b.items.count, Backpack.defaults[0].items.count)
        XCTAssertNotEqual(b.items[0].id, Backpack.defaults[0].items[0].id)
        b.items[0].checked = true
        XCTAssertEqual(b.checkedCount, 1)
        let o = UUID()
        b.resetChecks(for: o)
        XCTAssertEqual(b.checkedCount, 0)
        XCTAssertEqual(b.checksFor, o)
        XCTAssertEqual(b.categories.first, "Sicurezza")
    }

    func testStatsAndWrapped() {
        let o1 = Outing(name: "Dura", kind: .skiTouring, start: Synthetic.t0, stats: TrackStats(distance: 10_000, ascent: 1500, maxSpeed: 15), hasTrack: false, source: .manual)
        let o2 = Outing(name: "Facile", kind: .hike, start: Synthetic.summer, stats: TrackStats(distance: 8000, ascent: 600), hasTrack: false, source: .manual)
        let s1 = SummitStamp(peak: Synthetic.peak, date: Synthetic.t0, mode: .ski)
        let s2 = SummitStamp(peak: Synthetic.peak, date: Synthetic.summer, mode: .foot)
        let t = StatsBuilder.totals([o1, o2], stamps: [s1, s2], allStamps: [s1, s2], calendar: Synthetic.utc)
        XCTAssertEqual(t.days, 2)
        XCTAssertEqual(t.ascent, 2100)
        XCTAssertEqual(t.newSummits, 1)
        let seasonStats = StatsBuilder.season(Season(kind: .winter, year: 2024), outings: [o1, o2], stamps: [s1, s2], calendar: Synthetic.utc)
        XCTAssertEqual(seasonStats.totals.outings, 1)
        XCTAssertEqual(seasonStats.daysByMonth[1], 1)
        let cards = Wrapped.cards(year: 2025, outings: [o1, o2], stamps: [s1, s2], calendar: Synthetic.utc)
        XCTAssertEqual(cards.first?.value, "2")
        XCTAssertTrue(cards.contains { $0.id == "favourite" && $0.value == "Cima Test" })
        XCTAssertTrue(cards.contains { $0.id == "big" && $0.value == "Dura" })
        XCTAssertTrue(Wrapped.cards(year: 2010, outings: [o1], stamps: [], calendar: Synthetic.utc).isEmpty)
    }

    func testStravaKinds() {
        XCTAssertEqual(ActivityKind.fromStrava("BackcountrySki"), .skiTouring)
        XCTAssertEqual(ActivityKind.fromStrava("Alpine Ski"), .resortSki)
        XCTAssertEqual(ActivityKind.fromStrava("Snowshoe"), .snowshoe)
        XCTAssertEqual(ActivityKind.fromStrava("MountainBikeRide"), .mtb)
        XCTAssertEqual(ActivityKind.fromStrava("TrailRun"), .trailRun)
        XCTAssertNil(ActivityKind.fromStrava("Yoga"))
    }

    func testAppDataTolerantDecoding() throws {
        let data = Data(#"{"outings":[],"settings":{"appearance":"dark"}}"#.utf8)
        let d = try JSONFileStore<AppData>.decoder.decode(AppData.self, from: data)
        XCTAssertEqual(d.settings.appearance, .dark)
        XCTAssertEqual(d.settings.summitRadius, 60)
        XCTAssertEqual(d.backpacks.count, 6)
        var full = AppData()
        full.outings = [Outing(name: "x", kind: .hike, start: Synthetic.t0, stats: TrackStats(), hasTrack: false, source: .manual, createdAt: Synthetic.t0)]
        full.gear = [GearItem(name: "g", type: .skis, intervals: [.waxing: 3])]
        let enc = try JSONFileStore<AppData>.encoder().encode(full)
        XCTAssertEqual(try JSONFileStore<AppData>.decoder.decode(AppData.self, from: enc), full)
    }
}
