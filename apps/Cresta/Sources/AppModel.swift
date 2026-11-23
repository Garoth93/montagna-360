import SwiftUI
import BackgroundTasks
import WidgetKit
import CrestaCore

enum AppTab: Hashable {
    case home, diary, peaks, tools, settings
}

/// A running or finished import (export ZIP, files, Strava).
struct ImportJob: Identifiable, Equatable {
    enum Phase: Equatable { case running, finished, failed, cancelled }
    let id = UUID()
    var title: String
    var phase: Phase = .running
    var total = 0
    var done = 0
    var imported = 0
    var duplicates = 0
    var failed = 0
    var summits = 0
    var status = ""

    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
}

/// Strava export opened from Files, before and during the import.
struct ExportSession: Identifiable {
    enum Phase: Equatable { case reading, preview, failed(String) }
    let id = UUID()
    var fileName: String
    var phase: Phase = .reading
    var preview: ExportPreview?
    var kinds: Set<ActivityKind> = Set(ActivityKind.allCases)
    var includeOther = false
    var skipDuplicates = true

    var selection: [StravaExportActivity] {
        preview?.selection(kinds: kinds, includeOther: includeOther, skipDuplicates: skipDuplicates) ?? []
    }
}

/// Cached data for one Go/No-Go place (kept on disk: works offline).
struct GoCache: Codable, Equatable {
    var forecast: Data?
    var avalanche: AvalancheReport?
    var fetchedAt: Date

    var response: OpenMeteo.Response? { forecast.flatMap { try? OpenMeteo.decode($0) } }
}

actor DataWriter {
    private let store = JSONFileStore<AppData>(url: AppFiles.data, compact: true)
    private var lastRevision = -1

    func save(_ data: AppData, revision: Int) throws {
        guard revision > lastRevision else { return }
        try store.save(data)
        lastRevision = revision
    }
}

/// Bridges the Strava engine (any thread) to the main-actor model.
final class StravaBridge: StravaSyncDelegate, @unchecked Sendable {
    weak var model: AppModel?

    init(model: AppModel) { self.model = model }

    func tokensChanged(_ tokens: StravaTokens) async { StravaCredentials.tokens = tokens }

    func stateChanged(_ state: StravaSyncState) async {
        await MainActor.run { model?.updateStravaState(state) }
    }

    func importActivity(_ s: StravaSummary, track: Track?) async -> Bool {
        let parsed = track.map { ParsedTrack(track: $0) }
        let fallback = TrackStats(distance: s.distance ?? 0, ascent: s.total_elevation_gain ?? 0, elapsed: s.elapsed_time ?? 0,
                                  moving: s.moving_time ?? 0, maxSpeed: s.max_speed ?? 0)
        guard let m = model else { return false }
        let (gear, index, areas, sports) = await MainActor.run { (m.data.gear, m.peakIndex, m.skiAreaIndex, m.data.settings.syncSports) }
        // Sports excluded from the sync are skipped (not imported).
        if let k = ActivityKind.fromStrava(s.sport), !sports.contains(k) { return false }
        guard let built = OutingBuilder.build(parsed: parsed, name: s.name, sport: s.sport, start: s.startDate, source: .stravaAPI,
                                              stravaID: s.id, fallback: fallback, gear: gear, skiAreas: areas) else { return false }
        let matches = built.track.map { SummitMatcher.match(track: $0, index: index) } ?? []
        return await MainActor.run { m.ingest(built.outing, track: built.track, matches: matches) }
    }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var data = AppData()
    private(set) var isLoaded = false
    private(set) var peakIndex = PeakIndex(peaks: [])
    private(set) var skiAreaIndex = PeakIndex(peaks: [])
    private(set) var bundledCounts: [PeakKind: Int] = [:]
    var bundledPeakCount: Int { bundledCounts[.peak] ?? 0 }
    private(set) var stravaSyncing = false
    private(set) var weatherBackfillRunning = false
    var tab: AppTab = .home
    /// Navigation of the Strumenti tab (the widget opens Go/No-Go there).
    var toolsPath = NavigationPath()
    var toast: Toast?
    var errorMessage: String?
    var importJob: ImportJob?
    var exportSession: ExportSession?
    var goCache: [UUID: GoCache] = [:]
    var webcamRatings: [UUID: WebcamRating] = [:]
    var isActive = false

    private let writer = DataWriter()
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var exportReader: StravaExportReader?
    @ObservationIgnored private var exportURL: URL?
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var weatherTried = Set<UUID>()
    @ObservationIgnored private var resumeTask: Task<Void, Never>?
    @ObservationIgnored private var widgetTask: Task<Void, Never>?
    @ObservationIgnored private var bridge: StravaBridge!

    static let syncTaskID = "com.garoth93.cresta.sync"

    private init() {
        bridge = StravaBridge(model: self)
        Task { await load() }
    }

    // MARK: - Loading and saving

    private func load() async {
        let url = AppFiles.data
        let result = await Task.detached(priority: .userInitiated) { () -> Result<AppData?, Error> in
            do { return .success(try JSONFileStore<AppData>(url: url).load()) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let loaded):
            data = loaded ?? AppData()
        case .failure:
            // Never overwrite an unreadable file: keep it aside.
            let aside = url.deletingLastPathComponent().appendingPathComponent("cresta-data-illeggibile-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            data = AppData()
            errorMessage = "Il file dei dati non era leggibile ed è stato messo da parte. L'app riparte vuota: puoi ripristinare un backup dalle Impostazioni."
        }
        if let cache = try? JSONFileStore<[UUID: GoCache]>(url: AppFiles.weatherCache).load() { goCache = cache }
        revision = data.revision
        isLoaded = true
        let loaded = await Task.detached(priority: .utility) { PeakDatabase.load() }.value
        peakIndex = PeakIndex(peaks: loaded.places + data.userPeaks)
        skiAreaIndex = PeakIndex(peaks: loaded.skiAreas)
        bundledCounts = loaded.bundled
        upgradeExistingData()
        if isActive { becameActive() }
        Task { await CloudBackupService.shared.offerRestoreIfNeeded() }
        scheduleWidgetUpdate()
    }

    /// Once per new database: stamps passes on stored tracks and names the
    /// ski areas of resort days imported before these features existed.
    private func upgradeExistingData() {
        let key = "upgrade.passes-areas.v1"
        guard !UserDefaults.standard.bool(forKey: key), data.outings.contains(where: \.hasTrack),
              peakIndex.count(of: .pass) > 0 || skiAreaIndex.count > 0 else { return }
        UserDefaults.standard.set(true, forKey: key)
        rematchAllSummits(silent: true)
    }

    func mutate(_ change: (inout AppData) -> Void) {
        change(&data)
        revision += 1
        data.revision = revision
        scheduleSave()
        CloudBackupService.shared.schedule()
        scheduleWidgetUpdate()
    }

    // MARK: - Widget

    /// Shares the place shown in "Oggi" with the Go/No-Go widget (debounced).
    func scheduleWidgetUpdate() {
        widgetTask?.cancel()
        widgetTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            publishWidget()
        }
    }

    func publishWidget() {
        guard isLoaded else { return }
        let t = data.goTargets.first
        let cache = t.flatMap { goCache[$0.id] }
        let snap = GoWidgetSnapshot(target: t, forecast: cache?.forecast, avalanche: cache?.avalanche, fetchedAt: cache?.fetchedAt,
                                    factors: data.settings.goFactors, winter: seasonKind == .winter, seed: seedColor,
                                    webcam: t.flatMap { webcamRatings[$0.id] })
        Task.detached(priority: .utility) {
            if SharedStore.saveGo(snap) { WidgetCenter.shared.reloadTimelines(ofKind: "GoNoGo") }
        }
    }

    func handle(url: URL) {
        guard url.scheme == "cresta" else { return }
        if url.host == "go" {
            tab = .tools
            toolsPath = NavigationPath()
            toolsPath.append(Tool.goNoGo)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = data
        let rev = revision
        let writer = writer
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await Self.write(writer, snapshot, rev)
        }
    }

    private nonisolated static func write(_ writer: DataWriter, _ data: AppData, _ rev: Int) async {
        try? await writer.save(data, revision: rev)
    }

    func saveNow() {
        saveTask?.cancel()
        let snapshot = data, rev = revision, writer = writer
        BackgroundWork.run("save") { await Self.write(writer, snapshot, rev) }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            becameActive()
        } else {
            saveNow()
            if data.settings.cloudBackup {
                BackgroundWork.run("cresta-icloud-backup") { await CloudBackupService.shared.backup(force: false) }
            }
            scheduleBackgroundSync()
        }
    }

    private func becameActive() {
        guard isLoaded else { return }
        autoResetBackpacksIfNeeded()
        if data.strava.connected { syncStrava(silent: true) }
        backfillWeather()
    }

    func show(_ message: String, icon: String = "checkmark.circle.fill", style: Toast.Style = .success) {
        toast = Toast(message: message, icon: icon, style: style)
        let id = toast?.id
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            if toast?.id == id { toast = nil }
        }
    }

    // MARK: - Season and theme

    var seasonKind: Season.Kind { data.currentSeasonKind }

    var seedColor: String {
        switch data.settings.colorMode {
        case .seasonal: return seasonKind == .winter ? Palette.winterSeed : Palette.summerSeed
        case .custom: return data.settings.customSeed
        }
    }

    func toggleSeason() {
        let next: SeasonMode = seasonKind == .winter ? .summer : .winter
        mutate { $0.settings.seasonMode = next }
    }

    // MARK: - Outings

    var outingsSorted: [Outing] { data.outings.sorted { $0.start > $1.start } }

    func outing(_ id: UUID) -> Outing? { data.outings.first { $0.id == id } }

    /// Adds an outing (with its track and summits) unless it is a duplicate.
    @discardableResult
    func ingest(_ outing: Outing, track: Track?, matches: [SummitMatcher.Match]) -> Bool {
        if DuplicateDetector.isDuplicate(stravaID: outing.stravaID, start: outing.start, distance: outing.stats.distance, in: data.outings) {
            return false
        }
        var o = outing
        if let track, !track.isEmpty { TrackStore.save(track, for: o.id) }
        var newStamps: [SummitStamp] = []
        if data.settings.autoMatchSummits {
            for m in matches {
                guard let peak = peakIndex.peak(id: m.peakID) else { continue }
                newStamps.append(SummitStamp(peak: peak, date: m.time ?? o.start, mode: o.kind.summitMode, outingID: o.id, automatic: true))
            }
        }
        o.summitStampIDs = newStamps.map(\.id)
        mutate {
            $0.outings.append(o)
            $0.stamps.append(contentsOf: newStamps)
        }
        if importJob?.phase == .running { importJob?.summits += newStamps.count }
        return true
    }

    func update(_ outing: Outing) {
        mutate { d in
            if let i = d.outings.firstIndex(where: { $0.id == outing.id }) { d.outings[i] = outing }
        }
    }

    /// Changes the kind by hand; the summit stamps of the outing follow
    /// unless they were set by hand too.
    func setKind(_ kind: ActivityKind, for id: UUID) {
        mutate { d in
            guard let i = d.outings.firstIndex(where: { $0.id == id }) else { return }
            d.outings[i].kind = kind
            d.outings[i].kindIsManual = true
            for s in d.stamps.indices where d.stamps[s].outingID == id && !d.stamps[s].modeIsManual {
                d.stamps[s].mode = kind.summitMode
            }
        }
    }

    func deleteOuting(_ id: UUID) {
        guard let o = outing(id) else { return }
        TrackStore.delete(id)
        o.photos.forEach(PhotoStore.delete)
        mutate { d in
            d.outings.removeAll { $0.id == id }
            d.stamps.removeAll { $0.outingID == id && $0.automatic }
            for i in d.stamps.indices where d.stamps[i].outingID == id { d.stamps[i].outingID = nil }
        }
    }

    func addManualOuting(name: String, kind: ActivityKind, start: Date, duration: TimeInterval, distance: Double, ascent: Double) -> UUID {
        let o = Outing(name: name.nonEmpty ?? OutingBuilder.defaultName(kind: kind, date: start), kind: kind, kindIsManual: true, start: start,
                       stats: TrackStats(distance: distance, ascent: ascent, descent: ascent, elapsed: duration, moving: duration),
                       hasTrack: false, source: .manual, gearIDs: GarageLogic.defaultGear(for: kind, gear: data.gear))
        mutate { $0.outings.append(o) }
        resetBackpackChecks(for: o)
        return o.id
    }

    func addPhoto(_ imageData: Data, to id: UUID) {
        guard let name = PhotoStore.save(imageData) else { return }
        mutate { d in
            if let i = d.outings.firstIndex(where: { $0.id == id }) { d.outings[i].photos.append(name) }
        }
    }

    func removePhoto(_ name: String, from id: UUID) {
        PhotoStore.delete(name)
        mutate { d in
            if let i = d.outings.firstIndex(where: { $0.id == id }) { d.outings[i].photos.removeAll { $0 == name } }
        }
    }

    /// Re-runs the automatic summit matching on all stored tracks.
    func rematchAllSummits(silent: Bool = false) {
        let outings = data.outings.filter(\.hasTrack)
        let index = peakIndex
        let areas = skiAreaIndex
        let radius = data.settings.summitRadius
        if !silent {
            importJob = ImportJob(title: "Abbinamento cime e passi", total: outings.count, status: "Cerco cime, passi e comprensori lungo le tracce…")
        }
        Task.detached(priority: silent ? .utility : .userInitiated) {
            var results: [(UUID, [SummitMatcher.Match], String?)] = []
            for (n, o) in outings.enumerated() {
                if let t = TrackStore.load(o.id) {
                    let area = (o.kind == .resortSki || o.kind == .snowboard) ? SkiAreaNamer.name(for: t, areas: areas) : nil
                    results.append((o.id, SummitMatcher.match(track: t, index: index, radius: radius), area))
                }
                if !silent, n % 25 == 0 { await MainActor.run { AppModel.shared.importJob?.done = n } }
            }
            let final = results
            await MainActor.run { AppModel.shared.applyMatches(final, silent: silent) }
        }
    }

    private func applyMatches(_ results: [(UUID, [SummitMatcher.Match], String?)], silent: Bool = false) {
        var added = 0
        mutate { d in
            for (oid, matches, area) in results {
                guard let oi = d.outings.firstIndex(where: { $0.id == oid }) else { continue }
                if let area, d.outings[oi].area == nil { d.outings[oi].area = area }
                for m in matches {
                    if d.stamps.contains(where: { $0.outingID == oid && $0.peakID == m.peakID }) { continue }
                    guard let peak = peakIndex.peak(id: m.peakID) else { continue }
                    let s = SummitStamp(peak: peak, date: m.time ?? d.outings[oi].start, mode: d.outings[oi].kind.summitMode, outingID: oid, automatic: true)
                    d.stamps.append(s)
                    d.outings[oi].summitStampIDs.append(s.id)
                    added += 1
                }
            }
        }
        if silent {
            if added > 0 { show("Trovati \(added) nuovi timbri tra cime e passi", icon: "flag.fill") }
        } else {
            importJob?.done = importJob?.total ?? 0
            importJob?.summits = added
            importJob?.phase = .finished
            importJob?.status = added == 0 ? "Nessuna nuova cima o passo trovato." : "Trovati \(added) nuovi timbri."
        }
        backfillWeather()
    }

    // MARK: - Summits

    func addStamp(peak: Peak, date: Date, mode: SummitMode, outingID: UUID? = nil, note: String = "") {
        let s = SummitStamp(peak: peak, date: date, mode: mode, modeIsManual: true, outingID: outingID, note: note)
        mutate { d in
            d.stamps.append(s)
            if let oid = outingID, let i = d.outings.firstIndex(where: { $0.id == oid }) { d.outings[i].summitStampIDs.append(s.id) }
        }
        show("Cima timbrata: \(peak.name)", icon: "flag.fill")
        Task { await fetchWeather(stamp: s.id) }
    }

    func setStampMode(_ mode: SummitMode, stamp id: UUID) {
        mutate { d in
            if let i = d.stamps.firstIndex(where: { $0.id == id }) { d.stamps[i].mode = mode; d.stamps[i].modeIsManual = true }
        }
    }

    func deleteStamp(_ id: UUID) {
        mutate { d in
            d.stamps.removeAll { $0.id == id }
            for i in d.outings.indices { d.outings[i].summitStampIDs.removeAll { $0 == id } }
        }
    }

    func addUserPeak(name: String, coordinate: Coordinate, elevation: Double?) -> Peak {
        let p = Peak(id: "user:\(UUID().uuidString)", name: name, lat: coordinate.lat, lon: coordinate.lon, elevation: elevation)
        mutate { $0.userPeaks.append(p) }
        peakIndex = PeakIndex(peaks: peakIndex.peaks + [p])
        return p
    }

    /// Distinct peaks reached, newest stamp first.
    var collectedPeaks: [(peakID: String, stamps: [SummitStamp])] {
        Dictionary(grouping: data.stamps, by: \.peakID)
            .map { (peakID: $0.key, stamps: $0.value.sorted { $0.date > $1.date }) }
            .sorted { ($0.stamps.first?.date ?? .distantPast) > ($1.stamps.first?.date ?? .distantPast) }
    }

    /// Downloads peaks, passes and ski areas of a zone for offline use.
    func downloadPeaks(in box: BoundingBox) async {
        var places: [Peak] = []
        var areas: [Peak] = []
        var failed = false
        for kind in PeakKind.allCases {
            do {
                let list = try await OverpassService.places(in: box, kind: kind)
                await Task.detached { PeakDatabase.appendDownloaded(list, kind: kind) }.value
                if kind == .skiArea { areas += list } else { places += list }
            } catch { failed = true }
        }
        if !places.isEmpty { peakIndex = PeakIndex(peaks: peakIndex.peaks + places) }
        if !areas.isEmpty { skiAreaIndex = PeakIndex(peaks: skiAreaIndex.peaks + areas) }
        if places.isEmpty && areas.isEmpty && failed {
            show("Download non riuscito: riprova più tardi", icon: "wifi.exclamationmark", style: .error)
        } else {
            show("Scaricate \(places.count) tra cime e passi per l'uso offline", icon: "arrow.down.circle.fill")
        }
    }

    // MARK: - Weather backfill

    func fetchWeather(stamp id: UUID) async {
        guard let s = data.stamps.first(where: { $0.id == id }) else { return }
        if let w = await WeatherService.snapshot(at: s.date, coordinate: s.coordinate, elevation: s.elevation) {
            mutate { d in if let i = d.stamps.firstIndex(where: { $0.id == id }) { d.stamps[i].weather = w } }
        }
    }

    func fetchWeather(outing id: UUID) async {
        guard let o = outing(id), let c = o.startCoordinate else { return }
        let mid = o.start.addingTimeInterval(o.stats.elapsed / 2)
        if let w = await WeatherService.snapshot(at: mid, coordinate: c, elevation: nil) {
            mutate { d in if let i = d.outings.firstIndex(where: { $0.id == id }) { d.outings[i].weather = w } }
        }
    }

    /// Fills in the weather of imported outings and stamps, slowly, while the app is open.
    func backfillWeather() {
        guard data.settings.fetchWeatherForImports, !weatherBackfillRunning else { return }
        weatherBackfillRunning = true
        Task {
            var failures = 0
            while isActive, failures < 5 {
                let stamp = data.stamps.first { $0.weather == nil && !weatherTried.contains($0.id) }
                let outing = stamp == nil ? data.outings.first { $0.weather == nil && $0.startCoordinate != nil && !weatherTried.contains($0.id) } : nil
                guard stamp != nil || outing != nil else { break }
                if let s = stamp {
                    weatherTried.insert(s.id)
                    await fetchWeather(stamp: s.id)
                    if data.stamps.first(where: { $0.id == s.id })?.weather == nil { failures += 1 } else { failures = 0 }
                } else if let o = outing {
                    weatherTried.insert(o.id)
                    await fetchWeather(outing: o.id)
                    if self.outing(o.id)?.weather == nil { failures += 1 } else { failures = 0 }
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
            weatherBackfillRunning = false
        }
    }

    // MARK: - Import: Strava export ZIP

    func openExport(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        exportURL = scoped ? url : nil
        var session = ExportSession(fileName: url.lastPathComponent)
        session.kinds = data.settings.importSports
        exportSession = session
        let existing = data.outings
        Task.detached(priority: .userInitiated) {
            do {
                let reader = try StravaExportReader(url: url)
                let preview = reader.preview(existing: existing)
                await MainActor.run {
                    AppModel.shared.exportReader = reader
                    AppModel.shared.exportSession?.preview = preview
                    AppModel.shared.exportSession?.phase = .preview
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "Archivio non leggibile. Serve lo ZIP «Scarica i tuoi dati» di Strava."
                await MainActor.run { AppModel.shared.exportSession?.phase = .failed(msg) }
            }
        }
    }

    func closeExport() {
        if importJob?.phase == .running { return }
        exportSession = nil
        exportReader = nil
        exportURL?.stopAccessingSecurityScopedResource()
        exportURL = nil
    }

    func startExportImport() {
        guard let session = exportSession, let reader = exportReader else { return }
        let list = session.selection
        mutate { $0.settings.importSports = session.kinds }
        cancelRequested = false
        importJob = ImportJob(title: "Import archivio Strava", total: list.count, status: "Importo le attività…")
        let gear = data.gear
        let index = peakIndex
        let areas = skiAreaIndex
        let radius = data.settings.summitRadius
        Task.detached(priority: .userInitiated) {
            var batch: [(Outing, Track?, [SummitMatcher.Match])] = []
            var failed = 0
            func flush(_ done: Int) async {
                let b = batch
                let f = failed
                batch.removeAll()
                await MainActor.run {
                    let m = AppModel.shared
                    for (o, t, ms) in b {
                        if m.ingest(o, track: t, matches: ms) { m.importJob?.imported += 1 } else { m.importJob?.duplicates += 1 }
                    }
                    m.importJob?.failed = f
                    m.importJob?.done = done
                }
            }
            for (n, a) in list.enumerated() {
                if await MainActor.run(body: { AppModel.shared.cancelRequested }) { break }
                autoreleasepool {
                    if let built = reader.outing(for: a, gear: gear, skiAreas: areas) {
                        let matches = built.track.map { SummitMatcher.match(track: $0, index: index, radius: radius) } ?? []
                        batch.append((built.outing, built.track, matches))
                    } else {
                        failed += 1
                    }
                }
                if batch.count >= 15 { await flush(n + 1) }
            }
            await flush(list.count)
            await MainActor.run { AppModel.shared.finishImport() }
        }
    }

    func cancelImport() { cancelRequested = true }

    private func finishImport() {
        guard var job = importJob else { return }
        job.phase = cancelRequested ? .cancelled : .finished
        job.done = cancelRequested ? job.done : job.total
        job.status = "\(job.imported) importate · \(job.duplicates) già presenti" + (job.failed > 0 ? " · \(job.failed) senza dati" : "")
        importJob = job
        applySourceGear()
        if exportSession != nil, let reader = exportReader { exportSession?.preview = reader.preview(existing: data.outings) }
        saveNow()
        backfillWeather()
    }

    // MARK: - Import: single files

    func importFiles(_ urls: [URL]) {
        importJob = ImportJob(title: "Import file", total: urls.count, status: "Leggo i file…")
        let gear = data.gear
        let index = peakIndex
        let areas = skiAreaIndex
        let radius = data.settings.summitRadius
        Task.detached(priority: .userInitiated) {
            var lastID: UUID?
            for (n, url) in urls.enumerated() {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var result: (Outing, Track?, [SummitMatcher.Match])?
                if let d = try? Data(contentsOf: url), let parsed = try? TrackFileParser.parse(d, fileName: url.lastPathComponent),
                   let built = OutingBuilder.build(parsed: parsed, name: nil, sport: nil, start: nil, source: .file, gear: gear, skiAreas: areas) {
                    result = (built.outing, built.track, built.track.map { SummitMatcher.match(track: $0, index: index, radius: radius) } ?? [])
                }
                let r = result
                let added: UUID? = await MainActor.run {
                    let m = AppModel.shared
                    var id: UUID?
                    if let r {
                        if m.ingest(r.0, track: r.1, matches: r.2) { m.importJob?.imported += 1; id = r.0.id } else { m.importJob?.duplicates += 1 }
                    } else {
                        m.importJob?.failed += 1
                    }
                    m.importJob?.done = n + 1
                    return id
                }
                if let added { lastID = added }
            }
            let opened = lastID
            await MainActor.run {
                let m = AppModel.shared
                m.finishImport()
                if let id = opened, let o = m.outing(id) { m.resetBackpackChecks(for: o) }
            }
        }
    }

    // MARK: - Strava API

    var stravaConfigured: Bool { StravaCredentials.config.isComplete }
    var stravaAthlete: String? { StravaCredentials.tokens?.athleteName }

    func connectStrava(code: String) async {
        let client = StravaClient(config: StravaCredentials.config, tokens: nil, transport: URLSessionTransport())
        do {
            let tokens = try await client.exchange(code: code)
            StravaCredentials.tokens = tokens
            // Continue from the newest activity already in the diary.
            let newest = data.outings.filter { $0.source != .manual }.map(\.start).max()
            mutate {
                $0.strava.connected = true
                if $0.strava.after == 0 { $0.strava.startFrom = newest.map { $0.addingTimeInterval(-3 * 86_400) } }
            }
            show("Strava collegato", icon: "link")
            syncStrava()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func disconnectStrava() {
        StravaCredentials.tokens = nil
        mutate { $0.strava = StravaSyncState() }
    }

    func updateStravaState(_ s: StravaSyncState) {
        var copy = s
        copy.connected = s.connected || data.strava.connected
        if s.lastError == StravaError.unauthorized.errorDescription { copy.connected = false }
        mutate { $0.strava = copy }
    }

    func syncStrava(silent: Bool = false, maxRequests: Int = .max) {
        guard !stravaSyncing, data.strava.connected else { return }
        guard StravaCredentials.config.isComplete else {
            if !silent { errorMessage = StravaError.notConfigured.errorDescription }
            return
        }
        if let wait = data.strava.rate.waitUntil(), !silent {
            show("Limite Strava: riprendo alle \(Format.time(wait))", icon: "hourglass", style: .info)
        }
        stravaSyncing = true
        let before = data.strava.importedCount
        let client = StravaClient(config: StravaCredentials.config, tokens: StravaCredentials.tokens, transport: URLSessionTransport())
        let state = data.strava
        let bridge: StravaBridge = self.bridge
        Task {
            let result = await StravaSync.run(client: client, state: state, delegate: bridge, maxRequests: maxRequests)
            stravaSyncing = false
            updateStravaState(result)
            let added = result.importedCount - before
            if added > 0 { show("Strava: \(added) nuove uscite", icon: "arrow.triangle.2.circlepath") }
            scheduleResume()
            backfillWeather()
        }
    }

    /// Resumes automatically when the rate-limit window reopens.
    private func scheduleResume() {
        resumeTask?.cancel()
        let s = data.strava
        guard s.connected, !s.pending.isEmpty || s.rate.waitUntil() != nil else { return }
        let at = s.rate.waitUntil() ?? Date().addingTimeInterval(5)
        resumeTask = Task {
            try? await Task.sleep(for: .seconds(max(1, at.timeIntervalSinceNow)))
            guard !Task.isCancelled, isActive else { return }
            syncStrava(silent: true)
        }
        scheduleBackgroundSync()
    }

    /// Background refresh: Strava sync (if connected) and iCloud backup.
    func scheduleBackgroundSync() {
        guard data.strava.connected || data.settings.cloudBackup else { return }
        let req = BGAppRefreshTaskRequest(identifier: Self.syncTaskID)
        req.earliestBeginDate = (data.strava.connected ? data.strava.rate.waitUntil() : nil) ?? Date().addingTimeInterval(4 * 3600)
        try? BGTaskScheduler.shared.submit(req)
    }

    /// Background refresh: a few Strava requests, the iCloud backup, then reschedule.
    func runBackgroundSync() async {
        guard isLoaded else { return }
        if data.strava.connected, StravaCredentials.config.isComplete, !stravaSyncing {
            stravaSyncing = true
            let client = StravaClient(config: StravaCredentials.config, tokens: StravaCredentials.tokens, transport: URLSessionTransport())
            let delegate: StravaBridge = bridge
            let result = await StravaSync.run(client: client, state: data.strava, delegate: delegate, maxRequests: 30)
            stravaSyncing = false
            updateStravaState(result)
            saveNow()
        }
        await CloudBackupService.shared.backup(force: false)
        scheduleBackgroundSync()
    }

    /// Replaces the data with an iCloud backup (tracks/photos already copied).
    func restore(_ file: BackupFile) {
        var restored = file.data
        restored.onboardingDone = true
        // Tokens are not in backups: connected only if this phone still has them.
        restored.strava.connected = restored.strava.connected && StravaCredentials.tokens != nil
        for o in restored.outings where o.hasTrack && !FileManager.default.fileExists(atPath: TrackStore.url(o.id).path) {
            // Track not downloaded: keep the numbers, drop the map.
            if let i = restored.outings.firstIndex(where: { $0.id == o.id }) { restored.outings[i].hasTrack = false }
        }
        mutate { $0 = restored }
        peakIndex = PeakIndex(peaks: peakIndex.peaks + restored.userPeaks)
        show("Backup ripristinato: \(restored.outings.count) uscite", icon: "icloud.and.arrow.down.fill")
    }

    // MARK: - Backpacks

    func updateBackpack(_ b: Backpack) {
        mutate { d in if let i = d.backpacks.firstIndex(where: { $0.id == b.id }) { d.backpacks[i] = b } else { d.backpacks.append(b) } }
    }

    func deleteBackpack(_ id: UUID) { mutate { $0.backpacks.removeAll { $0.id == id } } }

    func toggleItem(_ itemID: UUID, in backpackID: UUID) {
        mutate { d in
            guard let b = d.backpacks.firstIndex(where: { $0.id == backpackID }),
                  let i = d.backpacks[b].items.firstIndex(where: { $0.id == itemID }) else { return }
            d.backpacks[b].items[i].checked.toggle()
            // Ticks made now belong to the next outing.
            if d.backpacks[b].lastReset == nil || d.outings.contains(where: { $0.createdAt > d.backpacks[b].lastReset! }) {
                d.backpacks[b].lastReset = Date()
            }
        }
    }

    /// New outing → all ticks start again.
    func resetBackpackChecks(for outing: Outing?) {
        mutate { d in for i in d.backpacks.indices { d.backpacks[i].resetChecks(for: outing?.id) } }
    }

    /// Ticks are reset automatically when an outing newer than the last reset exists.
    func autoResetBackpacksIfNeeded() {
        guard let newest = data.outings.map(\.createdAt).max() else { return }
        if data.backpacks.contains(where: { ($0.lastReset ?? .distantPast) < newest && $0.checkedCount > 0 }) {
            mutate { d in
                for i in d.backpacks.indices where (d.backpacks[i].lastReset ?? .distantPast) < newest {
                    d.backpacks[i].resetChecks(for: nil)
                }
            }
        }
    }

    // MARK: - Garage

    func updateGear(_ g: GearItem) {
        mutate { d in if let i = d.gear.firstIndex(where: { $0.id == g.id }) { d.gear[i] = g } else { d.gear.append(g) } }
        checkGarageAlerts()
    }

    func deleteGear(_ id: UUID) {
        mutate { d in
            d.gear.removeAll { $0.id == id }
            for i in d.outings.indices { d.outings[i].gearIDs.removeAll { $0 == id } }
        }
    }

    func logMaintenance(_ task: MaintenanceTask, gear id: UUID, date: Date = Date()) {
        mutate { d in
            if let i = d.gear.firstIndex(where: { $0.id == id }) { d.gear[i].history.append(MaintenanceRecord(task: task, date: date)) }
        }
        show("\(task.title) registrata", icon: task.icon)
    }

    /// Gear named by the source (Strava export) goes into the garage.
    func applySourceGear() {
        let r = GarageLogic.gearFromSources(outings: data.outings.filter { $0.sourceGear != nil }, gear: data.gear)
        guard !r.newItems.isEmpty || !r.assignments.isEmpty else { return }
        mutate { d in
            d.gear += r.newItems
            for i in d.outings.indices {
                if let g = r.assignments[d.outings[i].id], !d.outings[i].gearIDs.contains(g) { d.outings[i].gearIDs.append(g) }
            }
        }
        if !r.newItems.isEmpty { show("Garage: aggiunte \(r.newItems.count) attrezzature da Strava", icon: "shoe.fill") }
    }

    var garageAlerts: [(item: GearItem, status: MaintenanceStatus)] {
        GarageLogic.alerts(gear: data.gear, outings: data.outings)
    }

    func checkGarageAlerts() {
        guard data.settings.notificationsEnabled else { return }
        for a in garageAlerts where a.status.isDue {
            Notifier.schedule(id: "garage.\(a.item.id).\(a.status.task.rawValue)", title: "\(a.status.task.title) per \(a.item.name)",
                              body: "\(a.status.used) \(a.status.unitLabel) d'uso dall'ultima volta (intervallo \(a.status.interval)).",
                              at: Date().addingTimeInterval(5))
        }
    }

    // MARK: - Go/No-Go

    func addGoTarget(_ t: GoTarget) { mutate { $0.goTargets.append(t) } }

    func updateGoTarget(_ t: GoTarget) {
        mutate { d in if let i = d.goTargets.firstIndex(where: { $0.id == t.id }) { d.goTargets[i] = t } }
    }

    func deleteGoTarget(_ id: UUID) {
        mutate { $0.goTargets.removeAll { $0.id == id } }
        goCache[id] = nil
    }

    func moveGoTargetToTop(_ id: UUID) {
        mutate { d in
            guard let i = d.goTargets.firstIndex(where: { $0.id == id }) else { return }
            d.goTargets.insert(d.goTargets.remove(at: i), at: 0)
        }
    }

    /// Refreshes the places whose data is older than 30 minutes (or all).
    func refreshAllGo(force: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for t in data.goTargets where force || (goCache[t.id]?.fetchedAt.timeIntervalSinceNow ?? -99_999) < -1800 {
                group.addTask { await self.refreshGo(t) }
            }
        }
    }

    func refreshGo(_ t: GoTarget) async {
        async let forecast = try? Net.get(OpenMeteo.forecastURL(t.coordinate, pastDays: 30, elevation: t.elevation))
        async let avalanche = AvalancheService.fetch(region: t.avalancheRegion, fallbackURL: data.settings.avalancheFallbackURL)
        let (f, a) = await (forecast, avalanche)
        let old = goCache[t.id]
        goCache[t.id] = GoCache(forecast: f ?? old?.forecast, avalanche: a ?? old?.avalanche, fetchedAt: f != nil ? Date() : (old?.fetchedAt ?? Date()))
        if f == nil { show("Offline: uso gli ultimi dati salvati", icon: "wifi.slash", style: .info) }
        if t.id == data.goTargets.first?.id { scheduleWidgetUpdate() }
        let cache = goCache
        Task.detached { try? JSONFileStore<[UUID: GoCache]>(url: AppFiles.weatherCache).save(cache) }
    }

    func goResult(for t: GoTarget, from: Date, to: Date) -> GoNoGoResult {
        let cache = goCache[t.id]
        let r = cache?.response
        let input = GoNoGoInput(targetElevation: t.elevation, isWinterOuting: seasonKind == .winter,
                                avalanche: cache?.avalanche?.level(at: t.elevation),
                                weather: r.map { OpenMeteo.window($0, from: from, to: to) },
                                daysSinceSnowfall: r.flatMap { OpenMeteo.daysSinceSnowfall($0, before: from) },
                                webcam: webcamRatings[t.id])
        return GoNoGo.evaluate(input, enabled: data.settings.goFactors)
    }

    // MARK: - Last light

    func scheduleLastLight(_ plan: LastLightPlan, peakName: String) async -> Bool {
        guard let turn = plan.turnaround else { return false }
        guard await Notifier.requestAuthorization() else {
            errorMessage = "Le notifiche sono disattivate: abilitale in Impostazioni › Notifiche › Cresta."
            return false
        }
        let before = data.settings.lastLightNotifyBefore * 60
        Notifier.schedule(id: "lastlight.warning", title: "Tra \(Int(before / 60)) minuti si rientra",
                          body: "Ora limite per lasciare \(peakName): \(Format.time(turn)). Buio alle \(plan.civilDusk.map { Format.time($0) } ?? "—").",
                          at: turn.addingTimeInterval(-before))
        Notifier.schedule(id: "lastlight.turnaround", title: "Ora di rientrare",
                          body: "È l'ora limite per scendere da \(peakName) e arrivare con la luce.", at: turn)
        show("Avviso impostato per le \(Format.time(turn.addingTimeInterval(-before)))", icon: "bell.fill")
        return true
    }

    func cancelLastLight() {
        Notifier.cancel("lastlight.warning")
        Notifier.cancel("lastlight.turnaround")
    }

    // MARK: - Backup

    func makeBackup() async -> Data {
        let snapshot = data
        let ids = data.outings.filter(\.hasTrack).map(\.id)
        return await Task.detached(priority: .userInitiated) {
            let z = ZipWriter()
            if let d = try? JSONFileStore<AppData>.encoder(compact: true).encode(snapshot) { z.add(d, as: "cresta-data.json") }
            for id in ids {
                if let d = try? Data(contentsOf: TrackStore.url(id)) { z.add(d, as: "tracks/\(id.uuidString).json") }
            }
            return z.finish()
        }.value
    }

    func restoreBackup(from url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let result: AppData? = await Task.detached(priority: .userInitiated) { () -> AppData? in
            guard let zip = try? ZipArchive(url: url), let e = zip.entry(named: "cresta-data.json"),
                  let d = try? zip.data(for: e), let restored = try? JSONFileStore<AppData>.decoder.decode(AppData.self, from: d) else { return nil }
            for entry in zip.entries where entry.name.hasPrefix("tracks/") && !entry.isDirectory {
                if let td = try? zip.data(for: entry) {
                    try? td.write(to: AppFiles.tracks.appendingPathComponent(String(entry.name.dropFirst(7))), options: .atomic)
                }
            }
            return restored
        }.value
        guard let restored = result else {
            errorMessage = "Questo file non è un backup di Cresta."
            return
        }
        mutate { $0 = restored }
        peakIndex = PeakIndex(peaks: peakIndex.peaks + restored.userPeaks)
        show("Backup ripristinato: \(restored.outings.count) uscite")
    }

    func deleteAllData() {
        for o in data.outings { TrackStore.delete(o.id); o.photos.forEach(PhotoStore.delete) }
        StravaCredentials.tokens = nil
        var fresh = AppData()
        fresh.onboardingDone = true
        mutate { $0 = fresh }
        goCache = [:]
        show("Dati eliminati", icon: "trash.fill", style: .info)
    }
}
