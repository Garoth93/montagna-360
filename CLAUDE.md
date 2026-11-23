# CLAUDE.md — regole di lavoro per questa repo

App iOS **nativa (Swift + SwiftUI)** sviluppata senza Mac: il codice viene
scritto su Linux (Claude Code) e compilato **solo** su GitHub Actions con
runner macOS. Non va su App Store: l'app arriva sull'iPhone con **TestFlight**
(account Apple a pagamento, firma automatica in CI, `testflight.yml`); il
`.ipa` non firmato per Sideloadly (`build-ipa.yml`) resta come ripiego.

Stessa impostazione delle repo `Garoth93/tessere-IOS` (TestFlight, backup
iCloud: procedure riusabili descritte nel suo CLAUDE.md), `Garoth93/ritorni-IOS`,
`Garoth93/diario-sonoro-IOS`, `Garoth93/memory-analyzer-IOS`.

## Vincoli fissi

- Nativo vero: Swift/SwiftUI. Niente WebView, niente cross-platform.
- Nessun `.xcodeproj` committato: generato in CI da `apps/<app>/project.yml`
  con XcodeGen.
- Mai committare segreti (client id/secret Strava, token), certificati,
  profili, Team ID. Le credenziali Strava arrivano dai repository secrets
  `STRAVA_CLIENT_ID` / `STRAVA_CLIENT_SECRET` (passati a `xcodebuild` come
  build setting → `Info.plist`) oppure dall'app (Keychain).
- **Privacy**: mai committare dati personali (export Strava, GPX/FIT, CSV,
  backup, coordinate o nomi di luoghi dell'utente). I test usano solo dati
  sintetici (`Synthetic.swift`, coordinate inventate intorno a 10°N 20°E).
- Testi dell'app neutri, come un'app pubblica: nessun riferimento a "uso
  personale" o a dati dell'utente.
- Offline-first: dati in `Application Support` (`cresta-data.json`, tracce in
  `tracks/`, foto in `photos/`). iCloud solo come **backup in iCloud Drive**
  (niente CloudKit), vedi sotto. Rete solo per: Open-Meteo, bollettini
  valanghe (EAWS CAAML + pagina di ripiego), Overpass (download vette),
  Strava.
- Firma solo in `testflight.yml` (automatica, chiave API App Store Connect).
  Mai certificati, profili o `.p8` nella repo; Team ID solo nei secrets.
  `build-ipa.yml` compila senza firma (`CODE_SIGNING_ALLOWED=NO`).
- Non modificare impostazioni della repo o secrets: spiegare all'utente cosa
  configurare.

## Struttura

| App    | Package logica | Bundle ID              | Deployment target |
|--------|----------------|------------------------|-------------------|
| Cresta | CrestaCore     | `com.garoth93.cresta` (+ `.widgets`) | iOS 26.0 |

App Group `group.com.garoth93.cresta` (app + widget), container iCloud
`iCloud.com.garoth93.backup` (solo app). Entrambi creati e spuntati a mano su
developer.apple.com sugli App ID `com.garoth93.cresta` e
`com.garoth93.cresta.widgets` (l'API App Store Connect non può assegnarli).

Package `CrestaCore` (Foundation only, testato su Linux):

- `Track`, `TrackStats` (dislivello con isteresi 3 m, velocità max con mediana
  a 5 contro i picchi GPS, risalite/discese con `ClimbSegmenter`),
  semplificazione Douglas–Peucker.
- Parser: `TrackFileParser` (GPX/TCX con `XMLParser`, `FITParser` binario),
  `Inflate` (deflate/gzip in Swift puro; su Apple usa Compression),
  `ZipArchive` (ZIP64, letto a pezzi), `CSV`/`StravaCSV`.
- `StravaExportReader` → `ExportPreview` (doppioni, conteggi per sport);
  `OutingBuilder` è il punto unico che crea le uscite (export, file, API e,
  in futuro, `TrackRecorder`).
- `ModeClassifier` (tipo di uscita da velocità/dislivello/stagione),
  `SummitMatcher` + `PeakIndex` (griglia 0,05°, indice per id), `PeakFile`
  (TSV OSM) con `PeakKind` (`peak`, `pass`, `skiArea`): vette e passi nello
  stesso indice e nello stesso album (timbri con `placeKind`), comprensori in
  un indice a parte usato da `SkiAreaNamer` (nome del comprensorio delle
  giornate di sci, `Outing.area`).
- `MountainFilter` / `AppData.mountainOutings`: montagna vs allenamento
  (`Settings.mountainOnly`, `mountainMinAscent`), usato da Oggi, Statistiche,
  riepilogo; il Diario mostra tutto.
- `SkiDay` (discese, impianti, tempo sugli sci, stile Slopes),
  `LastLight.history` (tempi reali dalle salite passate con traccia).
- Garage: `MaintenanceTask.unit` giorni (sci) o km (scarpe, bici),
  `GarageLogic.gearFromSources` (attrezzatura dall'export Strava,
  `Outing.sourceGear`).
- Nei dati della sorgente (CSV/API) vincono distanza, dislivello, tempo e
  velocità max del dispositivo; la velocità dalla traccia si calcola solo dalle
  posizioni (il campo velocità dei FIT non è affidabile).
- `Sun` (NOAA, offline), `LastLight` (ora limite), `GoNoGo` (punteggio con
  pesi e veto), `AvalancheBulletin` (CAAML v6 + HTML), `OpenMeteo`.
- `Backpack`, `GarageLogic`, `Season` (inverno 15/11–30/4), `StatsBuilder`,
  `Wrapped`.
- Strava API: `StravaConfig`, `StravaTokens`, `RateLimitState` (finestre
  15 min / giorno UTC, header `X-ReadRateLimit-*`), `StravaClient` (actor),
  `StravaSync` (stato persistente con coda `pending`: riprende dove si era
  fermata). Rete dietro `HTTPTransport` (fake nei test).

Widget (`apps/Cresta/Widgets`, estensione `CrestaWidgets`): Go/No-Go della
meta mostrata in Oggi (small, medium, schermata di blocco). L'app scrive
`GoWidgetSnapshot` (meta, previsioni e bollettino in cache, fattori attivi)
nel file `go-widget.json` dell'App Group (`Shared/SharedStore.swift`, gruppo
reale letto da `embedded.mobileprovision` con `ProvisioningProfile`); il
widget ricalcola il punteggio (`GoDayWindow`: oggi 8–16, domani dopo le 15)
e aggiorna da solo previsioni e bollettino se hanno più di 3 ore. Tocco →
`cresta://go` (apre Go/No-Go). `Shared/` (tema e store) è compilato in
entrambi i target.

App (`apps/Cresta/Sources`): `AppModel` (`@Observable @MainActor`, salvataggio
differito con `DataWriter`), `Services.swift` (file, Keychain, rete,
notifiche), una vista per modulo. Tab: Oggi, Diario, Cime, Strumenti,
Impostazioni. Tema Material 3 da seme (`Palette.winterSeed`/`summerSeed` o
scelto dall'utente).

### Backup iCloud Drive

Stessa procedura di `Garoth93/tessere-IOS`: container **condiviso**
`iCloud.com.garoth93.backup`, sottocartella `Cresta` (in File: *iCloud Drive ›
Backup › Cresta*).

- `Cresta.entitlements` (App Group + container + `CloudDocuments`), usato da
  `testflight.yml`; `Cresta.sideload.entitlements` solo App Group, senza
  iCloud, preferito da `build-ipa.yml` (l'account gratuito non ha iCloud);
  `Widgets.entitlements` solo App Group (mai iCloud nel widget). `project.yml`:
  `SystemCapabilities` `com.apple.iCloud`, `NSUbiquitousContainers` con
  `NSUbiquitousContainerName: Backup`.
- Sull'App ID `com.garoth93.cresta` (developer.apple.com) va spuntato a mano
  il container in iCloud › *Configure*.
- File: `Cresta-backup-yyyy-MM-dd.json` (uno al giorno, ultimi 30) +
  `Cresta-backup-latest.json`, `BackupFile` JSON con `version`; tracce in
  `tracks/<uuid>.json` e foto in `photos/` caricate una volta sola (non
  cambiano). Logica pura in `CloudBackup.swift` (package), I/O in
  `CloudBackupService.swift` (`NSFileCoordinator`, container risolto fuori dal
  main thread, segnaposto `.<nome>.icloud`).
- **Mai nel backup**: token Strava, client id/secret (restano nel Keychain);
  lo stato della coda di sincronizzazione viene azzerato.
- Quando: dopo le modifiche (8 s), all'uscita in background, nel
  `BGAppRefreshTask` (`com.garoth93.cresta.sync`, insieme a Strava). Un'app
  vuota non sovrascrive mai i backup.
- Ripristino: Impostazioni › Ripristina da iCloud (sostituisce i dati, con
  conferma) e guidato al primo avvio se l'app è vuota (chiesto una volta).

## Convenzioni di codice

- Swift 5 language mode (`SWIFT_VERSION: 5.0`), tools-version 5.9 nel package.
- Logica testabile nel package con test; nell'app solo UI e glue.
- Stringhe UI in italiano. Target iOS 26.0: API SwiftUI di iOS 26 senza `#available`.
- Nessuna dipendenza esterna.
- Commit piccoli e descrittivi; niente identificatori di modello AI nei commit.

## Xcode e runner

- Runner `macos-26`, Xcode `26.6` (`XCODE_VERSION` in ogni workflow).
- Test Linux: Docker `swift:6.0-noble`.

## CI

| Workflow | Trigger | Cosa fa |
|----------|---------|---------|
| `build-simulator.yml` | push, PR, manuale | build per Simulator, mostra gli errori di compilazione |
| `build-ipa.yml` | push su `main`/`claude/**`, manuale | scarica vette, passi e comprensori OSM (`scripts/fetch_peaks.py`, cache mensile per tipo), build Release senza firma, `.ipa` come artifact (30 giorni) |
| `test-linux.yml` | push, PR, manuale | `swift test` dei package |
| `testflight.yml` | manuale, push su `main`/`claude/**` (solo `apps/`, `packages/`), ogni ~60 giorni (1° dei mesi dispari, sul branch di default) | archive firmato + export App Store + upload su TestFlight |

### TestFlight

Procedura identica a `Garoth93/tessere-IOS` (vedi il suo CLAUDE.md):

- secrets della repo: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (chiave API
  App Store Connect, ruolo Admin), `APPLE_TEAM_ID`; facoltativi
  `STRAVA_CLIENT_ID` / `STRAVA_CLIENT_SECRET`;
- App ID `com.garoth93.cresta` e scheda App Store Connect creati a mano; i
  profili li crea `xcodebuild -allowProvisioningUpdates`. App Group e
  container iCloud vanno spuntati a mano sull'App ID (l'API non può);
- `project.yml` con firma vuota (la imposta il workflow da riga di comando),
  `SystemCapabilities` sul target, `UIRequiresFullScreen: true` (solo
  verticale, errore 90474), icona 1024 senza trasparenza;
- build number = `github.run_number`; `MARKETING_VERSION` si alza a mano;
- step "App ID capabilities" (`scripts/asc_bundle_ids.py --delete-stale
  --group group.com.garoth93.cresta`) stampa capability e profili di app e
  widget ed elimina i profili senza l'App Group (Xcode li ricrea); il certificato di sviluppo creato sul runner viene revocato
  (`scripts/asc_revoke_certs.py`). Log nell'artifact `testflight-logs`;
- le build TestFlight scadono dopo 90 giorni: la schedulazione le rinnova;
- gli archivi OSM (vette, passi, comprensori) vengono presi dalla cache di
  `build-ipa.yml`.

## Regole di lavoro (per Claude)

1. Dopo ogni push controllare la CI e correggere fino a build verde; riportare
   l'esito reale con il link al run.
2. Non si vede l'interfaccia: nelle scelte grafiche ambigue usare il
   comportamento standard e dire cosa verificare sul telefono.
3. Test in locale: `docker run --rm -v "$PWD":/src -w /src swift:6.0-noble swift test --package-path packages/CrestaCore`
