import XCTest
@testable import CrestaCore

final class CloudBackupTests: XCTestCase {
    func sample() -> AppData {
        var d = AppData()
        d.outings = [Outing(name: "x", kind: .hike, start: Synthetic.t0, stats: TrackStats(distance: 1000), hasTrack: true, source: .file,
                            photos: ["a.jpg"], createdAt: Synthetic.t0)]
        d.strava.connected = true
        d.strava.after = 123
        d.strava.pending = [StravaSummary(id: 1, name: "p", start_date: "2025-01-01T00:00:00Z")]
        d.revision = 7
        return d
    }

    func testRoundTripAndNoSyncState() throws {
        let f = BackupFile(data: sample(), now: Synthetic.t0)
        let decoded = try BackupFile.decode(try f.encoded())
        XCTAssertEqual(decoded, f)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertTrue(decoded.data.strava.pending.isEmpty)
        XCTAssertEqual(decoded.data.strava.after, 123)
        XCTAssertEqual(decoded.trackIDs, [sample().outings[0].id].map { _ in decoded.data.outings[0].id })
        XCTAssertEqual(decoded.photoNames, ["a.jpg"])
        // Secrets are not part of the data model: nothing token-like is exported.
        let json = String(decoding: try f.encoded(), as: UTF8.self).lowercased()
        for word in ["token", "secret", "clientid", "client_id"] { XCTAssertFalse(json.contains(word), word) }
        XCTAssertThrowsError(try BackupFile.decode(Data(#"{"version":1,"app":"Altro","exportedAt":"2025-01-01T00:00:00Z","data":{}}"#.utf8)))
    }

    func testFingerprintIgnoresTimeAndRevision() {
        var d = sample()
        let a = CloudBackupPlan.fingerprint(BackupFile(data: d, now: Synthetic.t0))
        d.revision = 99
        XCTAssertEqual(a, CloudBackupPlan.fingerprint(BackupFile(data: d, now: Synthetic.summer)))
        d.outings[0].note = "nuova nota"
        XCTAssertNotEqual(a, CloudBackupPlan.fingerprint(BackupFile(data: d, now: Synthetic.t0)))
    }

    func testNamesEntriesAndPruning() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let day = cal.date(from: DateComponents(year: 2025, month: 3, day: 7, hour: 12))!
        XCTAssertEqual(CloudBackupPlan.dailyName(for: day), "Cresta-backup-2025-03-07.json")
        let names = [".Cresta-backup-2025-03-07.json.icloud", "Cresta-backup-latest.json", "Cresta-backup-2025-03-05.json", "altro.txt", "tracks"]
        let e = CloudBackupPlan.entries(fromFileNames: names)
        XCTAssertEqual(e.map(\.name), ["Cresta-backup-latest.json", "Cresta-backup-2025-03-07.json", "Cresta-backup-2025-03-05.json"])
        XCTAssertEqual(CloudBackupPlan.namesToPrune(names, keep: 1), ["Cresta-backup-2025-03-05.json"])
        XCTAssertEqual(CloudBackupPlan.missing(["a.json", "b.json"], existing: [".a.json.icloud"]), ["b.json"])
    }

    func testOldDataDecodesCloudBackupDefault() throws {
        let s = try JSONFileStore<Settings>.decoder.decode(Settings.self, from: Data("{}".utf8))
        XCTAssertTrue(s.cloudBackup)
    }
}
