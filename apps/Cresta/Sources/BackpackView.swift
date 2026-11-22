import SwiftUI
import CrestaCore

struct BackpackListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3

    var body: some View {
        ScreenScroll {
            Text("Le spunte si azzerano a ogni nuova uscita. I modelli si possono duplicare e modificare.")
                .font(.m3BodyMedium).foregroundStyle(m3.onSurfaceVariant)
            ForEach(model.data.backpacks) { b in
                NavigationLink(value: b.id.uuidString) {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle().stroke(m3.secondaryContainer, lineWidth: 6)
                            Circle().trim(from: 0, to: b.progress).stroke(m3.primary, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: b.icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(m3.onSurface)
                        }
                        .frame(width: 52, height: 52)
                        .animation(.m3Spatial, value: b.progress)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.name).font(.m3TitleMedium).foregroundStyle(m3.onSurface)
                            Text("\(b.checkedCount)/\(b.items.count) pronti" + (b.builtIn ? " · modello" : ""))
                                .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(m3.onSurfaceVariant)
                    }
                    .padding(14)
                    .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
            Button {
                model.updateBackpack(Backpack(name: "Nuovo zaino", icon: "backpack.fill", items: []))
            } label: {
                Label("Nuovo zaino vuoto", systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            Button { model.resetBackpackChecks(for: nil) } label: {
                Label("Azzera tutte le spunte", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
        .navigationTitle("Zaino")
        .navigationDestination(for: String.self) { id in
            if let uuid = UUID(uuidString: id) { BackpackDetailView(backpackID: uuid) }
        }
    }
}

struct BackpackDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @Environment(\.dismiss) private var dismiss
    let backpackID: UUID
    @State private var editing = false
    @State private var newItem = ""
    @State private var newCategory = ""
    @State private var rename = ""

    var body: some View {
        if let b = model.data.backpacks.first(where: { $0.id == backpackID }) {
            ScreenScroll {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(b.checkedCount) di \(b.items.count)").font(.m3DisplaySmall).contentTransition(.numericText())
                        Spacer()
                        if b.progress == 1 && !b.items.isEmpty {
                            Label("Pronto!", systemImage: "checkmark.seal.fill").font(.m3TitleMedium).foregroundStyle(m3.success)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    M3Progress(value: b.progress)
                }
                .animation(.m3Spatial, value: b.checkedCount)
                ForEach(b.categories, id: \.self) { cat in
                    SectionTitle(cat.isEmpty ? "Altro" : cat)
                    VStack(spacing: 6) {
                        ForEach(b.items.filter { $0.category == cat }) { item in
                            itemRow(item, in: b)
                        }
                    }
                }
                if editing {
                    M3Card {
                        VStack(spacing: 10) {
                            TextField("Nome dello zaino", text: $rename)
                                .onSubmit { var c = b; c.name = rename.nonEmpty ?? b.name; model.updateBackpack(c) }
                            TextField("Nuovo oggetto", text: $newItem)
                            TextField("Categoria (facoltativa)", text: $newCategory)
                            Button("Aggiungi") {
                                guard let t = newItem.nonEmpty else { return }
                                var c = b
                                c.items.append(ChecklistItem(title: t, category: newCategory.nonEmpty ?? b.categories.last ?? ""))
                                model.updateBackpack(c)
                                newItem = ""
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .navigationTitle(b.name)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { rename = b.name; withAnimation { editing.toggle() } } label: {
                            Label(editing ? "Fine modifica" : "Modifica", systemImage: "pencil")
                        }
                        Button { model.updateBackpack(b.duplicated()) } label: { Label("Duplica", systemImage: "plus.square.on.square") }
                        Button { var c = b; c.resetChecks(); model.updateBackpack(c) } label: { Label("Azzera spunte", systemImage: "arrow.counterclockwise") }
                        Button(role: .destructive) { dismiss(); model.deleteBackpack(b.id) } label: { Label("Elimina", systemImage: "trash") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
    }

    private func itemRow(_ item: ChecklistItem, in b: Backpack) -> some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.m3Spatial) { model.toggleItem(item.id, in: b.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: item.checked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundStyle(item.checked ? m3.primary : m3.outline)
                        .symbolEffect(.bounce, value: item.checked)
                    Text(item.title).font(.m3BodyLarge).foregroundStyle(item.checked ? m3.onSurfaceVariant : m3.onSurface)
                        .strikethrough(item.checked, color: m3.onSurfaceVariant)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            if editing {
                Button {
                    var c = b
                    c.items.removeAll { $0.id == item.id }
                    model.updateBackpack(c)
                } label: { Image(systemName: "minus.circle.fill").foregroundStyle(m3.error) }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(item.checked ? m3.secondaryContainer.opacity(0.6) : m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
