import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client id / secret come from configuration (build settings injected by
/// CI from repository secrets, or typed in Settings and kept in the
/// Keychain), never from the source code.
public struct StravaConfig: Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String
    public var redirectURI: String

    public init(clientID: String, clientSecret: String, redirectURI: String = "cresta://localhost/strava") {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
    }

    public var isComplete: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty && !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
            && !clientID.hasPrefix("$(")
    }

    public var authorizeURL: URL {
        var c = URLComponents(string: "https://www.strava.com/oauth/mobile/authorize")!
        c.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "approval_prompt", value: "auto"),
            URLQueryItem(name: "scope", value: "read,activity:read_all")
        ]
        return c.url!
    }

    /// Extracts the `code` from the OAuth callback.
    public static func code(fromCallback url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }
}

public struct StravaTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var athleteName: String?

    public init(accessToken: String, refreshToken: String, expiresAt: Date, athleteName: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.athleteName = athleteName
    }

    /// Refresh one minute before expiry.
    public func needsRefresh(now: Date = Date()) -> Bool { expiresAt.timeIntervalSince(now) < 60 }

    struct Response: Decodable {
        var access_token: String
        var refresh_token: String
        var expires_at: Double
        var athlete: Athlete?
        struct Athlete: Decodable { var firstname: String?; var lastname: String? }
    }

    public static func decode(_ data: Data, previous: StravaTokens? = nil) throws -> StravaTokens {
        let r = try JSONDecoder().decode(Response.self, from: data)
        let name = [r.athlete?.firstname, r.athlete?.lastname].compactMap { $0 }.joined(separator: " ")
        return StravaTokens(accessToken: r.access_token, refreshToken: r.refresh_token,
                            expiresAt: Date(timeIntervalSince1970: r.expires_at),
                            athleteName: name.isEmpty ? previous?.athleteName : name)
    }
}

/// Strava's limits: requests per 15 minutes and per day. Windows reset at
/// :00/:15/:30/:45 and at midnight UTC.
public struct RateLimitState: Codable, Equatable, Sendable {
    public var shortLimit = 100
    public var dailyLimit = 1000
    public var shortUsage = 0
    public var dailyUsage = 0
    public var updatedAt: Date?
    /// When the client may try again after hitting a limit.
    public var blockedUntil: Date?

    public init() {}

    /// Reads `X-RateLimit-*` or (preferred, read endpoints) `X-ReadRateLimit-*`.
    public mutating func update(headers: [String: String], now: Date = Date()) {
        let h = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        let limit = h["x-readratelimit-limit"] ?? h["x-ratelimit-limit"]
        let usage = h["x-readratelimit-usage"] ?? h["x-ratelimit-usage"]
        if let l = limit?.split(separator: ",").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), l.count == 2 {
            shortLimit = l[0]; dailyLimit = l[1]
        }
        if let u = usage?.split(separator: ",").compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) }), u.count == 2 {
            shortUsage = u[0]; dailyUsage = u[1]
            updatedAt = now
        }
    }

    public static func nextQuarterHour(after d: Date) -> Date {
        let t = d.timeIntervalSince1970
        return Date(timeIntervalSince1970: (floor(t / 900) + 1) * 900 + 5)
    }

    public static func nextUTCMidnight(after d: Date) -> Date {
        let t = d.timeIntervalSince1970
        return Date(timeIntervalSince1970: (floor(t / 86_400) + 1) * 86_400 + 5)
    }

    /// Usage as known now (counters roll over at window boundaries).
    func effective(now: Date) -> (short: Int, daily: Int) {
        guard let u = updatedAt else { return (0, 0) }
        let s = Self.nextQuarterHour(after: u) <= now ? 0 : shortUsage
        let d = Self.nextUTCMidnight(after: u) <= now ? 0 : dailyUsage
        return (s, d)
    }

    /// nil = go ahead; otherwise wait until that date. Keeps a small
    /// reserve so the user's other apps aren't starved.
    public func waitUntil(now: Date = Date(), reserve: Int = 5) -> Date? {
        if let b = blockedUntil, b > now { return b }
        let e = effective(now: now)
        if e.daily >= dailyLimit - reserve { return Self.nextUTCMidnight(after: now) }
        if e.short >= shortLimit - reserve { return Self.nextQuarterHour(after: now) }
        return nil
    }

    /// After HTTP 429.
    public mutating func hitLimit(now: Date = Date()) {
        let e = effective(now: now)
        blockedUntil = e.daily >= dailyLimit - 1 ? Self.nextUTCMidnight(after: now) : Self.nextQuarterHour(after: now)
    }
}

/// Persistent sync progress: survives app restarts so a long first sync
/// resumes where it stopped.
public struct StravaSyncState: Codable, Equatable, Sendable {
    /// Newest activity start already listed (epoch seconds, for `after=`).
    public var after: Double = 0
    /// Page being listed in the current pass.
    public var page = 1
    /// Activities listed but whose streams are not downloaded yet.
    public var pending: [StravaSummary] = []
    public var rate = RateLimitState()
    public var lastSync: Date?
    public var lastError: String?
    public var importedCount = 0
    /// Only activities after this date (the export covers the past).
    public var startFrom: Date?
    public var connected = false

    public init() {}

    public var isIdle: Bool { pending.isEmpty }
}

/// The fields of `/athlete/activities` that are used.
public struct StravaSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64
    public var name: String
    public var sport_type: String?
    public var type: String?
    public var start_date: String
    public var distance: Double?
    public var moving_time: Double?
    public var elapsed_time: Double?
    public var total_elevation_gain: Double?
    public var max_speed: Double?
    public var start_latlng: [Double]?
    public var map: MapInfo?
    public var manual: Bool?

    public struct MapInfo: Codable, Equatable, Sendable { public var summary_polyline: String? }

    public var startDate: Date? { ISOTime.parse(start_date) }
    public var sport: String { sport_type ?? type ?? "" }
}

/// Streams (`key_by_type=true`).
public struct StravaStreams: Decodable, Sendable {
    public struct Stream<T: Decodable & Sendable>: Decodable, Sendable { public var data: [T] }
    public var latlng: Stream<[Double]>?
    public var altitude: Stream<Double>?
    public var time: Stream<Double>?
    public var velocity_smooth: Stream<Double>?
    public var heartrate: Stream<Double>?

    public func track(start: Date) -> Track {
        guard let ll = latlng?.data else { return Track(points: []) }
        var pts: [TrackPoint] = []
        pts.reserveCapacity(ll.count)
        for (i, c) in ll.enumerated() where c.count == 2 {
            pts.append(TrackPoint(lat: c[0], lon: c[1],
                                  ele: altitude.flatMap { i < $0.data.count ? $0.data[i] : nil },
                                  time: time.flatMap { i < $0.data.count ? start.addingTimeInterval($0.data[i]) : nil },
                                  speed: velocity_smooth.flatMap { i < $0.data.count ? $0.data[i] : nil },
                                  heartRate: heartrate.flatMap { i < $0.data.count ? Int($0.data[i]) : nil }))
        }
        return Track(points: pts)
    }
}

/// Google encoded polyline (Strava `summary_polyline`), used when streams
/// are not available.
public enum Polyline {
    public static func decode(_ s: String) -> [Coordinate] {
        var out: [Coordinate] = []
        let b = Array(s.utf8)
        var i = 0, lat = 0, lon = 0
        func next() -> Int? {
            var result = 0, shift = 0
            while i < b.count {
                let v = Int(b[i]) - 63
                i += 1
                result |= (v & 0x1F) << shift
                shift += 5
                if v < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : result >> 1 }
            }
            return nil
        }
        while i < b.count {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat; lon += dLon
            out.append(Coordinate(lat: Double(lat) / 1e5, lon: Double(lon) / 1e5))
        }
        return out
    }
}

// MARK: - Transport and sync engine

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Network access is behind a protocol: URLSession in the app, fakes in tests.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public enum StravaError: Error, Equatable, LocalizedError {
    case notConfigured
    case notConnected
    case rateLimited(until: Date)
    case unauthorized
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Inserisci Client ID e Client Secret di Strava nelle impostazioni."
        case .notConnected: return "Collega l'account Strava."
        case .rateLimited(let d): return "Limite di richieste Strava raggiunto: riprendo alle \(Format.time(d))."
        case .unauthorized: return "Autorizzazione Strava scaduta: ricollega l'account."
        case .http(let c): return "Errore Strava (HTTP \(c))."
        }
    }
}

/// Persistence hooks for the engine (the app saves to disk / Keychain).
public protocol StravaSyncDelegate: AnyObject, Sendable {
    func tokensChanged(_ tokens: StravaTokens) async
    func stateChanged(_ state: StravaSyncState) async
    /// Returns false if the activity was a duplicate and was skipped.
    func importActivity(_ summary: StravaSummary, track: Track?) async -> Bool
}

public actor StravaClient {
    public let config: StravaConfig
    private let transport: HTTPTransport
    private var tokens: StravaTokens?
    private let base = "https://www.strava.com/api/v3"

    public init(config: StravaConfig, tokens: StravaTokens?, transport: HTTPTransport) {
        self.config = config
        self.tokens = tokens
        self.transport = transport
    }

    public var currentTokens: StravaTokens? { tokens }

    func form(_ url: String, _ items: [String: String]) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        r.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
        return r
    }

    public func exchange(code: String) async throws -> StravaTokens {
        guard config.isComplete else { throw StravaError.notConfigured }
        let res = try await transport.send(form("https://www.strava.com/oauth/token", [
            "client_id": config.clientID, "client_secret": config.clientSecret, "code": code, "grant_type": "authorization_code"
        ]))
        guard res.status == 200 else { throw res.status == 401 ? StravaError.unauthorized : StravaError.http(res.status) }
        let t = try StravaTokens.decode(res.body)
        tokens = t
        return t
    }

    /// Returns a valid access token, refreshing it if needed.
    public func validTokens(now: Date = Date()) async throws -> (StravaTokens, refreshed: Bool) {
        guard let t = tokens else { throw StravaError.notConnected }
        guard t.needsRefresh(now: now) else { return (t, false) }
        guard config.isComplete else { throw StravaError.notConfigured }
        let res = try await transport.send(form("https://www.strava.com/oauth/token", [
            "client_id": config.clientID, "client_secret": config.clientSecret,
            "grant_type": "refresh_token", "refresh_token": t.refreshToken
        ]))
        guard res.status == 200 else { throw res.status == 400 || res.status == 401 ? StravaError.unauthorized : StravaError.http(res.status) }
        let n = try StravaTokens.decode(res.body, previous: t)
        tokens = n
        return (n, true)
    }

    public func get(_ path: String, query: [String: String], state: inout StravaSyncState, now: Date = Date()) async throws -> HTTPResponse {
        if let wait = state.rate.waitUntil(now: now) { throw StravaError.rateLimited(until: wait) }
        let (t, _) = try await validTokens(now: now)
        var c = URLComponents(string: base + path)!
        c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var r = URLRequest(url: c.url!)
        r.setValue("Bearer \(t.accessToken)", forHTTPHeaderField: "Authorization")
        let res = try await transport.send(r)
        state.rate.update(headers: res.headers, now: now)
        switch res.status {
        case 200: return res
        case 429:
            state.rate.hitLimit(now: now)
            throw StravaError.rateLimited(until: state.rate.blockedUntil ?? RateLimitState.nextQuarterHour(after: now))
        case 401: throw StravaError.unauthorized
        default: throw StravaError.http(res.status)
        }
    }
}

/// Incremental sync: list new activities page by page, then download the
/// streams of each one. Stops cleanly at the rate limit and resumes later
/// from the saved state.
public enum StravaSync {
    public static func run(client: StravaClient, state initial: StravaSyncState, delegate: StravaSyncDelegate,
                           now: @Sendable () -> Date = { Date() }, maxRequests: Int = .max) async -> StravaSyncState {
        var state = initial
        state.lastError = nil
        var requests = 0
        let before = await client.currentTokens
        do {
            // 1. Listing.
            if state.pending.isEmpty {
                var after = state.after
                if after == 0, let s = state.startFrom { after = s.timeIntervalSince1970 }
                while requests < maxRequests {
                    let res = try await client.get("/athlete/activities", query: [
                        "after": String(Int(after)), "per_page": "100", "page": String(state.page)
                    ], state: &state, now: now())
                    requests += 1
                    let list = (try? JSONDecoder().decode([StravaSummary].self, from: res.body)) ?? []
                    state.pending.append(contentsOf: list.filter { a in !state.pending.contains { $0.id == a.id } })
                    if list.count < 100 { state.page = 1; break }
                    state.page += 1
                    await delegate.stateChanged(state)
                }
                state.pending.sort { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            }
            if let t = await client.currentTokens, t != before { await delegate.tokensChanged(t) }
            // 2. Streams, oldest first, advancing the cursor after each one.
            while let next = state.pending.first, requests < maxRequests {
                var track: Track?
                if next.manual != true, next.start_latlng?.count == 2 {
                    let res = try await client.get("/activities/\(next.id)/streams", query: [
                        "keys": "latlng,altitude,time,velocity_smooth,heartrate", "key_by_type": "true"
                    ], state: &state, now: now())
                    requests += 1
                    if let s = try? JSONDecoder().decode(StravaStreams.self, from: res.body), let start = next.startDate {
                        track = s.track(start: start)
                    }
                    if track?.isEmpty != false, let poly = next.map?.summary_polyline, !poly.isEmpty {
                        track = Track(points: Polyline.decode(poly).map { TrackPoint(lat: $0.lat, lon: $0.lon) })
                    }
                }
                if await delegate.importActivity(next, track: track) { state.importedCount += 1 }
                state.pending.removeFirst()
                if let d = next.startDate { state.after = max(state.after, d.timeIntervalSince1970) }
                await delegate.stateChanged(state)
            }
            if state.pending.isEmpty { state.lastSync = now() }
        } catch let e as StravaError {
            state.lastError = e.errorDescription
            if case .unauthorized = e { state.connected = false }
        } catch {
            state.lastError = error.localizedDescription
        }
        if let t = await client.currentTokens, t != before { await delegate.tokensChanged(t) }
        await delegate.stateChanged(state)
        return state
    }
}
