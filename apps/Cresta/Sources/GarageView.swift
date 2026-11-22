import SwiftUI
import CrestaCore

struct GarageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @State private var editing: GearItem?
    @State private var showRetired = false

    var body: some View {
        let gear = model.data.gear.filter { showRetired || !$0.retired }
        ScreenScroll {
            if model.data.gear.isEmpty {
                EmptyStateView(icon: "figure.skiing.downhill", title: "Il garage è vuoto",
                               message: "Aggiungi sci e scarponi: Cresta conta i giorni d'uso dalle uscite e ti avvisa quando serve affilare o sciolinare.")
            }
            ForEach(gear) { g in GearCard(item: g) { editing = g } }
            PillButton(title: "Aggiungi attrezzatura", icon: "plus", tones: m3.primaryTones, filled: false) {
                editing = GearItem(name: "", type: .skis, defaultFor: [.resortSki])
            }
            if model.data.gear.contains(where: \.retired) {
                Toggle("Mostra attrezzatura dismessa", isOn: $showRetired)
            }
        }
        .navigationTitle("Sci Garage")
        .sheet(item: $editing) { GearEditor(item: $0).presentationCornerRadius(32) }
    }
}

struct GearCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    let item: GearItem
    let edit: () -> Void

    var body: some View {
        let status = GarageLogic.status(item, outings: model.data.outings)
        let total = GarageLogic.totalDays(item, outings: model.data.outings)
        M3Card(corner: 32) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    IconBadge(icon: item.type.icon, tones: m3.primaryTones, size: 52, cookie: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.m3TitleLarge).foregroundStyle(m3.onSurface)
                        Text([item.brand.nonEmpty, item.type.title, "\(total) giorni totali"].compactMap { $0 }.joined(separator: " · "))
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
                            Text(s.isDue ? "Da fare" : "tra \(s.remaining) gg").font(.m3LabelLarge).foregroundStyle(tones.onContainer)
                                .padding(.horizontal, 10).padding(.vertical, 4).background(tones.container, in: Capsule())
                        }
                        M3Progress(value: s.fraction, tones: tones, height: 8)
                        HStack {
                            Text("\(s.daysUsed)/\(s.interval) giorni" + (s.lastDone.map { " · ultima il \(Format.dayMonthYear($0))" } ?? " · mai registrata"))
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
                    TextField("Nome (es. Sci da pista)", text: $item.name)
                    TextField("Marca e modello", text: $item.brand)
                    Picker("Tipo", selection: $item.type) {
                        ForEach(GearType.allCases, id: \.self) { Label($0.title, systemImage: $0.icon).tag($0) }
                    }
                    Toggle("Dismesso", isOn: $item.retired)
                }
                Section {
                    ForEach(ActivityKind.allCases.filter(\.isSnow)) { k in
                        Toggle(isOn: Binding(get: { item.defaultFor.contains(k) }, set: { on in
                            if on { item.defaultFor.insert(k) } else { item.defaultFor.remove(k) }
                        })) { Label(k.title, systemImage: k.icon) }
                    }
                } header: { Text("Usato di default per") } footer: {
                    Text("Viene aggiunto da solo alle nuove uscite di questo tipo; puoi cambiarlo nella scheda dell'uscita.")
                }
                Section("Intervalli (giorni d'uso)") {
                    ForEach(item.type.tasks, id: \.self) { t in
                        Stepper("\(t.title): ogni \(item.interval(t)) giorni", value: Binding(get: { item.interval(t) }, set: { item.intervals[t] = $0 }), in: 1...200)
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
