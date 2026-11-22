import Foundation

public struct ChecklistItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var category: String
    public var checked: Bool

    public init(id: UUID = UUID(), title: String, category: String = "", checked: Bool = false) {
        self.id = id
        self.title = title
        self.category = category
        self.checked = checked
    }
}

/// A packing checklist ("zaino"). Templates are ordinary backpacks marked
/// `builtIn`: they can be duplicated and edited like any other.
public struct Backpack: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var icon: String
    public var items: [ChecklistItem]
    public var builtIn: Bool
    /// Outing the current ticks belong to; ticks reset when a new outing starts.
    public var checksFor: UUID?
    public var lastReset: Date?

    public init(id: UUID = UUID(), name: String, icon: String, items: [ChecklistItem], builtIn: Bool = false) {
        self.id = id
        self.name = name
        self.icon = icon
        self.items = items
        self.builtIn = builtIn
    }

    public var checkedCount: Int { items.filter(\.checked).count }
    public var progress: Double { items.isEmpty ? 0 : Double(checkedCount) / Double(items.count) }
    public var categories: [String] {
        items.map(\.category).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    public func duplicated(name: String? = nil) -> Backpack {
        Backpack(name: name ?? "\(self.name) (copia)", icon: icon,
                 items: items.map { ChecklistItem(title: $0.title, category: $0.category) })
    }

    /// Unticks everything: called when a new outing begins.
    public mutating func resetChecks(for outing: UUID? = nil, at date: Date = Date()) {
        for i in items.indices { items[i].checked = false }
        checksFor = outing
        lastReset = date
    }

    static func make(_ name: String, _ icon: String, _ groups: [(String, [String])]) -> Backpack {
        Backpack(name: name, icon: icon, items: groups.flatMap { g in g.1.map { ChecklistItem(title: $0, category: g.0) } }, builtIn: true)
    }

    public static let defaults: [Backpack] = [
        make("Scialpinismo", "figure.skiing.crosscountry", [
            ("Sicurezza", ["ARTVA (acceso e testato)", "Pala", "Sonda", "Kit primo soccorso", "Telo termico", "Telefono carico"]),
            ("Attrezzatura", ["Sci con attacchi", "Pelli", "Rampanti", "Scarponi", "Bastoncini", "Casco", "Ramponi e piccozza (se serve)"]),
            ("Abbigliamento", ["Guscio", "Piumino leggero", "Secondo paio di guanti", "Berretto", "Maschera", "Occhiali da sole"]),
            ("Altro", ["Acqua / thermos", "Cibo", "Crema solare", "Frontale", "Bollettino valanghe letto"])
        ]),
        make("Sci in pista", "figure.skiing.downhill", [
            ("Attrezzatura", ["Sci", "Scarponi", "Bastoncini", "Casco", "Maschera"]),
            ("Abbigliamento", ["Giacca", "Pantaloni", "Guanti", "Sottocasco / scaldacollo", "Calze da sci"]),
            ("Altro", ["Skipass", "Crema solare", "Snack", "Portafoglio"])
        ]),
        make("Ciaspole", "snowflake", [
            ("Sicurezza", ["ARTVA", "Pala", "Sonda", "Kit primo soccorso", "Telefono carico"]),
            ("Attrezzatura", ["Ciaspole", "Bastoncini con rotelle da neve", "Scarponi impermeabili", "Ghette"]),
            ("Abbigliamento", ["Guscio", "Pile", "Guanti", "Berretto", "Occhiali da sole"]),
            ("Altro", ["Thermos", "Cibo", "Frontale", "Crema solare"])
        ]),
        make("Escursione", "figure.hiking", [
            ("Base", ["Scarponcini", "Zaino", "Acqua (almeno 1,5 l)", "Cibo", "Mappa / traccia scaricata"]),
            ("Abbigliamento", ["Giacca antipioggia", "Pile o strato caldo", "Cappello", "Occhiali da sole", "Maglia di ricambio"]),
            ("Sicurezza", ["Kit primo soccorso", "Telefono carico", "Powerbank", "Frontale", "Fischietto"]),
            ("Altro", ["Crema solare", "Bastoncini", "Documento"])
        ]),
        make("Ferrata", "figure.climbing", [
            ("Attrezzatura", ["Imbrago", "Set da ferrata con dissipatore", "Casco", "Guanti da ferrata", "Moschettone e cordino di riposo"]),
            ("Base", ["Scarpe da avvicinamento", "Acqua", "Cibo", "Relazione della ferrata"]),
            ("Sicurezza", ["Kit primo soccorso", "Telefono carico", "Frontale", "Giacca"])
        ]),
        make("Corsa lunga", "figure.run", [
            ("Base", ["Scarpe da trail", "Gilet idrico / borracce", "Gel o barrette", "Sali minerali"]),
            ("Abbigliamento", ["Giacca antivento leggera", "Cappellino", "Calze tecniche", "Occhiali"]),
            ("Sicurezza", ["Telefono carico", "Telo termico", "Fischietto", "Traccia sull'orologio"]),
            ("Altro", ["Vaselina / antisfregamento", "Crema solare", "Cambio per dopo"])
        ])
    ]
}
