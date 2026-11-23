# Cresta — montagna e sci (iOS)

App iOS nativa (Swift + SwiftUI, grafica Material 3 Expressive) per le giornate
in montagna, d'inverno e d'estate: diario delle uscite, album delle cime,
statistiche di stagione e strumenti per decidere e prepararsi. Offline-first:
i dati restano sul telefono, nessun server e nessun account.

Sviluppata senza Mac: compilata da GitHub Actions e distribuita con
**TestFlight**; il `.ipa` per Sideloadly resta come ripiego.

[![build-ipa](https://github.com/Garoth93/montagna-360/actions/workflows/build-ipa.yml/badge.svg)](https://github.com/Garoth93/montagna-360/actions/workflows/build-ipa.yml)
[![test-linux](https://github.com/Garoth93/montagna-360/actions/workflows/test-linux.yml/badge.svg)](https://github.com/Garoth93/montagna-360/actions/workflows/test-linux.yml)

## Moduli

- **Oggi** — cruscotto. Interruttore **Inverno / Non inverno** (automatico per
  data: inverno dal 15 novembre al 30 aprile; cambiabile a mano) che decide
  cosa viene prima: d'inverno Go/No-Go, stagione sulla neve, garage; d'estate
  cime, Ultima Luce, dislivello. Anche i colori seguono la stagione.
- **Diario** — una scheda per uscita: traccia su mappa, profilo altimetrico,
  distanza, dislivello ±, tempo in movimento e totale, velocità massima, quota
  massima, discese (sci in pista), meteo, note, foto, attrezzatura usata,
  esportazione GPX. Filtri per stagione e attività, ricerca, uscite a mano.
- **Statistiche** di stagione (giorni, metri, record, giorni per mese, per
  attività) e **riepilogo dell'anno** a schede animate.
- **Cime** — album delle vette (OpenStreetMap, offline). Ogni cima raggiunta
  ha il suo timbro con data, quota, meteo e modalità (a piedi / sci / ciaspole /
  bici): proposta da traccia e velocità, correggibile a mano. Le tracce
  importate vengono abbinate da sole alle vette vicine. Mappa di tutte le
  vette con download di nuove zone per l'uso offline.
- **Import** — archivio Strava (ZIP «Scarica i tuoi dati»: `activities.csv` +
  GPX/FIT/TCX anche `.gz`) con anteprima, filtro per sport, rilevamento
  doppioni e barra di avanzamento; file singoli GPX/FIT/TCX; poi
  **sincronizzazione Strava** incrementale (OAuth, refresh token) che rispetta
  i limiti di richieste e riprende da sola.
- **Ultima Luce** — da vetta e ora di partenza: tramonto, buio (fine del
  crepuscolo civile), ora limite per scendere, rientro previsto, con notifica.
  Il passo può essere imparato dalle uscite passate.
- **Go/No-Go** — punteggio 0–10 da bollettino valanghe (EAWS CAAML; ripiego
  sulla lettura della pagina web), meteo e vento (Open-Meteo), zero termico,
  webcam (valutazione a vista), giorni dall'ultima nevicata. Ogni fattore si
  attiva/disattiva; i dati scaricati restano disponibili offline.
- **Zaino** — checklist con modelli (scialpinismo, sci in pista, ciaspole,
  escursione, ferrata, corsa lunga) duplicabili e modificabili; le spunte si
  azzerano a ogni nuova uscita.
- **Sci Garage** — sci, scarponi, pelli: giorni d'uso dall'ultima affilatura,
  sciolinatura o manutenzione, con avvisi.

## Installare l'app sull'iPhone

**TestFlight (consigliato)**: il workflow `testflight` firma e carica l'app a
ogni modifica (e da solo ogni ~60 giorni, prima che la build scada dopo 90).
Sull'iPhone basta l'app TestFlight.

**Ripiego Sideloadly (da Windows)**:

1. Pagina **Actions** della repo › workflow **build-ipa** › ultimo run verde
   (o **Run workflow**) › artifact `Cresta-unsigned-ipa`: estrai
   `Cresta-unsigned.ipa` (resta disponibile 30 giorni).
2. **Sideloadly**: collega l'iPhone, trascina il `.ipa`, inserisci l'Apple ID,
   **Start**. Sull'iPhone: Impostazioni › Generali › VPN e gestione
   dispositivo › Autorizza (serve la Modalità sviluppatore attiva).
3. Con l'account gratuito la firma dura 7 giorni: rifirma lo stesso `.ipa`, i
   dati restano. Prima di reinstallare da zero fai un backup (Impostazioni ›
   Esporta backup).

## Collegare Strava

1. Su <https://www.strava.com/settings/api> crea un'applicazione con
   **Authorization Callback Domain** = `localhost`.
2. Due modi per dare all'app Client ID e Client Secret (mai nel codice):
   - **nella configurazione di build**: nella repo, Settings › Secrets and
     variables › Actions › *New repository secret* `STRAVA_CLIENT_ID` e
     `STRAVA_CLIENT_SECRET`; il workflow `build-ipa` li inserisce
     nell'`Info.plist` del pacchetto;
   - **nell'app**: Strumenti › Importa › Credenziali API Strava (salvate nel
     portachiavi; hanno la precedenza).
3. Strumenti › Importa › **Collega Strava**. Dopo l'import dell'archivio la
   sincronizzazione parte dall'ultima attività già presente.

## Vette offline

Il workflow `build-ipa` scarica a ogni mese le vette con nome
(`natural=peak`) di Alpi e Appennini dall'API Overpass di OpenStreetMap
(`scripts/fetch_peaks.py`) e le include nel pacchetto (`peaks.tsv`). Se il
download non riesce l'app funziona lo stesso e le zone si scaricano dalla
mappa delle Cime. Dati © OpenStreetMap contributors, licenza ODbL.

## Struttura

```
apps/Cresta/              app SwiftUI (project.yml per XcodeGen)
  Sources/                schermate, modello, servizi (rete, file, notifiche, portachiavi)
  Resources/              icona, colori; peaks.tsv aggiunto in CI
packages/CrestaCore/      logica non grafica, testata con `swift test` anche su Linux
scripts/fetch_peaks.py    download delle vette OSM (CI)
.github/workflows/        build-simulator, build-ipa, test-linux
CLAUDE.md                 convenzioni e regole di lavoro per Claude Code
```

## Seconda fase: registrazione GPS

L'architettura è pronta: tutte le fonti (archivio, file, Strava) producono un
`Track` e passano da `OutingBuilder`. La registrazione dal telefono
implementerà il protocollo `TrackRecorder` (`CrestaCore/Recording.swift`, con
`LiveStats` per i numeri in diretta) e salverà l'uscita con lo stesso percorso.
