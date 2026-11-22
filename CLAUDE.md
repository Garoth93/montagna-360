# CLAUDE.md — regole di lavoro per questa repo

App iOS **nativa (Swift + SwiftUI)** sviluppata senza Mac: il codice viene
scritto su Linux (Claude Code) e compilato **solo** su GitHub Actions con
runner macOS. Non va su App Store: l'utente scarica il `.ipa` non firmato
dagli artifact e lo firma con Sideloadly da Windows.

Stessa impostazione delle repo `Garoth93/ritorni-IOS`,
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
  `tracks/`, foto in `photos/`). Rete solo per: Open-Meteo, bollettini
  valanghe (EAWS CAAML + pagina di ripiego), Overpass (download vette),
  Strava.
- Account Apple gratuito: nessuna firma in CI (`CODE_SIGNING_ALLOWED=NO`).
- Non modificare impostazioni della repo o secrets: spiegare all'utente cosa
  configurare.

## Struttura

| App    | Package logica | Bundle ID              | Deployment target |
|--------|----------------|------------------------|-------------------|
| Cresta | CrestaCore     | `com.garoth93.cresta`  | iOS 26.0 |

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
  `SummitMatcher` + `PeakIndex` (griglia 0,05°), `PeakFile` (TSV OSM).
- `Sun` (NOAA, offline), `LastLight` (ora limite), `GoNoGo` (punteggio con
  pesi e veto), `AvalancheBulletin` (CAAML v6 + HTML), `OpenMeteo`.
- `Backpack`, `GarageLogic`, `Season` (inverno 15/11–30/4), `StatsBuilder`,
  `Wrapped`.
- Strava API: `StravaConfig`, `StravaTokens`, `RateLimitState` (finestre
  15 min / giorno UTC, header `X-ReadRateLimit-*`), `StravaClient` (actor),
  `StravaSync` (stato persistente con coda `pending`: riprende dove si era
  fermata). Rete dietro `HTTPTransport` (fake nei test).

App (`apps/Cresta/Sources`): `AppModel` (`@Observable @MainActor`, salvataggio
differito con `DataWriter`), `Services.swift` (file, Keychain, rete,
notifiche), una vista per modulo. Tab: Oggi, Diario, Cime, Strumenti,
Impostazioni. Tema Material 3 da seme (`Palette.winterSeed`/`summerSeed` o
scelto dall'utente).

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
| `build-ipa.yml` | push su `main`/`claude/**`, manuale | scarica le vette OSM (cache mensile), build Release senza firma, `.ipa` come artifact (30 giorni) |
| `test-linux.yml` | push, PR, manuale | `swift test` dei package |

## Regole di lavoro (per Claude)

1. Dopo ogni push controllare la CI e correggere fino a build verde; riportare
   l'esito reale con il link al run.
2. Non si vede l'interfaccia: nelle scelte grafiche ambigue usare il
   comportamento standard e dire cosa verificare sul telefono.
3. Test in locale: `docker run --rm -v "$PWD":/src -w /src swift:6.0-noble swift test --package-path packages/CrestaCore`
