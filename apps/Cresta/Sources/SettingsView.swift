import SwiftUI
import UniformTypeIdentifiers
import CrestaCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @State private var backup: DataFileDocument?
    @State private var pickRestore = false
    @State private var confirmDelete = false
    @State private var makingBackup = false

    var body: some View {
        let s = model.data.settings
        Form {
            Section("Aspetto") {
                Picker("Tema", selection: binding(\.appearance)) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Colori", selection: binding(\.colorMode)) {
                    ForEach(ColorMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if s.colorMode == .custom {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Palette.seeds, id: \.hex) { seed in
                                Button { model.mutate { $0.settings.customSeed = seed.hex } } label: {
                                    VStack(spacing: 4) {
                                        Circle().fill(Color(rgb: RGBColor(hex: seed.hex)!)).frame(width: 40, height: 40)
                                            .overlay(Circle().stroke(m3.onSurface, lineWidth: s.customSeed == seed.hex ? 3 : 0).padding(-4))
                                        Text(seed.name).font(.m3LabelSmall)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            Section {
                Picker("Stagione", selection: binding(\.seasonMode)) {
                    ForEach(SeasonMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: { Text("In automatico è inverno dal 15 novembre al 30 aprile.") }

            Section {
                Toggle("Timbra le cime in automatico", isOn: binding(\.autoMatchSummits))
                Stepper("Distanza dalla vetta: \(Int(s.summitRadius)) m", value: binding(\.summitRadius), in: 20...200, step: 10)
                Button("Ricontrolla tutte le tracce") { model.rematchAllSummits() }
                Toggle("Scarica il meteo storico delle uscite", isOn: binding(\.fetchWeatherForImports))
                LabeledContent("Vette nell'archivio offline", value: Format.number(Double(model.peakIndex.count)))
            } header: { Text("Cime") } footer: {
                Text(model.bundledPeakCount > 0
                     ? "Dati © OpenStreetMap contributors (ODbL). Altre zone si scaricano dalla mappa delle Cime."
                     : "Nessun archivio di vette incluso nell'app: scarica le zone che ti interessano dalla mappa delle Cime. Dati © OpenStreetMap contributors (ODbL).")
            }

            Section("Ultima Luce") {
                Stepper("Margine di sicurezza: \(Int(s.lastLightMargin)) min", value: binding(\.lastLightMargin), in: 0...120, step: 5)
                Stepper("Avviso prima: \(Int(s.lastLightNotifyBefore)) min", value: binding(\.lastLightNotifyBefore), in: 5...120, step: 5)
            }

            Section {
                TextField("Pagina del bollettino", text: binding(\.avalancheFallbackURL)).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: { Text("Bollettino valanghe") } footer: {
                Text("Fonte principale: bollettino EAWS in formato CAAML. Se non risponde, Cresta legge questa pagina web e cerca il grado di pericolo.")
            }

            Section("Notifiche") {
                Toggle("Avvisi di manutenzione e Ultima Luce", isOn: binding(\.notificationsEnabled))
            }

            Section("Importa e sincronizza") {
                NavigationLink { ImportHubView() } label: { Label("Importa da Strava o da file", systemImage: "square.and.arrow.down") }
                NavigationLink { StravaSettingsView() } label: { Label("Credenziali API Strava", systemImage: "key.fill") }
            }

            Section {
                Button {
                    makingBackup = true
                    Task { backup = DataFileDocument(data: await model.makeBackup()); makingBackup = false }
                } label: {
                    HStack { Label("Esporta backup", systemImage: "externaldrive.fill"); if makingBackup { Spacer(); ProgressView() } }
                }
                Button { pickRestore = true } label: { Label("Ripristina backup", systemImage: "arrow.counterclockwise") }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Elimina tutti i dati", systemImage: "trash") }
            } header: { Text("Dati") } footer: {
                Text("Tutto resta sul telefono. Il backup contiene uscite, tracce, cime, zaini e garage (le foto no).")
            }

            Section("Informazioni") {
                LabeledContent("Versione", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("Uscite", value: "\(model.data.outings.count)")
                LabeledContent("Timbri", value: "\(model.data.stamps.count)")
                Text("Meteo: Open-Meteo.com · Valanghe: bollettini EAWS · Vette: OpenStreetMap").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Impostazioni")
        .fileExporter(isPresented: Binding(get: { backup != nil }, set: { if !$0 { backup = nil } }), document: backup,
                      contentType: .zip, defaultFilename: "cresta-backup-\(Format.isoDay(Date())).zip") { result in
            if case .success = result { model.show("Backup salvato") }
            backup = nil
        }
        .fileImporter(isPresented: $pickRestore, allowedContentTypes: [.zip, .data]) { result in
            if case .success(let url) = result { Task { await model.restoreBackup(from: url) } }
        }
        .confirmationDialog("Eliminare tutti i dati?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Elimina tutto", role: .destructive) { model.deleteAllData() }
        } message: { Text("Uscite, tracce, foto, cime e impostazioni verranno cancellate. Fai prima un backup.") }
    }

    private func binding<T>(_ kp: WritableKeyPath<CrestaCore.Settings, T>) -> Binding<T> {
        Binding(get: { model.data.settings[keyPath: kp] }, set: { v in model.mutate { $0.settings[keyPath: kp] = v } })
    }
}
