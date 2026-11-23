import Foundation
import CrestaCore

/// Small JSON shared by the app and the Go/No-Go widget through the App
/// Group. The real group id is read from the provisioning profile, because
/// free-account signers (Sideloadly) may rename it.
enum SharedStore {
    static let configuredGroup = "group.com.garoth93.cresta"

    /// The App Group actually available to this process, if any.
    static let groupID: String? = {
        var candidates: [String] = []
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url) {
            candidates = ProvisioningProfile.appGroups(from: data)
        }
        if let declared = Bundle.main.object(forInfoDictionaryKey: "CRAppGroup") as? String, !declared.isEmpty {
            candidates.append(declared)
        }
        candidates.append(configuredGroup)
        var seen = Set<String>()
        let ordered = candidates.filter { seen.insert($0).inserted }
        let preferred = ProvisioningProfile.pickGroup(configured: configuredGroup, available: ordered)
        for id in [preferred].compactMap({ $0 }) + ordered {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) != nil { return id }
        }
        return nil
    }()

    static var containerURL: URL? {
        groupID.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    static var isShared: Bool { containerURL != nil }

    static var snapshotURL: URL? { containerURL?.appendingPathComponent(GoWidgetSnapshot.fileName) }

    static func loadGo() -> GoWidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        return GoWidgetSnapshot.decode(data)
    }

    /// Returns true when the file changed (so the widget needs a reload).
    @discardableResult
    static func saveGo(_ snapshot: GoWidgetSnapshot) -> Bool {
        guard let url = snapshotURL else { return false }
        if loadGo() == snapshot { return false }
        guard let data = try? snapshot.encoded() else { return false }
        try? data.write(to: url, options: .atomic)
        return true
    }
}
