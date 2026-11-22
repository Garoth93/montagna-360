import XCTest
@testable import CrestaCore

final class ParsingTests: XCTestCase {
    func testInflateDynamicAndFixed() throws {
        let out = try Inflate.swiftInflate(Data(base64Encoded: Synthetic.deflateB64)!)
        XCTAssertEqual(String(decoding: out, as: UTF8.self), Synthetic.deflateText)
        XCTAssertEqual(CRC32.checksum(out), 2_249_096_853)
        let fixed = try Inflate.swiftInflate(Data(base64Encoded: Synthetic.fixedB64)!)
        XCTAssertEqual(String(decoding: fixed, as: UTF8.self), "abcabcabcabc hello hello hello")
    }

    func testGunzipGPX() throws {
        let parsed = try TrackFileParser.parse(Data(base64Encoded: Synthetic.gpxGzB64)!, fileName: "activities/1.gpx.gz")
        XCTAssertEqual(parsed.track.points.count, 60)
        XCTAssertEqual(parsed.name, "Gita test")
        XCTAssertEqual(parsed.sport, "hiking")
        XCTAssertEqual(parsed.track.points[0].ele, 1500)
        XCTAssertEqual(parsed.track.start, ISOTime.parse("2025-01-15T09:00:00Z"))
    }

    func testGPXParser() throws {
        let pts = Synthetic.line(start: Synthetic.t0, n: 10, dt: 60, dLat: 0.0001, dEle: 5)
        let parsed = try TrackFileParser.parse(Data(Synthetic.gpx(pts, type: "BackcountrySki").utf8), fileName: "x.gpx")
        XCTAssertEqual(parsed.track.points.count, 10)
        XCTAssertEqual(parsed.name, "Uscita sintetica")
        XCTAssertEqual(parsed.sport, "BackcountrySki")
        XCTAssertEqual(parsed.track.points[3].ele!, 1515, accuracy: 0.001)
        XCTAssertEqual(parsed.track.points[3].time, Synthetic.t0.addingTimeInterval(180))
    }

    func testTCXParser() throws {
        let tcx = """
        <?xml version="1.0"?><TrainingCenterDatabase><Activities><Activity Sport="Running"><Lap><Track>
        <Trackpoint><Time>2025-01-15T09:00:00.000Z</Time><Position><LatitudeDegrees>10.0</LatitudeDegrees><LongitudeDegrees>20.0</LongitudeDegrees></Position><AltitudeMeters>100.5</AltitudeMeters><HeartRateBpm><Value>120</Value></HeartRateBpm></Trackpoint>
        <Trackpoint><Time>2025-01-15T09:00:10Z</Time></Trackpoint>
        <Trackpoint><Time>2025-01-15T09:00:20+01:00</Time><Position><LatitudeDegrees>10.001</LatitudeDegrees><LongitudeDegrees>20.0</LongitudeDegrees></Position></Trackpoint>
        </Track></Lap></Activity></Activities></TrainingCenterDatabase>
        """
        let parsed = try TrackFileParser.parse(Data(tcx.utf8), fileName: "a.tcx")
        XCTAssertEqual(parsed.track.points.count, 2)
        XCTAssertEqual(parsed.sport, "Running")
        XCTAssertEqual(parsed.track.points[0].heartRate, 120)
        XCTAssertEqual(parsed.track.points[0].ele, 100.5)
        XCTAssertEqual(parsed.track.points[1].time, ISOTime.parse("2025-01-15T08:00:20Z"))
    }

    func testFITRoundTrip() throws {
        let pts = Synthetic.line(start: Synthetic.t0, n: 20, dt: 5, dLat: 0.0001, dEle: 2).map { p -> TrackPoint in
            var q = p; q.speed = 2.5; return q
        }
        let data = FITParser.encode(points: pts, sport: 13)
        let parsed = try TrackFileParser.parse(data, fileName: "x.fit")
        XCTAssertEqual(parsed.track.points.count, 20)
        XCTAssertEqual(parsed.sport, "AlpineSki")
        XCTAssertEqual(parsed.track.points[5].lat, pts[5].lat, accuracy: 1e-6)
        XCTAssertEqual(parsed.track.points[5].ele!, pts[5].ele!, accuracy: 0.3)
        XCTAssertEqual(parsed.track.points[5].speed!, 2.5, accuracy: 0.01)
        XCTAssertEqual(parsed.track.points[5].time, pts[5].time)
    }

    func testISOTime() {
        XCTAssertEqual(ISOTime.parse("1970-01-01T00:00:00Z")?.timeIntervalSince1970, 0)
        XCTAssertEqual(ISOTime.parse("2000-03-01T12:30:15.5Z")?.timeIntervalSince1970, 951_913_815.5)
        XCTAssertEqual(ISOTime.parse("2000-03-01T13:30:15+01:00")?.timeIntervalSince1970, 951_913_815)
        XCTAssertNil(ISOTime.parse("garbage"))
    }

    func testCSVQuotes() {
        let rows = CSV.parse("a,b,c\n\"x, y\",\"he said \"\"hi\"\"\",\"multi\nline\"\r\n1,,3")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1], ["x, y", "he said \"hi\"", "multi\nline"])
        XCTAssertEqual(rows[2], ["1", "", "3"])
    }

    func testStravaCSV() {
        let csv = """
        Activity ID,Activity Date,Activity Name,Activity Type,Activity Description,Elapsed Time,Distance,Max Heart Rate,Relative Effort,Commute,Activity Private Note,Activity Gear,Filename,Athlete Weight,Bike Weight,Elapsed Time,Moving Time,Distance,Max Speed,Average Speed,Elevation Gain
        111,"Jan 15, 2025, 9:00:00 AM",Gita sintetica,Backcountry Ski,"Bella, neve",9000,12.5,,,false,,,activities/111.gpx.gz,,,9000,8000,12500.3,15.2,1.5,1000
        222,"15 gen 2025, 14:00:00",Seconda,Snowshoe,,3600,"5,2",,,false,,,,,,3600,3000,,2.0,1.4,300
        """
        let a = StravaCSV.activities(csv)
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a[0].activityID, 111)
        XCTAssertEqual(a[0].kind, .skiTouring)
        XCTAssertEqual(a[0].description, "Bella, neve")
        XCTAssertEqual(a[0].distance!, 12500.3, accuracy: 0.01)
        XCTAssertEqual(a[0].moving, 8000)
        XCTAssertEqual(a[0].ascent, 1000)
        XCTAssertEqual(a[0].date, ISOTime.parse("2025-01-15T09:00:00Z"))
        XCTAssertEqual(a[0].fileName, "activities/111.gpx.gz")
        XCTAssertEqual(a[1].kind, .snowshoe)
        XCTAssertEqual(a[1].distance!, 5200, accuracy: 0.01)
        XCTAssertEqual(a[1].date, ISOTime.parse("2025-01-15T14:00:00Z"))
        XCTAssertFalse(a[1].hasFile)
    }

    func testStravaExportZipEndToEnd() throws {
        let csv = """
        Activity ID,Activity Date,Activity Name,Activity Type,Elapsed Time,Distance,Filename
        1,"Jan 15, 2025, 9:00:00 AM",Gita uno,Hike,3540,3.3,activities/1.gpx.gz
        2,"Jan 16, 2025, 9:00:00 AM",Pista,Alpine Ski,1000,10,activities/2.fit
        3,"Jan 17, 2025, 9:00:00 AM",Manuale,Run,1800,5,
        """
        let z = ZipWriter()
        z.add(Data(csv.utf8), as: "activities.csv")
        z.add(Data(base64Encoded: Synthetic.gpxGzB64)!, as: "activities/1.gpx.gz")
        z.add(FITParser.encode(points: Synthetic.resort(start: ISOTime.parse("2025-01-16T09:00:00Z")!).points), as: "activities/2.fit")
        let raw = Data(base64Encoded: Synthetic.deflateB64)!
        z.addDeflated(raw, originalSize: 3600, crc: 2_249_096_853, as: "media/readme.txt")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID()).zip")
        try z.finish().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try StravaExportReader(url: url)
        XCTAssertEqual(reader.activities.count, 3)
        XCTAssertEqual(String(decoding: try reader.archive.data(for: reader.archive.entry(named: "media/readme.txt")!), as: UTF8.self), Synthetic.deflateText)

        let first = reader.outing(for: reader.activities[0])!
        XCTAssertEqual(first.outing.name, "Gita uno")
        XCTAssertEqual(first.outing.stravaID, 1)
        XCTAssertTrue(first.outing.hasTrack)
        XCTAssertEqual(first.outing.stats.ascent, 885, accuracy: 50)
        // Hike in January, slow both ways → stays a winter-ish foot outing.
        XCTAssertTrue([.hike, .snowshoe].contains(first.outing.kind))

        let second = reader.outing(for: reader.activities[1])!
        XCTAssertEqual(second.outing.kind, .resortSki)
        XCTAssertGreaterThanOrEqual(second.outing.stats.runs, 3)

        let third = reader.outing(for: reader.activities[2])!
        XCTAssertFalse(third.outing.hasTrack)
        XCTAssertEqual(third.outing.stats.distance, 5000)
        XCTAssertEqual(third.outing.kind, .run)

        // Duplicates against an existing diary.
        let preview = reader.preview(existing: [first.outing])
        XCTAssertEqual(preview.duplicates, [1])
        XCTAssertEqual(preview.selection(kinds: [.hike, .resortSki, .run], includeOther: false).map(\.activityID), [2, 3])
        XCTAssertEqual(preview.selection(kinds: [.run], includeOther: false).map(\.activityID), [3])
    }

    func testItalianStravaCSV() {
        // Italian export: typographic apostrophes, "Nome del file", comma decimals,
        // repeated columns (second = meters / seconds).
        let csv = "ID attività,Data dell\u{2019}attività,Nome attività,Tipo attività,Descrizione dell\u{2019}attività,Tempo trascorso,Distanza,Frequenza cardiaca massima,Sforzo relativo,Tragitto pendolare,Nota privata sulle attività,Attrezzatura attività,Nome del file,Peso dell\u{2019}atleta,Peso della bici,Tempo trascorso,Tempo in movimento,Distanza,Velocità massima,Velocità media,Dislivello positivo,Dislivello negativo\n"
            + "900,\"15 gen 2025, 09:00:00\",Uscita test,Sci alpino,,3646,\"10,24\",153.0,41,false,,,activities/900.fit.gz,,,3646.0,3563.0,10243.4,19.84,2.875,18.0,1500.0\n"
            + "901,\"3 mag 2025, 18:05:00\",Seconda,Allenamento generico,,1800,\"0,0\",,,false,,,activities/901.fit.gz,,,1800.0,1800.0,,,,,\n"
        let a = StravaCSV.activities(csv)
        XCTAssertEqual(a.count, 2)
        XCTAssertEqual(a[0].date, ISOTime.parse("2025-01-15T09:00:00Z"))
        XCTAssertEqual(a[0].fileName, "activities/900.fit.gz")
        XCTAssertEqual(a[0].kind, .resortSki)
        XCTAssertEqual(a[0].distance!, 10_243.4, accuracy: 0.01)
        XCTAssertEqual(a[0].moving, 3563)
        XCTAssertEqual(a[0].ascent, 18)
        XCTAssertEqual(a[0].descent, 1500)
        XCTAssertEqual(a[0].maxSpeed, 19.84)
        XCTAssertEqual(a[1].kind, .other)
        XCTAssertEqual(a[1].date, ISOTime.parse("2025-05-03T18:05:00Z"))
    }

    func testDateFormats() {
        let expected = ISOTime.parse("2025-12-01T21:13:11Z")
        for s in ["Dec 1, 2025, 9:13:11 PM", "Dec 1, 2025, 9:13:11\u{202F}PM", "1 dic 2025, 21:13:11", "1 dicembre 2025, 21:13:11",
                  "01/12/2025, 21:13:11", "2025-12-01 21:13:11"] {
            XCTAssertEqual(StravaCSV.date(s), expected, s)
        }
    }

    func testSourceNumbersWinOverTrack() {
        // Device numbers (barometric, lifts excluded) are preferred.
        let parsed = ParsedTrack(track: Synthetic.resort(), sport: "AlpineSki")
        let fb = TrackStats(distance: 4000, ascent: 0, descent: 1500, elapsed: 3600, moving: 2400, maxSpeed: 20)
        let o = OutingBuilder.build(parsed: parsed, name: "x", sport: nil, start: nil, source: .stravaExport, fallback: fb)!.outing
        XCTAssertEqual(o.stats.distance, 4000)
        XCTAssertEqual(o.stats.descent, 1500)
        XCTAssertEqual(o.stats.maxSpeed, 20)
        XCTAssertGreaterThan(o.stats.ascent, 0) // from the track: the source had none
        XCTAssertGreaterThanOrEqual(o.stats.runs, 3)
        // No GPS: the source type is kept, never guessed.
        let empty = OutingBuilder.build(parsed: nil, name: nil, sport: "Workout", start: Synthetic.t0, source: .stravaExport, fallback: fb)!.outing
        XCTAssertEqual(empty.kind, .other)
    }

    func testDuplicateDetectorByTimeAndDistance() {
        let o = Outing(name: "x", kind: .hike, start: Synthetic.t0, stats: TrackStats(distance: 10_000), hasTrack: false, source: .file)
        XCTAssertTrue(DuplicateDetector.isDuplicate(stravaID: nil, start: Synthetic.t0.addingTimeInterval(60), distance: 10_400, in: [o]))
        XCTAssertFalse(DuplicateDetector.isDuplicate(stravaID: nil, start: Synthetic.t0.addingTimeInterval(60), distance: 15_000, in: [o]))
        XCTAssertFalse(DuplicateDetector.isDuplicate(stravaID: nil, start: Synthetic.t0.addingTimeInterval(3600), distance: 10_000, in: [o]))
    }

    func testPeakFileAndElevations() {
        let text = "1\t10.06\t20.0\t2400\tCima Test\n2\t10.2\t20.2\t3.000\tPunta Lontana\n3\t10.3\t20.3\t\tSenza quota\nbad line\n4\t1\t1\t1\t"
        let peaks = PeakFile.parse(text)
        XCTAssertEqual(peaks.count, 3)
        XCTAssertEqual(peaks[1].elevation, 3000)
        XCTAssertNil(peaks[2].elevation)
        XCTAssertEqual(PeakFile.parseElevation("2.345 m"), 2345)
        XCTAssertEqual(PeakFile.parseElevation("1000 ft")!, 304.8, accuracy: 0.01)
        XCTAssertEqual(PeakFile.parseElevation("3343;3340"), 3343)
        XCTAssertEqual(PeakFile.parse(PeakFile.serialize(peaks)), peaks)
    }

    func testPolyline() {
        let c = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c[0].lat, 38.5, accuracy: 1e-5)
        XCTAssertEqual(c[2].lon, -126.453, accuracy: 1e-5)
    }
}
