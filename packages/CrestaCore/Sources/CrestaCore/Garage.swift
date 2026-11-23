import Foundation

public enum GearType: String, Codable, CaseIterable, Sendable {
    case skis, boots, splitboard, skins, shoes, bike, other

    public var title: String {
        switch self {
        case .skis: return "Sci"
        case .boots: return "Scarponi"
        case .splitboard: return "Snowboard / splitboard"
        case .skins: return "Pelli"
        case .shoes: return "Scarpe"
        case .bike: return "Bici"
        case .other: return "Altro"
        }
    }

    /// Section of the garage.
    public var group: String {
        switch self {
        case .skis, .boots, .splitboard, .skins: return "Sci"
        case .shoes: return "Scarpe"
        case .bike: return "Bici"
        case .other: return "Altro"
        }
    }

    /// Kinds of outing a new item of this type is used for by default.
    public var defaultKinds: Set<ActivityKind> {
        switch self {
        case .skis, .boots: return [.resortSki]
        case .splitboard: return [.snowboard, .skiTouring]
        case .skins: return [.skiTouring]
        case .shoes: return [.run, .trailRun]
        case .bike: return [.bike]
        case .other: return []
        }
    }

    public var icon: String {
        switch self {
        case .skis: return "figure.skiing.downhill"
        case .boots: return "shoeprints.fill"
        case .splitboard: return "figure.snowboarding"
        case .skins: return "rectangle.stack.fill"
        case .shoes: return "shoe.fill"
        case .bike: return "bicycle"
        case .other: return "wrench.and.screwdriver.fill"
        }
    }

    /// Maintenance tasks that make sense for this type.
    public var tasks: [MaintenanceTask] {
        switch self {
        case .skis, .splitboard: return [.sharpening, .waxing]
        case .boots: return [.service]
        case .skins: return [.glue]
        case .shoes: return [.shoeLife]
        case .bike: return [.chain, .bikeService]
        case .other: return [.service]
        }
    }
}

public enum MaintenanceTask: String, Codable, CaseIterable, Sendable {
    case sharpening, waxing, service, glue, shoeLife, chain, bikeService

    public enum Unit: Sendable { case days, km }

    /// Ski gear is counted in days of use, shoes and bikes in km.
    public var unit: Unit {
        switch self {
        case .shoeLife, .chain, .bikeService: return .km
        default: return .days
        }
    }

    public var title: String {
        switch self {
        case .sharpening: return "Affilatura"
        case .waxing: return "Sciolina"
        case .service: return "Manutenzione"
        case .glue: return "Colla"
        case .shoeLife: return "Sostituzione"
        case .chain: return "Catena"
        case .bikeService: return "Tagliando"
        }
    }

    public var icon: String {
        switch self {
        case .sharpening: return "scissors"
        case .waxing: return "drop.fill"
        case .service: return "wrench.fill"
        case .glue: return "bandage.fill"
        case .shoeLife: return "shoe.2.fill"
        case .chain: return "link"
        case .bikeService: return "wrench.adjustable.fill"
        }
    }

    /// Default interval: ski days, or km for shoes and bikes.
    public var defaultInterval: Int {
        switch self {
        case .sharpening: return 12
        case .waxing: return 5
        case .service: return 60
        case .glue: return 40
        case .shoeLife: return 700
        case .chain: return 3000
        case .bikeService: return 5000
        }
    }
}

public struct MaintenanceRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var task: MaintenanceTask
    public var date: Date
    public var note: String

    public init(id: UUID = UUID(), task: MaintenanceTask, date: Date, note: String = "") {
        self.id = id
        self.task = task
        self.date = date
        self.note = note
    }
}

/// Skis, boots… with usage since the last maintenance.
public struct GearItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var type: GearType
    public var brand: String
    /// Activity kinds this item is used for by default on new outings.
    public var defaultFor: Set<ActivityKind>
    public var intervals: [MaintenanceTask: Int]
    public var history: [MaintenanceRecord]
    public var retired: Bool
    public var purchaseDate: Date?

    public init(id: UUID = UUID(), name: String, type: GearType, brand: String = "", defaultFor: Set<ActivityKind> = [],
                intervals: [MaintenanceTask: Int] = [:], history: [MaintenanceRecord] = [], retired: Bool = false, purchaseDate: Date? = nil) {
        self.id = id; self.name = name; self.type = type; self.brand = brand; self.defaultFor = defaultFor
        self.intervals = intervals; self.history = history; self.retired = retired; self.purchaseDate = purchaseDate
    }

    public func interval(_ task: MaintenanceTask) -> Int { intervals[task] ?? task.defaultInterval }

    public func last(_ task: MaintenanceTask) -> Date? {
        history.filter { $0.task == task }.map(\.date).max()
    }
}

public struct MaintenanceStatus: Equatable, Sendable, Identifiable {
    public var task: MaintenanceTask
    public var lastDone: Date?
    /// Use since the last intervention (or since purchase): distinct days for
    /// ski gear, km for shoes and bikes.
    public var used: Int
    public var interval: Int

    public var id: String { task.rawValue }
    public var unit: MaintenanceTask.Unit { task.unit }
    public var remaining: Int { interval - used }
    public var isDue: Bool { used >= interval }
    public var isSoon: Bool { !isDue && remaining <= max(1, interval / 5) }
    public var fraction: Double { interval > 0 ? min(1, Double(used) / Double(interval)) : 0 }
    public var unitLabel: String { unit == .km ? "km" : "giorni" }
}

public enum GarageLogic {
    /// Distinct calendar days on which `item` was used after `since`.
    public static func daysOfUse(_ item: GearItem, outings: [Outing], since: Date?, calendar: Calendar = .current) -> Int {
        var days = Set<DateComponents>()
        for o in outings where o.gearIDs.contains(item.id) {
            if let since, o.start <= since { continue }
            days.insert(calendar.dateComponents([.year, .month, .day], from: o.start))
        }
        return days.count
    }

    /// Km travelled with `item` after `since`.
    public static func kmOfUse(_ item: GearItem, outings: [Outing], since: Date?) -> Double {
        outings.filter { o in o.gearIDs.contains(item.id) && (since.map { o.start > $0 } ?? true) }
            .reduce(0) { $0 + $1.stats.distance } / 1000
    }

    public static func status(_ item: GearItem, outings: [Outing], calendar: Calendar = .current) -> [MaintenanceStatus] {
        item.type.tasks.map { t in
            let last = item.last(t) ?? item.purchaseDate
            let used = t.unit == .km ? Int(kmOfUse(item, outings: outings, since: last).rounded())
                : daysOfUse(item, outings: outings, since: last, calendar: calendar)
            return MaintenanceStatus(task: t, lastDone: item.last(t), used: used, interval: item.interval(t))
        }
    }

    /// Garage items for the gear names given by the source (Strava export):
    /// creates the missing ones and assigns each outing to its item.
    public static func gearFromSources(outings: [Outing], gear: [GearItem]) -> (newItems: [GearItem], assignments: [UUID: UUID]) {
        var items = gear
        var created: [GearItem] = []
        var assign: [UUID: UUID] = [:]
        // Newest use first, so the most recent item becomes the default.
        for o in outings.sorted(by: { $0.start > $1.start }) {
            guard let name = o.sourceGear?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let item: GearItem
            if let existing = items.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                item = existing
            } else {
                let type: GearType = [.bike, .mtb].contains(o.kind) ? .bike : o.kind.usesSkiGear ? .skis : .shoes
                let kinds = type.defaultKinds.contains(o.kind) ? type.defaultKinds : [o.kind]
                let alreadyDefault = items.contains { $0.type == type && !$0.defaultFor.isDisjoint(with: kinds) }
                item = GearItem(name: name, type: type, defaultFor: alreadyDefault ? [] : kinds)
                items.append(item)
                created.append(item)
            }
            if !o.gearIDs.contains(item.id) { assign[o.id] = item.id }
        }
        return (created, assign)
    }

    public static func totalDays(_ item: GearItem, outings: [Outing]) -> Int {
        daysOfUse(item, outings: outings, since: nil)
    }

    /// Items needing attention, worst first.
    public static func alerts(gear: [GearItem], outings: [Outing]) -> [(item: GearItem, status: MaintenanceStatus)] {
        gear.filter { !$0.retired }.flatMap { g in
            status(g, outings: outings).filter { $0.isDue || $0.isSoon }.map { (g, $0) }
        }.sorted { $0.1.fraction > $1.1.fraction }
    }

    /// Gear to attach automatically to a new outing of `kind`.
    public static func defaultGear(for kind: ActivityKind, gear: [GearItem]) -> [UUID] {
        gear.filter { !$0.retired && $0.defaultFor.contains(kind) }.map(\.id)
    }
}
