import XCTest
@testable import CrestaCore

final class WidgetTests: XCTestCase {
    func testWindowsAndNextChange() {
        let cal = Synthetic.utc
        let morning = ISOTime.parse("2025-01-15T09:00:00Z")!
        let evening = ISOTime.parse("2025-01-15T18:00:00Z")!
        XCTAssertEqual(GoDayWindow.current(now: morning, calendar: cal).label, "oggi")
        XCTAssertEqual(GoDayWindow.current(now: evening, calendar: cal).label, "domani")
        XCTAssertEqual(GoDayWindow.current(now: evening, calendar: cal).from, ISOTime.parse("2025-01-16T08:00:00Z"))
        XCTAssertEqual(GoDayWindow.nextChange(after: morning, calendar: cal), ISOTime.parse("2025-01-15T15:00:00Z"))
        XCTAssertEqual(GoDayWindow.nextChange(after: evening, calendar: cal), ISOTime.parse("2025-01-16T00:00:00Z"))
        XCTAssertEqual(GoDayWindow.forDay(offset: 2, now: morning, calendar: cal).label, "17 gennaio")
    }

    func testSnapshotEvaluatesAndRoundTrips() throws {
        let json = """
        {"utc_offset_seconds":0,"hourly":{"time":["2025-01-15T09:00","2025-01-15T12:00"],"weather_code":[0,1],
         "wind_speed_10m":[5,8],"wind_gusts_10m":[10,12],"freezing_level_height":[1200,1300],"snow_depth":[0.8,0.8],"snowfall":[0,0]}}
        """
        let target = GoTarget(name: "Meta test", coordinate: Coordinate(lat: 10, lon: 20), elevation: 2000)
        let snap = GoWidgetSnapshot(target: target, forecast: Data(json.utf8),
                                    avalanche: AvalancheReport(regionID: "X", maxLevel: .low, fetchedAt: Synthetic.t0, source: "t"),
                                    fetchedAt: Synthetic.t0, factors: Set(GoFactor.allCases), winter: true, seed: Palette.winterSeed)
        let e = try XCTUnwrap(snap.evaluate(now: ISOTime.parse("2025-01-15T07:00:00Z")!, calendar: Synthetic.utc))
        XCTAssertTrue(e.hasData)
        XCTAssertEqual(e.result.verdict, .go)
        XCTAssertEqual(GoWidgetSnapshot.decode(try snap.encoded()), snap)
        XCTAssertTrue(snap.isStale(now: Synthetic.t0.addingTimeInterval(4 * 3600)))
        XCTAssertFalse(snap.isStale(now: Synthetic.t0.addingTimeInterval(3600)))
        XCTAssertNil(GoWidgetSnapshot(target: nil, forecast: nil, avalanche: nil, fetchedAt: nil, factors: [], winter: false, seed: "").evaluate())
    }

    func testProvisioningGroupPick() {
        XCTAssertEqual(ProvisioningProfile.pickGroup(configured: "group.com.garoth93.cresta", available: ["group.com.garoth93.cresta"]), "group.com.garoth93.cresta")
        XCTAssertEqual(ProvisioningProfile.pickGroup(configured: "group.com.garoth93.cresta", available: ["group.ABC123.com.garoth93.cresta"]), "group.ABC123.com.garoth93.cresta")
        XCTAssertNil(ProvisioningProfile.pickGroup(configured: "group.x", available: []))
    }
}
