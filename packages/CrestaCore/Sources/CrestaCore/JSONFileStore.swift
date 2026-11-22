import Foundation

/// Minimal JSON persistence for any `Codable` value.
/// Used by the app to save its state in Application Support; used by
/// tests with a temporary directory. Works on Linux.
public struct JSONFileStore<Value: Codable>: Sendable {
    public let url: URL
    /// Compact output for big files (the visit history), pretty for small ones.
    public let compact: Bool

    public init(url: URL, compact: Bool = false) {
        self.url = url
        self.compact = compact
    }

    /// Returns `nil` when the file does not exist yet.
    public func load() throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(Value.self, from: data)
    }

    /// Writes atomically, creating the parent directory if needed.
    public func save(_ value: Value) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.encoder(compact: compact).encode(value)
        try data.write(to: url, options: .atomic)
    }

    public static func encoder(compact: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = compact ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
