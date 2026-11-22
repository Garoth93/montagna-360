import SwiftUI
import AuthenticationServices
import UniformTypeIdentifiers
import CrestaCore

struct ImportHubView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @State private var pickZip = false
    @State private var pickFiles = false

    static var trackTypes: [UTType] {
        ["gpx", "fit", "tcx", "gz"].compactMap { UTType(filenameExtension: $0) } + [.xml, .data]
    }

    var body: some View {
        ScreenScroll {
            ImportOptionCard(icon: "archivebox.fill", colorHex: "#fc4c02", title: "Archivio Strava (primo import)",
                             text: "Sul sito Strava: Impostazioni › Il mio account › Scarica o elimina il tuo account › «Richiedi il tuo archivio». Salva lo ZIP in File e aprilo qui: vedrai l'anteprima, potrai filtrare per sport e i doppioni verranno saltati.",
                             button: "Scegli lo ZIP") { pickZip = true }
            ImportOptionCard(icon: "doc.badge.plus", colorHex: "#2e7d32", title: "File GPX, FIT o TCX",
                             text: "Uno o più file, anche compressi .gz. Il tipo di uscita viene proposto da traccia e velocità.",
                             button: "Scegli i file") { pickFiles = true }
            StravaSyncCard()
            NavigationLink { StravaSettingsView() } label: {
                Label("Credenziali API Strava", systemImage: "key.fill").frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
        .navigationTitle("Importa")
        .fileImporter(isPresented: $pickZip, allowedContentTypes: [.zip, .archive, .data]) { result in
            if case .success(let url) = result { model.openExport(url: url) }
        }
        .fileImporter(isPresented: $pickFiles, allowedContentTypes: Self.trackTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty { model.importFiles(urls) }
        }
    }
}

struct ImportOptionCard: View {
    @Environment(\.m3) private var m3
    let icon: String
    let colorHex: String
    let title: String
    let text: String
    let button: String
    let action: () -> Void

    var body: some View {
        let t = m3.tones(colorHex)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(icon: icon, tones: t, size: 48, filled: true)
                Text(title).font(.m3TitleMedium).foregroundStyle(t.onContainer)
            }
            Text(text).font(.m3BodyMedium).foregroundStyle(t.onContainer.opacity(0.85))
            PillButton(title: button, icon: "folder.fill", tones: t, height: 48, action: action)
        }
        .padding(18)
        .background(t.container, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }
}

/// Strava API: connection status and incremental sync.
struct StravaSyncCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var connecting = false

    var body: some View {
        let s = model.data.strava
        M3Card(corner: 30) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconBadge(icon: "arrow.triangle.2.circlepath", tones: m3.tones("#fc4c02"), size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sincronizzazione Strava").font(.m3TitleMedium).foregroundStyle(m3.onSurface)
                        Text(s.connected ? "Collegato\(model.stravaAthlete.map { " come \($0)" } ?? "")" : "Non collegato")
                            .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
                    }
                }
                if !model.stravaConfigured {
                    Text("Per collegare Strava servono Client ID e Client Secret di un'app API Strava: inseriscili in «Credenziali API Strava».")
                        .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
                } else if s.connected {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.stravaSyncing { Label("Sincronizzazione in corso…", systemImage: "arrow.triangle.2.circlepath").symbolEffect(.rotate) }
                        if !s.pending.isEmpty { Text("\(s.pending.count) attività in coda") }
                        if let wait = s.rate.waitUntil() { Text("Limite richieste raggiunto: riprendo da solo alle \(Format.time(wait))") }
                        if let last = s.lastSync { Text("Ultima sincronizzazione: \(Format.dayMonth(last)) alle \(Format.time(last))") }
                        Text("Importate finora: \(s.importedCount)")
                        if let e = s.lastError { Text(e).foregroundStyle(m3.error) }
                    }
                    .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
                    HStack {
                        Button { model.syncStrava() } label: { Label("Sincronizza ora", systemImage: "arrow.clockwise") }
                            .buttonStyle(.borderedProminent).disabled(model.stravaSyncing)
                        Spacer()
                        Button("Scollega", role: .destructive) { model.disconnectStrava() }
                    }
                } else {
                    Button {
                        Task { await connect() }
                    } label: {
                        HStack { if connecting { ProgressView() }; Text("Collega Strava") }.frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(rgb: RGBColor(hex: "#fc4c02")!))
                    Text("Dopo il primo collegamento le nuove attività arrivano da sole. I limiti di richieste di Strava vengono rispettati: se si raggiungono, la sincronizzazione riprende appena possibile.")
                        .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
                }
            }
        }
    }

    private func connect() async {
        connecting = true
        defer { connecting = false }
        let config = StravaCredentials.config
        do {
            let callback = try await webAuth.authenticate(using: config.authorizeURL, callbackURLScheme: "cresta",
                                                          preferredBrowserSession: .shared)
            guard let code = StravaConfig.code(fromCallback: callback) else {
                model.errorMessage = "Autorizzazione Strava non completata."
                return
            }
            await model.connectStrava(code: code)
        } catch {
            if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                model.errorMessage = "Collegamento non riuscito: \(error.localizedDescription)"
            }
        }
    }
}

struct StravaSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var clientID = Keychain.string("strava.clientID") ?? ""
    @State private var secret = Keychain.string("strava.clientSecret") ?? ""

    var body: some View {
        Form {
            Section {
                TextField("Client ID", text: $clientID).keyboardType(.numberPad)
                SecureField("Client Secret", text: $secret)
                Button("Salva") {
                    Keychain.setString(clientID.nonEmpty, for: "strava.clientID")
                    Keychain.setString(secret.nonEmpty, for: "strava.clientSecret")
                    model.show("Credenziali salvate", icon: "key.fill")
                }
            } footer: {
                Text(StravaCredentials.fromBuild
                     ? "L'app contiene già le credenziali della configurazione di build. Quelle inserite qui hanno la precedenza."
                     : "Crea un'app su strava.com/settings/api con «Authorization Callback Domain» = localhost. Le credenziali restano nel portachiavi del telefono.")
            }
        }
        .navigationTitle("API Strava")
    }
}

/// Strava export: preview with filters, then progress.
struct ExportImportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScreenScroll {
                if let job = model.importJob, job.title.hasPrefix("Import archivio") {
                    ImportProgressContent(job: job)
                } else if let s = model.exportSession {
                    switch s.phase {
                    case .reading:
                        VStack(spacing: 16) {
                            ProgressView().controlSize(.large)
                            Text("Leggo \(s.fileName)…").font(.m3BodyLarge)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 80)
                    case .failed(let msg):
                        EmptyStateView(icon: "exclamationmark.triangle.fill", title: "Archivio non valido", message: msg)
                    case .preview:
                        if let p = s.preview { preview(p, s) }
                    }
                }
            }
            .navigationTitle("Archivio Strava")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if model.importJob?.phase != .running {
                        Button("Chiudi") { model.importJob = nil; dismiss() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func preview(_ p: ExportPreview, _ s: ExportSession) -> some View {
        let total = p.activities.count
        let withFile = p.activities.filter(\.hasFile).count
        HStack(spacing: 10) {
            StatTile(value: "\(total)", label: "attività", icon: "list.bullet")
            StatTile(value: "\(withFile)", label: "con traccia GPS", icon: "point.topleft.down.to.point.bottomright.curvepath")
            StatTile(value: "\(p.duplicates.count)", label: "già nel diario", icon: "doc.on.doc", tones: m3.warningTones)
        }
        if let first = p.activities.compactMap(\.date).min(), let last = p.activities.compactMap(\.date).max() {
            Text("Dal \(Format.dayMonthYear(first)) al \(Format.dayMonthYear(last))").font(.m3BodyMedium).foregroundStyle(m3.onSurfaceVariant)
        }
        SectionTitle("Sport da importare")
        let kinds = ActivityKind.allCases.filter { (p.countsByKind[$0] ?? 0) > 0 }
        ForEach(kinds) { k in
            Toggle(isOn: Binding(get: { model.exportSession?.kinds.contains(k) ?? false }, set: { on in
                if on { model.exportSession?.kinds.insert(k) } else { model.exportSession?.kinds.remove(k) }
            })) {
                Label("\(k.title) (\(p.countsByKind[k] ?? 0))", systemImage: k.icon).font(.m3BodyLarge)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        if let other = p.countsByKind[nil], other > 0 {
            Toggle(isOn: Binding(get: { model.exportSession?.includeOther ?? false }, set: { model.exportSession?.includeOther = $0 })) {
                Label("Altri sport (\(other))", systemImage: "ellipsis.circle").font(.m3BodyLarge)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        Toggle("Salta i doppioni", isOn: Binding(get: { model.exportSession?.skipDuplicates ?? true }, set: { model.exportSession?.skipDuplicates = $0 }))
            .padding(.horizontal, 4)
        let count = s.selection.count
        PillButton(title: count == 0 ? "Nessuna attività selezionata" : "Importa \(count) attività", icon: "square.and.arrow.down.fill",
                   tones: m3.primaryTones) {
            if count > 0 { model.startExportImport() }
        }
        .disabled(count == 0)
        Text("Le vette lungo le tracce vengono timbrate in automatico. Il meteo storico viene aggiunto poco alla volta quando l'app è aperta e c'è rete.")
            .font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant)
    }
}

struct ImportProgressSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            ScreenScroll {
                if let job = model.importJob { ImportProgressContent(job: job) }
            }
            .navigationTitle(model.importJob?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if model.importJob?.phase != .running { Button("Fine") { model.importJob = nil } }
                }
            }
        }
    }
}

struct ImportProgressContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    let job: ImportJob

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(job.phase == .running ? "In corso" : job.phase == .cancelled ? "Interrotto" : "Completato")
                    .font(.m3HeadlineSmall).foregroundStyle(m3.onSurface)
                Spacer()
                Text("\(Int(job.fraction * 100))%").font(.m3TitleLarge).contentTransition(.numericText()).foregroundStyle(m3.primary)
            }
            M3Progress(value: job.fraction, height: 14)
            Text("\(job.done) di \(job.total)").font(.m3BodyMedium).foregroundStyle(m3.onSurfaceVariant)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                StatTile(value: "\(job.imported)", label: "importate", icon: "checkmark.circle.fill", tones: m3.successTones)
                StatTile(value: "\(job.duplicates)", label: "già presenti", icon: "doc.on.doc")
                StatTile(value: "\(job.summits)", label: "cime timbrate", icon: "flag.fill", tones: m3.tertiaryTones)
                StatTile(value: "\(job.failed)", label: "senza dati utili", icon: "exclamationmark.triangle")
            }
            if !job.status.isEmpty { Text(job.status).font(.m3BodyMedium).foregroundStyle(m3.onSurfaceVariant) }
            if job.phase == .running {
                Button("Interrompi", role: .destructive) { model.cancelImport() }.frame(maxWidth: .infinity)
            }
        }
        .animation(.m3Effects, value: job.done)
    }
}
