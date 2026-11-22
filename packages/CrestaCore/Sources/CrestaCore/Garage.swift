import Foundation

public enum GearType: String, Codable, CaseIterable, Sendable {
    case skis, boots, splitboard, skins, other

    public var title: String {
        switch self {
        case .skis: return "Sci"
        case .boots: return "Scarponi"
        case .splitboard: return "Snowboard / splitboard"
        case .skins: return "Pelli"
        case .other: return "Altro"
        }
    }

    public var icon: String {
        switch self {
        case .skis: return "figure.skiing.downhill"
        case .boots: return "shoeprints.fill"
        case .splitboard: return "figure.snowboarding"
        case .skins: return "rectangle.stack.fill"
        case .other: return "wrench.and.screwdriver.fill"
        }
    }

    /// Maintenance tasks that make sense for this type.
    public var tasks: [MaintenanceTask] {
        switch self {
        case .skis, .splitboard: return [.sharpening, .waxing]
        case .boots: return [.service]
        case .skins: return [.glue]
        case .other: return [.service]
        }
    }
}

public enum MaintenanceTask: String, Codable, CaseIterable, Sendable {
    case sharpening, waxing, service, glue

    public var title: String {
        switch self {
        case .sharpening: return "Affilatura"
        case .waxing: return "Sciolina"
        case .service: return "Manutenzione"
        case .glue: return "Colla"
        }
    }

    public var icon: String {
        switch self {
        case .sharpening: return "scissors"
        case .waxing: return "drop.fill"
        case .service: return "wrench.fill"
        case .glue: return "bandage.fill"
        }
    }

    /// Default number of ski days between two interventions.
    public var defaultInterval: Int {
        switch self {
        case .sharpening: return 12
        case .waxing: return 5
        case .service: return 60
        case .glue: return 40
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
    /// Distinct days of use since the last intervention (or since purchase).
    public var daysUsed: Int
    public var interval: Int

    public var id: String { task.rawValue }
    public var remaining: Int { interval - daysUsed }
    public var isDue: Bool { daysUsed >= interval }
    public var isSoon: Bool { !isDue && remaining <= max(1, interval / 5) }
    public var fraction: Double { interval > 0 ? min(1, Double(daysUsed) / Double(interval)) : 0 }
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

    public static func status(_ item: GearItem, outings: [Outing], calendar: Calendar = .current) -> [MaintenanceStatus] {
        item.type.tasks.map { t in
            let last = item.last(t) ?? item.purchaseDate
            return MaintenanceStatus(task: t, lastDone: item.last(t), daysUsed: daysOfUse(item, outings: outings, since: last, calendar: calendar),
                                     interval: item.interval(t))
        }
    }

    public static func totalDays(_ item: GearItem, outings: [Outing]) -> Int {
        daysOfUse(item, outings: outings, since: nil)
    }

    /// Items needing attention, worst first.
    public static func alerts(gear: [GearItem], outings: [Outing]) -> [(item: GearItem, status: MaintenanceStatus)] {
        gear.filter { !$0.retired }.flatMap { g in
            status(g, outings: outings).filter { $0.isDue || $0.isSoon }.map { (g, $0) }
        }.sorted { $0.1.remaining < $1.1.remaining }
    }

    /// Gear to attach automatically to a new outing of `kind`.
    public static func defaultGear(for kind: ActivityKind, gear: [GearItem]) -> [UUID] {
        gear.filter { !$0.retired && $0.defaultFor.contains(kind) }.map(\.id)
    }
}
