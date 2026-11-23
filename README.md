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
- **Montagna e allenamento**: Oggi, Statistiche e riepilogo contano solo le
  uscite in montagna (neve, escursioni, trail, ferrate; corse, bici e
  camminate solo con dislivello vero, sopra i 1200 m o su una cima/passo).
  Il Diario le mostra tutte, con il filtro "Solo montagna".
- **Giornate di sci** come Slopes: ogni discesa (dislivello, distanza, velocità
  massima), tempo sugli sci, sugli impianti e in pausa; sulla mappa piste e
  impianti con colori diversi; il **comprensorio** viene riconosciuto da
  OpenStreetMap.
- **Statistiche** di stagione (giorni, metri, record, giorni per mese, per
  attività, per comprensorio), **mappa di calore** di tutte le tracce e
  **riepilogo dell'anno** a schede animate, condivisibile come immagine
  (singola scheda o poster riassuntivo).
- **Cime e passi** — album delle vette e dei passi (OpenStreetMap, offline). Ogni cima raggiunta
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
  Se sei già salito su quella vetta con una traccia usa i tuoi tempi reali,
  altrimenti il passo imparato dalle uscite passate.
- **Go/No-Go** — punteggio 0–10 da bollettino valanghe (EAWS CAAML; ripiego
  sulla lettura della pagina web), meteo e vento (Open-Meteo), zero termico,
  webcam (valutazione a vista), giorni dall'ultima nevicata, neve al suolo
  e neve fresca degli ultimi 3 giorni. Ogni fattore si
  attiva/disattiva; i dati scaricati restano disponibili offline.
- **Zaino** — checklist con modelli (scialpinismo, sci in pista, ciaspole,
  escursione, ferrata, corsa lunga) duplicabili e modificabili; le spunte si
  azzerano a ogni nuova uscita.
- **Garage** — sci, scarponi, pelli (giorni d'uso dall'ultima affilatura,
  sciolinatura o manutenzione), scarpe e bici (km dall'ultimo cambio, catena,
  tagliando), con avvisi. L'attrezzatura indicata su Strava viene aggiunta da
  sola.

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
   dati restano. Con Sideloadly il backup iCloud non è disponibile: prima di
   reinstallare da zero usa Impostazioni › Esporta backup.

## Backup

Con TestFlight Cresta salva da sola un backup in **iCloud Drive › Backup ›
Cresta** (visibile nell'app File): un file al giorno (ultimi 30), con tracce e
foto, quando i dati cambiano e in background. Le credenziali Strava non
vengono mai salvate. Su un iPhone nuovo, se l'app è vuota, propone da sola il
ripristino; altrimenti Impostazioni › Ripristina da iCloud.

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

## Vette, passi e comprensori offline

Il workflow `build-ipa` scarica a ogni mese da OpenStreetMap (API Overpass,
`scripts/fetch_peaks.py`) le vette (`natural=peak`), i passi
(`mountain_pass=yes`) e i comprensori sciistici (`landuse=winter_sports`) con
nome di Alpi e Appennini e li include nel pacchetto (`peaks.tsv`,
`passes.tsv`, `skiareas.tsv`). Se il
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

## Sincronizzazione Strava

In Impostazioni › Sport da sincronizzare scegli quali attività scaricare
(es. "Solo montagna e neve" per lasciare fuori corse e bici in piano).
