import SwiftUI
import CrestaCore

struct GarageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @State private var editing: GearItem?
    @State private var showRetired = false

    var body: some View {
        let gear = model.data.gear.filter { showRetired || !$0.retired }
        let groups = ["Sci", "Scarpe", "Bici", "Altro"].map { g in (g, gear.filter { $0.type.group == g }) }.filter { !$0.1.isEmpty }
        ScreenScroll {
            if model.data.gear.isEmpty {
                EmptyStateView(icon: "wrench.and.screwdriver.fill", title: "Il garage è vuoto",
                               message: "Aggiungi sci, scarponi, scarpe e bici: Cresta conta giorni d'uso e km dalle uscite e ti avvisa quando serve affilare, sciolinare, cambiare le scarpe o la catena.")
            }
            ForEach(groups, id: \.0) { g in
                SectionTitle(g.0, trailing: "\(g.1.count)")
                ForEach(g.1) { item in GearCard(item: item) { editing = item } }
            }
            Menu {
                ForEach(GearType.allCases, id: \.self) { t in
                    Button { editing = GearItem(name: "", type: t, defaultFor: t.defaultKinds) } label: { Label(t.title, systemImage: t.icon) }
                }
            } label: {
                Label("Aggiungi attrezzatura", systemImage: "plus").font(.m3TitleMedium)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .foregroundStyle(m3.onPrimaryContainer)
                    .background(m3.primaryContainer, in: Capsule())
            }
            if model.data.gear.contains(where: \.retired) {
                Toggle("Mostra attrezzatura dismessa", isOn: $showRetired)
            }
        }
        .navigationTitle("Garage")
        .sheet(item: $editing) { GearEditor(item: $0).presentationCornerRadius(32) }
    }
}

struct GearCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    let item: GearItem
    let edit: () -> Void

    private func totalLabel(_ days: Int) -> String {
        let km = GarageLogic.kmOfUse(item, outings: model.data.outings, since: nil)
        return item.type == .shoes || item.type == .bike ? "\(Format.number(km)) km totali" : "\(days) giorni totali"
    }

    var body: some View {
        let status = GarageLogic.status(item, outings: model.data.outings)
        let total = GarageLogic.totalDays(item, outings: model.data.outings)
        M3Card(corner: 32) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    IconBadge(icon: item.type.icon, tones: m3.primaryTones, size: 52, cookie: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.m3TitleLarge).foregroundStyle(m3.onSurface)
                        Text([item.brand.nonEmpty, item.type.title, totalLabel(total)].compactMap { $0 }.joined(separator: " · "))
                            .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
                    }
                    Spacer()
                    Button(action: edit) { Image(systemName: "pencil.circle.fill").font(.system(size: 28)) }.buttonStyle(.plain)
                        .foregroundStyle(m3.primary)
                }
                ForEach(status) { s in
                    let tones = s.isDue ? m3.errorTones : s.isSoon ? m3.warningTones : m3.successTones
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label(s.task.title, systemImage: s.task.icon).font(.m3TitleSmall).foregroundStyle(m3.onSurface)
                            Spacer()
                            Text(s.isDue ? "Da fare" : "tra \(s.remaining) \(s.unit == .km ? "km" : "gg")").font(.m3LabelLarge).foregroundStyle(tones.onContainer)
                                .padding(.horizontal, 10).padding(.vertical, 4).background(tones.container, in: Capsule())
                        }
                        M3Progress(value: s.fraction, tones: tones, height: 8)
                        HStack {
                            Text("\(s.used)/\(s.interval) \(s.unitLabel)" + (s.lastDone.map { " · ultima il \(Format.dayMonthYear($0))" } ?? " · mai registrata"))
                                .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
                            Spacer()
                            Button("Fatto oggi") { model.logMaintenance(s.task, gear: item.id) }
                                .font(.m3LabelLarge)
                        }
                    }
                }
            }
        }
        .opacity(item.retired ? 0.6 : 1)
    }
}

struct GearEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var item: GearItem
    @State private var confirmDelete = false

    var body: some View {
        let exists = model.data.gear.contains { $0.id == item.id }
        NavigationStack {
            Form {
                Section {
                    TextField("Nome (es. Sci da pista, Scarpe da trail)", text: $item.name)
                    TextField("Marca e modello", text: $item.brand)
                    Picker("Tipo", selection: $item.type) {
                        ForEach(GearType.allCases, id: \.self) { Label($0.title, systemImage: $0.icon).tag($0) }
                    }
                    .onChange(of: item.type) { _, t in item.defaultFor = t.defaultKinds }
                    DatePicker("In uso dal", selection: Binding(get: { item.purchaseDate ?? Date() }, set: { item.purchaseDate = $0 }), displayedComponents: .date)
                    Toggle("Dismesso", isOn: $item.retired)
                }
                Section {
                    ForEach(ActivityKind.allCases.filter { item.type.group == "Sci" ? $0.isSnow : !$0.isSnow }) { k in
                        Toggle(isOn: Binding(get: { item.defaultFor.contains(k) }, set: { on in
                            if on { item.defaultFor.insert(k) } else { item.defaultFor.remove(k) }
                        })) { Label(k.title, systemImage: k.icon) }
                    }
                } header: { Text("Usato di default per") } footer: {
                    Text("Viene aggiunto da solo alle nuove uscite di questo tipo; puoi cambiarlo nella scheda dell'uscita.")
                }
                Section(item.type.tasks.first?.unit == .km ? "Intervalli (km)" : "Intervalli (giorni d'uso)") {
                    ForEach(item.type.tasks, id: \.self) { t in
                        if t.unit == .km {
                            Stepper("\(t.title): ogni \(item.interval(t)) km", value: Binding(get: { item.interval(t) }, set: { item.intervals[t] = $0 }), in: 100...20_000, step: 100)
                        } else {
                            Stepper("\(t.title): ogni \(item.interval(t)) giorni", value: Binding(get: { item.interval(t) }, set: { item.intervals[t] = $0 }), in: 1...200)
                        }
                    }
                }
                if !item.history.isEmpty {
                    Section("Storico interventi") {
                        ForEach(item.history.sorted { $0.date > $1.date }) { r in
                            HStack { Label(r.task.title, systemImage: r.task.icon); Spacer(); Text(Format.dayMonthYear(r.date)).foregroundStyle(.secondary) }
                        }
                        .onDelete { idx in
                            let sorted = item.history.sorted { $0.date > $1.date }
                            let ids = idx.map { sorted[$0].id }
                            item.history.removeAll { ids.contains($0.id) }
                        }
                    }
                }
                if exists {
                    Button("Elimina", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(exists ? "Modifica" : "Nuova attrezzatura")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annulla") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") {
                        if item.name.nonEmpty == nil { item.name = item.type.title }
                        model.updateGear(item)
                        dismiss()
                    }
                }
            }
            .confirmationDialog("Eliminare \(item.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Elimina", role: .destructive) { model.deleteGear(item.id); dismiss() }
            }
        }
    }
}
