import Foundation

/// Versioned backup file (JSON). Contains the app data only: Strava tokens
/// and client id/secret live in the Keychain and are never exported.
/// Tracks and photos are separate, immutable files next to it.
public struct BackupFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var app: String
    public var exportedAt: Date
    public var data: AppData

    public init(data: AppData, now: Date = Date()) {
        version = Self.currentVersion
        app = "Cresta"
        exportedAt = now
        var clean = data
        // Sync progress is device state, not user data: the next sync after a
        // restore rebuilds it (the cursor is kept to avoid re-downloading).
        clean.strava.pending = []
        clean.strava.rate = RateLimitState()
        clean.strava.lastError = nil
        self.data = clean
    }

    public func encoded() throws -> Data {
        try JSONFileStore<BackupFile>.encoder(compact: true).encode(self)
    }

    public static func decode(_ data: Data) throws -> BackupFile {
        let file = try JSONFileStore<BackupFile>.decoder.decode(BackupFile.self, from: data)
        guard file.app == "Cresta" else { throw BackupError.wrongApp }
        return file
    }

    /// Track files the backup needs (outings with a track).
    public var trackIDs: [UUID] { data.outings.filter(\.hasTrack).map(\.id) }
    public var photoNames: [String] { data.outings.flatMap(\.photos) }
}

public enum BackupError: Error, Equatable, LocalizedError {
    case wrongApp
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .wrongApp: return "Questo file non è un backup di Cresta."
        case .unreadable: return "Backup non leggibile."
        }
    }
}

/// Automatic backups in iCloud Drive: shared container
/// `iCloud.com.garoth93.backup`, sub-folder "Cresta", visible in Files.
///
/// Files: `Cresta-backup-yyyy-MM-dd.json` (one per day, overwritten during
/// the day, the last `keepDaily` kept), `Cresta-backup-latest.json`, plus
/// `tracks/<uuid>.json` and `photos/<name>` written once (they never change).
public enum CloudBackupPlan {
    public static let containerID = "iCloud.com.garoth93.backup"
    public static let folderName = "Cresta"
    public static let latestName = "Cresta-backup-latest.json"
    public static let prefix = "Cresta-backup-"
    public static let tracksFolder = "tracks"
    public static let photosFolder = "photos"
    public static let keepDaily = 30

    public struct Entry: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public var name: String
        /// Day of the backup (nil for "latest").
        public var day: Date?
        public var isLatest: Bool { day == nil }
    }

    private static func dayFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    public static func dailyName(for date: Date) -> String {
        "\(prefix)\(dayFormatter().string(from: date)).json"
    }

    public static func trackName(_ id: UUID) -> String { "\(id.uuidString).json" }

    /// iCloud placeholder of a file not downloaded yet: ".name.json.icloud".
    public static func realName(_ fileName: String) -> String {
        guard fileName.hasPrefix("."), fileName.hasSuffix(".icloud") else { return fileName }
        return String(fileName.dropFirst().dropLast(".icloud".count))
    }

    /// Backups found in the folder, newest first ("latest" on top).
    public static func entries(fromFileNames names: [String]) -> [Entry] {
        let f = dayFormatter()
        var latest: Entry?
        var daily: [Entry] = []
        for raw in Set(names.map(realName)) {
            if raw == latestName {
                latest = Entry(name: raw, day: nil)
            } else if raw.hasPrefix(prefix), raw.hasSuffix(".json") {
                let stamp = String(raw.dropFirst(prefix.count).dropLast(5))
                if let d = f.date(from: stamp) { daily.append(Entry(name: raw, day: d)) }
            }
        }
        daily.sort { $0.day! > $1.day! }
        return (latest.map { [$0] } ?? []) + daily
    }

    /// Daily files beyond the newest `keep`.
    public static func namesToPrune(_ names: [String], keep: Int = keepDaily) -> [String] {
        let daily = entries(fromFileNames: names).filter { !$0.isLatest }
        return daily.count > keep ? daily[keep...].map(\.name) : []
    }

    /// Files (tracks or photos) to upload: wanted ones not yet in iCloud.
    public static func missing(_ wanted: [String], existing: [String]) -> [String] {
        let have = Set(existing.map(realName))
        return wanted.filter { !have.contains($0) }
    }

    /// Fingerprint of what a backup contains, not of when it was made: an
    /// unchanged fingerprint means no new backup is needed.
    public static func fingerprint(_ backup: BackupFile) -> String {
        var b = backup
        b.exportedAt = Date(timeIntervalSince1970: 0)
        b.data.revision = 0
        guard let data = try? JSONFileStore<BackupFile>.encoder(compact: true).encode(b) else { return "" }
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            h ^= UInt64(byte)
            h = h &* 0x100_0000_01b3
        }
        return String(h, radix: 16) + "-" + String(data.count)
    }
}
