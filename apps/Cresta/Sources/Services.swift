import Foundation
import Security
import UIKit
import UserNotifications
import CrestaCore

// MARK: - Files

enum AppFiles {
    static var base: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var data: URL { base.appendingPathComponent("cresta-data.json") }
    static var tracks: URL { folder("tracks") }
    static var photos: URL { folder("photos") }
    static var extraPeaks: URL { base.appendingPathComponent("peaks-extra.tsv") }
    static var weatherCache: URL { base.appendingPathComponent("go-cache.json") }

    static func folder(_ name: String) -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// One compact JSON file per outing track.
enum TrackStore {
    static func url(_ id: UUID) -> URL { AppFiles.tracks.appendingPathComponent("\(id.uuidString).json") }

    static func save(_ track: Track, for id: UUID) {
        try? JSONFileStore<Track>(url: url(id), compact: true).save(track)
    }

    static func load(_ id: UUID) -> Track? {
        try? JSONFileStore<Track>(url: url(id), compact: true).load()
    }

    static func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id))
    }
}

enum PhotoStore {
    static func url(_ name: String) -> URL { AppFiles.photos.appendingPathComponent(name) }

    static func save(_ data: Data) -> String? {
        let name = "\(UUID().uuidString).jpg"
        // Re-encode smaller to save space.
        let out = UIImage(data: data).flatMap { img -> Data? in
            let maxSide: CGFloat = 2048
            let scale = min(1, maxSide / max(img.size.width, img.size.height))
            let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
            let r = UIGraphicsImageRenderer(size: size)
            return r.image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.82)
        } ?? data
        do { try out.write(to: url(name), options: .atomic); return name } catch { return nil }
    }

    static func image(_ name: String) -> UIImage? { UIImage(contentsOfFile: url(name).path) }

    static func delete(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }
}

/// Offline OSM databases: files bundled at build time (peaks, passes, ski
/// areas) plus areas downloaded from the app.
enum PeakDatabase {
    struct Loaded: Sendable {
        var places: [Peak] = []      // peaks + passes
        var skiAreas: [Peak] = []
        var bundled: [PeakKind: Int] = [:]
    }

    static func extraURL(_ kind: PeakKind) -> URL {
        kind == .peak ? AppFiles.extraPeaks : AppFiles.base.appendingPathComponent("\(kind.fileName)-extra.tsv")
    }

    static func load() -> Loaded {
        var out = Loaded()
        for kind in PeakKind.allCases {
            var list: [Peak] = []
            if let url = Bundle.main.url(forResource: kind.fileName, withExtension: "tsv"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                list = PeakFile.parse(text, kind: kind)
                out.bundled[kind] = list.count
            }
            if let text = try? String(contentsOf: extraURL(kind), encoding: .utf8) {
                list += PeakFile.parse(text, kind: kind)
            }
            if kind == .skiArea { out.skiAreas = list } else { out.places += list }
        }
        return out
    }

    static func appendDownloaded(_ new: [Peak], kind: PeakKind) {
        let url = extraURL(kind)
        var existing = (try? String(contentsOf: url, encoding: .utf8)).map { PeakFile.parse($0, kind: kind) } ?? []
        let ids = Set(existing.map(\.id))
        existing += new.filter { !ids.contains($0.id) }
        try? PeakFile.serialize(existing).write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Keychain (Strava tokens and credentials)

enum Keychain {
    static let service = "com.garoth93.cresta"

    static func set(_ data: Data?, for key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard let data else { return }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func string(_ key: String) -> String? { get(key).map { String(decoding: $0, as: UTF8.self) } }
    static func setString(_ s: String?, for key: String) { set(s.map { Data($0.utf8) }, for: key) }
}

enum StravaCredentials {
    /// Typed in Settings (Keychain) first, then the build configuration.
    static var config: StravaConfig {
        let info = Bundle.main.infoDictionary ?? [:]
        let id = Keychain.string("strava.clientID")?.nonEmpty ?? (info["StravaClientID"] as? String ?? "")
        let secret = Keychain.string("strava.clientSecret")?.nonEmpty ?? (info["StravaClientSecret"] as? String ?? "")
        return StravaConfig(clientID: id, clientSecret: secret)
    }

    static var fromBuild: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        return StravaConfig(clientID: info["StravaClientID"] as? String ?? "", clientSecret: info["StravaClientSecret"] as? String ?? "").isComplete
    }

    static var tokens: StravaTokens? {
        get { Keychain.get("strava.tokens").flatMap { try? JSONDecoder().decode(StravaTokens.self, from: $0) } }
        set { Keychain.set(newValue.flatMap { try? JSONEncoder().encode($0) }, for: "strava.tokens") }
    }
}

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Network

struct URLSessionTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResponse {
        var r = request
        r.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: r)
        let http = resp as? HTTPURLResponse
        var headers: [String: String] = [:]
        for (k, v) in http?.allHeaderFields ?? [:] { headers["\(k)"] = "\(v)" }
        return HTTPResponse(status: http?.statusCode ?? 0, headers: headers, body: data)
    }
}

enum Net {
    static func get(_ url: URL) async throws -> Data {
        var r = URLRequest(url: url)
        r.timeoutInterval = 30
        r.setValue("Cresta/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw URLError(.badServerResponse)
        }
        return data
    }
}

enum WeatherService {
    /// Weather at a time and place: forecast API for the last days, archive
    /// for older dates.
    static func snapshot(at date: Date, coordinate c: Coordinate, elevation: Double?) async -> WeatherSnapshot? {
        let age = Date().timeIntervalSince(date)
        let url: URL
        if age < 6 * 86_400 {
            url = OpenMeteo.forecastURL(c, pastDays: 7, elevation: elevation)
        } else {
            url = OpenMeteo.archiveURL(c, day: Format.isoDay(date, timeZone: TimeZone(identifier: "UTC")!), elevation: elevation)
        }
        guard let data = try? await Net.get(url), let r = try? OpenMeteo.decode(data) else { return nil }
        return OpenMeteo.snapshot(r, at: date)
    }

    static func forecast(_ c: Coordinate, elevation: Double?) async throws -> OpenMeteo.Response {
        try OpenMeteo.decode(try await Net.get(OpenMeteo.forecastURL(c, pastDays: 30, elevation: elevation)))
    }
}

enum AvalancheService {
    static func fetch(region: String, fallbackURL: String, day: Date = Date()) async -> AvalancheReport? {
        let iso = Format.isoDay(day)
        if let data = try? await Net.get(AvalancheBulletin.caamlURL(regionPrefix: region, day: iso)),
           let r = try? AvalancheBulletin.parseCAAML(data, regionID: region) {
            return r
        }
        // No machine-readable bulletin: read the web page.
        if let url = URL(string: fallbackURL), let data = try? await Net.get(url) {
            let html = String(decoding: data, as: UTF8.self)
            return AvalancheBulletin.parseHTML(html, regionID: region)
        }
        return nil
    }
}

enum OverpassService {
    static let endpoints = ["https://overpass-api.de/api/interpreter", "https://overpass.kumi.systems/api/interpreter"]

    static func places(in box: BoundingBox, kind: PeakKind) async throws -> [Peak] {
        var lastError: Error = URLError(.cannotConnectToHost)
        for e in endpoints {
            do {
                var r = URLRequest(url: URL(string: e)!)
                r.httpMethod = "POST"
                r.timeoutInterval = 120
                r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                let q = PeakFile.overpassQuery(box, kind: kind).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                r.httpBody = Data("data=\(q)".utf8)
                let (data, resp) = try await URLSession.shared.data(for: r)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                // Ways/relations (ski areas) get the same id offset as the CI script.
                let text = String(decoding: data, as: UTF8.self)
                return PeakFile.parse(text, kind: kind).map { p in
                    var q = p
                    if kind == .skiArea, let n = Int64(p.id.dropFirst(4)) { q.id = "osm:\(n + 1_000_000_000_000)" }
                    return q
                }
            } catch { lastError = error }
        }
        throw lastError
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    static func schedule(id: String, title: String, body: String, at date: Date) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
    }

    static func now(id: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content,
                                                                     trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }

    static func cancel(_ id: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
    }
}

/// Keeps the app alive a few seconds while finishing work in the background.
@MainActor
enum BackgroundWork {
    private final class Token { var id: UIBackgroundTaskIdentifier = .invalid }

    static func run(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            UIApplication.shared.endBackgroundTask(token.id)
            token.id = .invalid
        }
        Task { @MainActor in
            await work()
            if token.id != .invalid {
                UIApplication.shared.endBackgroundTask(token.id)
                token.id = .invalid
            }
        }
    }
}
