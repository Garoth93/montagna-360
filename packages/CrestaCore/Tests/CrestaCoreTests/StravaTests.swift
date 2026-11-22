import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import CrestaCore

final class StravaTests: XCTestCase {
    let config = StravaConfig(clientID: "12345", clientSecret: "test-secret")

    func testConfigAndCallback() {
        XCTAssertTrue(config.isComplete)
        XCTAssertFalse(StravaConfig(clientID: "$(STRAVA_CLIENT_ID)", clientSecret: "x").isComplete)
        XCTAssertTrue(config.authorizeURL.absoluteString.contains("activity:read_all"))
        XCTAssertEqual(StravaConfig.code(fromCallback: URL(string: "cresta://localhost/strava?state=&code=abc&scope=read")!), "abc")
    }

    func testRateLimitHeaders() {
        var r = RateLimitState()
        let now = ISOTime.parse("2025-01-15T10:07:00Z")!
        r.update(headers: ["X-RateLimit-Limit": "200,2000", "X-RateLimit-Usage": "10,100",
                           "X-ReadRateLimit-Limit": "100,1000", "X-ReadRateLimit-Usage": "97,500"], now: now)
        XCTAssertEqual(r.shortLimit, 100)
        XCTAssertEqual(r.shortUsage, 97)
        XCTAssertEqual(r.waitUntil(now: now), ISOTime.parse("2025-01-15T10:15:05Z"))
        // After the window rolls over the counter is considered reset.
        XCTAssertNil(r.waitUntil(now: ISOTime.parse("2025-01-15T10:16:00Z")!))
        r.update(headers: ["X-ReadRateLimit-Limit": "100,1000", "X-ReadRateLimit-Usage": "3,998"], now: now)
        XCTAssertEqual(r.waitUntil(now: now), ISOTime.parse("2025-01-16T00:00:05Z"))
    }

    func testTokenRefreshAndSync() async throws {
        let now = ISOTime.parse("2025-02-01T10:00:00Z")!
        let list = """
        [{"id":2,"name":"Seconda","sport_type":"Hike","start_date":"2025-01-21T08:00:00Z","distance":5000,"start_latlng":[10.0,20.0],"map":{"summary_polyline":""}},
         {"id":1,"name":"Prima","sport_type":"BackcountrySki","start_date":"2025-01-20T08:00:00Z","distance":8000,"start_latlng":[10.0,20.0]},
         {"id":3,"name":"Palestra","sport_type":"WeightTraining","start_date":"2025-01-22T08:00:00Z","manual":true}]
        """
        let streams = """
        {"latlng":{"data":[[10.0,20.0],[10.001,20.0],[10.002,20.0]]},"altitude":{"data":[1500,1550,1600]},"time":{"data":[0,600,1200]}}
        """
        let transport = FakeTransport { req in
            let url = req.url!.absoluteString
            let rl = ["X-ReadRateLimit-Limit": "100,1000", "X-ReadRateLimit-Usage": "1,1"]
            if url.contains("oauth/token") {
                return HTTPResponse(status: 200, headers: [:], body: Data(#"{"access_token":"new","refresh_token":"r2","expires_at":1900000000}"#.utf8))
            }
            if url.contains("/athlete/activities") { return HTTPResponse(status: 200, headers: rl, body: Data(list.utf8)) }
            if url.contains("/streams") { return HTTPResponse(status: 200, headers: rl, body: Data(streams.utf8)) }
            return HTTPResponse(status: 404, headers: [:], body: Data())
        }
        let expired = StravaTokens(accessToken: "old", refreshToken: "r1", expiresAt: now.addingTimeInterval(-10), athleteName: "Test")
        let client = StravaClient(config: config, tokens: expired, transport: transport)
        let delegate = RecordingDelegate()
        let state = await StravaSync.run(client: client, state: StravaSyncState(), delegate: delegate, now: { now })
        XCTAssertNil(state.lastError)
        XCTAssertEqual(delegate.imported.map(\.0.id), [1, 2, 3])
        XCTAssertEqual(delegate.imported[0].1?.points.count, 3)
        XCTAssertNil(delegate.imported[2].1) // manual activity: no streams request
        XCTAssertEqual(state.after, ISOTime.parse("2025-01-22T08:00:00Z")!.timeIntervalSince1970)
        XCTAssertEqual(delegate.tokens.last?.accessToken, "new")
        XCTAssertEqual(delegate.tokens.last?.athleteName, "Test")
        XCTAssertEqual(transport.requests.filter { $0.url!.absoluteString.contains("/streams") }.count, 2)
        XCTAssertEqual(transport.requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer new")
    }

    func testSyncStopsAtRateLimitAndResumes() async {
        let now = ISOTime.parse("2025-02-01T10:00:00Z")!
        var calls = 0
        let transport = FakeTransport { req in
            let url = req.url!.absoluteString
            if url.contains("/athlete/activities") {
                return HTTPResponse(status: 200, headers: [:], body: Data(#"[{"id":7,"name":"A","sport_type":"Run","start_date":"2025-01-20T08:00:00Z","start_latlng":[10,20]},{"id":8,"name":"B","sport_type":"Run","start_date":"2025-01-21T08:00:00Z","start_latlng":[10,20]}]"#.utf8))
            }
            calls += 1
            if calls == 2 { return HTTPResponse(status: 429, headers: [:], body: Data()) }
            return HTTPResponse(status: 200, headers: [:], body: Data(#"{"latlng":{"data":[[10,20],[10.001,20]]},"time":{"data":[0,60]}}"#.utf8))
        }
        let tokens = StravaTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(3600))
        let client = StravaClient(config: config, tokens: tokens, transport: transport)
        let d = RecordingDelegate()
        let s1 = await StravaSync.run(client: client, state: StravaSyncState(), delegate: d, now: { now })
        XCTAssertEqual(d.imported.map(\.0.id), [7])
        XCTAssertEqual(s1.pending.map { $0.id }, [8])
        XCTAssertNotNil(s1.lastError)
        XCTAssertEqual(s1.rate.blockedUntil, ISOTime.parse("2025-02-01T10:15:05Z"))
        // Too early: nothing happens.
        let s2 = await StravaSync.run(client: client, state: s1, delegate: d, now: { now.addingTimeInterval(60) })
        XCTAssertEqual(s2.pending.map { $0.id }, [8])
        // After the window: resumes from the pending queue.
        let s3 = await StravaSync.run(client: client, state: s2, delegate: d, now: { now.addingTimeInterval(1000) })
        XCTAssertTrue(s3.pending.isEmpty)
        XCTAssertEqual(d.imported.map(\.0.id), [7, 8])
    }
}
