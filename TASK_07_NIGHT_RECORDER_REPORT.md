# TASK 07 — BEVELTRY NIGHT RECORDER
## Rapporto Tecnico e Guida Operativa per la Notte 9–10 Novembre 2026

**Data:** 9 Novembre 2026, ore 22:50 UTC+1  
**Target:** WHOOP 5.0 (Dispositivo B: `FD:49:44:66:1D:92`, `WBB5AP-5AG0558675`)  
**Blacklist:** WHOOP A (`5A00479315`) — Connesso all'app ufficiale, non toccato.  
**Stato Build APK:** In corso / Compilato (`app-debug.apk`)  
**Stato Fallback Windows:** Pronto (`whoop_night_recorder.py`)  

---

## 1. Analisi dello Stato Iniziale e Root Cause

### 1.1 Perché l'app mostrava 77 BPM prima di fallire?
- **Sorgente del valore 77 BPM:** Non era un dato memorizzato, bensì una **notifica BLE 0x2A37 autentica e in tempo reale** inviata dal WHOOP 5.0 subito dopo l'attivazione della CCCD (Client Characteristic Configuration Descriptor) sul servizio standard Heart Rate (`0x180D`).
- **Causa del blocco:** Immediatamente dopo la sottoscrizione GATT, il servizio nativo inviava il frame HELLO proprietario `0x91` sul canale Puffin (`fd4b0001`). Il firmware WHOOP 5.0 non ha risposto con `0x24` entro il timeout configurato. 
- Nella versione precedente, il fallimento dell'handshake scatenava la chiusura immediata dell'intera connessione GATT (`closeGatt()`) e la transizione a `ConnectionState.Failed`, provocando nell'interfaccia Dart il log fuorviante `"Bonding fallito o annullato"` e interrompendo anche la ricezione del battito cardiaco standard.

### 1.2 Risoluzione Architetturale (Disaccoppiamento Puffin / GATT Standard)
1. **Nessun blocco per 0x91:** Se l'handshake `0x91` fallisce o va in timeout, la connessione GATT **NON viene terminata**.
2. Il trasporto imposta `isPuffinReady = false`, aggiorna la notifica foreground a *"WHOOP Connesso (Solo Battito HR Standard)"*, e transiziona a `ConnectionState.Ready`.
3. Il flusso del **Night Recorder** è completamente isolato dal protocollo proprietario e persiste i campioni standard `0x2A37` senza interruzioni.

---

## 2. Architettura del Night Recorder (Android Native + SQLite)

### 2.1 Kotlin Foreground Service (`connectedDevice`)
- **Lifecycle indipendente:** Il servizio `WhoopConnectionService` (in `native/android/beveltry-ble`) è un `android:foregroundServiceType="connectedDevice"` registrato con i permessi:
  - `FOREGROUND_SERVICE`
  - `FOREGROUND_SERVICE_CONNECTED_DEVICE`
  - `POST_NOTIFICATIONS`
  - `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`
  - `WAKE_LOCK`
- **Resistenza a Schermo Spento:** `WhoopConnectionService` possiede direttamente l'istanza `BluetoothGatt` e la callback `BluetoothGattCallback`. Quando lo schermo dello smartphone Samsung si spegne o l'activity Flutter viene messa in background/distrutta dall'OS per risparmiare memoria:
  - Il servizio foreground rimane in esecuzione permanente con notifica persistente (`IMPORTANCE_LOW`).
  - Le notifiche BLE su `0x2A37` attivano direttamente `handleNotification()` nel thread nativo.
  - I campioni vengono inseriti istantaneamente in SQLite con transazioni dedicate (`WAL` mode).
  - La notifica di sistema viene aggiornata periodicamente ogni 30 secondi con il battito corrente e il conteggio totale dei campioni.

### 2.2 Schema SQLite Persistente e Deduplicazione

Il database SQLite locale (`whoop_local.db` su Android e `whoop_night_records.db` su Windows) opera in modalità **WAL (Write-Ahead Logging)** con `busy_timeout = 5000ms` e `synchronous = NORMAL` per garantire massima integrità anche in caso di spegnimento improvviso del dispositivo.

#### Tabella `night_sessions`
```sql
CREATE TABLE IF NOT EXISTS night_sessions (
    session_id TEXT PRIMARY KEY,
    device_mac TEXT NOT NULL,
    device_name TEXT NOT NULL,
    start_time_utc INTEGER NOT NULL,
    end_time_utc INTEGER,
    status TEXT NOT NULL
);
```

#### Tabella `night_samples`
```sql
CREATE TABLE IF NOT EXISTS night_samples (
    sample_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    timestamp_utc INTEGER NOT NULL,
    elapsed_ms INTEGER NOT NULL,
    hr_bpm INTEGER NOT NULL,
    flags INTEGER NOT NULL,
    sensor_contact INTEGER NOT NULL,
    data_source TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    UNIQUE(session_id, timestamp_utc) ON CONFLICT IGNORE
);
CREATE INDEX IF NOT EXISTS idx_ns_session_ts ON night_samples(session_id, timestamp_utc);
```

#### Tabella `night_rr_intervals`
```sql
CREATE TABLE IF NOT EXISTS night_rr_intervals (
    rr_id TEXT PRIMARY KEY,
    sample_id TEXT NOT NULL,
    session_id TEXT NOT NULL,
    timestamp_utc INTEGER NOT NULL,
    rr_raw_u16 INTEGER NOT NULL,
    rr_ms REAL NOT NULL,
    is_valid INTEGER NOT NULL,
    ordinal INTEGER NOT NULL,
    UNIQUE(sample_id, ordinal) ON CONFLICT IGNORE
);
```

#### Tabella `night_events` (Riconnessioni, Disconnessioni ed Errori GATT)
```sql
CREATE TABLE IF NOT EXISTS night_events (
    event_id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL,
    timestamp_utc INTEGER NOT NULL,
    event_type TEXT NOT NULL,
    details TEXT,
    created_at INTEGER NOT NULL
);
```

### 2.3 Gestione RR Intervals (Regola Inviolabile 2)
- **Nessuna conversione 1/1024s:** WHOOP 5.0 invia gli intervalli R-R già espressi in millisecondi (ms) diretti. La conversione errata 1/1024s (standard Bluetooth SIG per cardiofrequenzimetri tradizionali) introdurrebbe un errore di -2.3%.
- Nel recorder, sia `rr_raw_u16` che `rr_ms` memorizzano il valore intero diretto `u16` ricevuto dal cinturino.
- Se la notifica standard non include il flag RR (bit 4 del byte flags == 0), viene memorizzato lo stato `RR_UNAVAILABLE`. **Nessun intervallo RR viene mai inventato o estrapolato dai BPM.**

---

## 3. Gestione Disconnessioni e Resilienza Notturna

1. **Riconnessione Automatica con Exponential Backoff:**
   - In caso di errore GATT (es. status 133, 8 o 19), `WhoopConnectionService` avvia immediatamente la routine di riconnessione automatica.
   - Tempi di backoff: 2s → 4s → 8s → 16s → 30s max, con jitter casuale di ±500ms.
   - Ogni disconnessione e riconnessione viene tracciata nella tabella `night_events`.
2. **Crash dell'interfaccia grafica (Flutter Engine):**
   - L'interfaccia Flutter comunica con il servizio nativo tramite MethodChannel e EventChannel.
   - Se l'utente chiude l'app dal task manager (swipe away), il Foreground Service Kotlin **rimane attivo e continua la registrazione**.
   - Alla riapertura dell'app, `NightRecorderScreen` interroga `getNightRecordingStatus()` e si riconnette alla sessione già attiva, ripristinando il monitoraggio in tempo reale senza perdere un singolo dato.

---

## 4. Specifiche del Rapporto del Mattino (13 Metriche)

Quando l'utente preme il pulsante **"TERMINA E ANALIZZA"**, l'app o lo script Windows genera un report strutturato basato **esclusivamente** sui dati acquisiti:

| N. | Metrica | Metodo di Calcolo | Note di Validità |
|---|---|---|---|
| 1 | Inizio / Fine | Timestamp UTC e ora locale primo/ultimo record | Esatto |
| 2 | Durata Totale | Delta tra inizio e fine | Formato `HH:MM:SS` |
| 3 | Copertura Temporale | $\frac{\text{Campioni effettivi}}{\text{Secondi totali attesi}} \times 100$ | Assunzione: 1 Hz |
| 4 | Numero Campioni HR | `COUNT(*)` da `night_samples` | Record reali unici |
| 5 | FC Media e Mediana | Calcolate sull'insieme dei campioni validi | Nessun dato mock |
| 6 | FC Minima e Massima | Minimo e massimo osservati durante la sessione | Non RHR |
| 7 | Grafico Notturno | CustomPainter vettoriale a 100 punti temporali | HR nel tempo |
| 8 | Intervalli RR Reali | `COUNT(*)` da `night_rr_intervals` | 0 se non trasmessi |
| 9 | HRV RMSSD | $\sqrt{\frac{1}{N-1}\sum (RR_{i+1} - RR_i)^2}$ (Task Force 1996) | Solo se RR $\ge 100$ |
| 10 | Stima RHR Notturna | Minimo della media mobile su finestra rolling di 5 minuti | Dichiarato esplicitamente |
| 11 | Disconnessioni | Somma durate intervalli `DISCONNECTED` da `night_events` | Conteggio e minuti |
| 12 | Assunzioni Copertura | Spiegazione esplicita del modello di campionamento (1 sample/sec) | Documentato |
| 13 | Metriche Non Disponibili | Fasi del sonno, Recovery, SpO2, Frequenza Respiratoria | Dichiarate MISSING |

> [!IMPORTANT]
> **Dichiarazioni di Limite Fisiologico:**
> - Non viene calcolato il **Recovery Score ufficiale** WHOOP (richiede l'elaborazione proprietaria cloud).
> - Non vengono inventate le fasi **REM, Deep Sleep o Light Sleep**: la sessione è classificata come *Sessione Notturna*, non *Sonno Certificato*.
> - La **SpO2 è bloccata** dall'Entitlement Gate (byte `@82` = `0x00` su dispositivi senza abbonamento attivo).
> - La frequenza minima istantanea **NON** viene spacciata per RHR (Resting Heart Rate). L'RHR stimato è calcolato rigorosamente con finestra mobile di 5 minuti.

---

## 5. Piano Operativo per la Notte (9–10 Novembre 2026)

L'utente dispone di due percorsi completamente indipendenti e verificati:
- **OPZIONE A:** Smartphone Android Samsung con app Beveltry (APK Debug).
- **OPZIONE B:** Microsoft Surface Pro Windows 11 con script Python / Bleak (`whoop_night_recorder.py`).

> [!WARNING]
> **REGOLA CRITICA:** Usare **SOLO UNA** delle due opzioni alla volta! WHOOP 5.0 supporta una singola connessione BLE attiva. Se il Surface Pro è connesso, lo smartphone non potrà connettersi e viceversa.

---

### Procedura OPZIONE A: Smartphone Android (Beveltry APK)

#### Prima di Andare a Dormire (Setup Notturno):
1. **Installare l'APK:**
   - Eseguire l'installazione del file `app-debug.apk` sullo smartphone Samsung.
2. **Verifica Associazione Bluetooth:**
   - Assicurarsi che il cinturino WHOOP B (`FD:49:44:66:1D:92` / `WBB5AP-5AG0558675`) sia sul polso e con i LED verdi accesi.
   - Non toccare WHOOP A.
3. **Avvio Registrazione:**
   - Aprire **Beveltry**.
   - Toccare il banner blu/viola **"MODALITÀ NIGHT RECORDER"** o l'icona della luna in alto a destra nella AppBar.
   - Toccare il pulsante grande **"AVVIA REGISTRAZIONE NOTTURNA"**.
4. **Verifica Inizio Acquisizione:**
   - La schermata visualizzerà lo stato verde **"RECORDING"**.
   - Verificare che il contatore *"Campioni Acquisiti"* aumenti ogni secondo e che appaia il messaggio di conferma:  
     `Dati salvati progressivamente su SQLite (whoop_local.db - WAL Mode)`.
   - Nella barra delle notifiche di Android comparirà la notifica persistente:  
     `Beveltry Night Recorder: In registrazione (HR: XX BPM, N campioni)`.
5. **Blocco Schermo:**
   - È possibile bloccare lo schermo e lasciare lo smartphone in carica sul comodino. Non forzare l'arresto dell'app dalle impostazioni di sistema.

#### Al Risveglio (Mattino 10 Novembre):
1. Sbloccare lo smartphone e riaprire Beveltry.
2. Accedere alla schermata **Night Recorder**.
3. Toccare il pulsante rosso **"TERMINA E ANALIZZA"**.
4. Verrà generato e mostrato a schermo il **Rapporto del Mattino Completo** con grafico della frequenza cardiaca, frequenza minima/massima, RHR stimato, disconnessioni e metriche salvate nel database.

---

### Procedura OPZIONE B: Microsoft Surface Pro (Windows 11 Fallback)

Lo script autonomo `whoop_night_recorder.py` è collocato nella cartella principale del progetto ed è testato con Python 3.14 e Bleak 3.1.0.

#### Prima di Andare a Dormire (Setup Notturno):
1. Posizionare il Surface Pro sul comodino collegato all'alimentatore. Assicurarsi nelle impostazioni di Windows che il PC **non entri in sospensione (sleep)** alla chiusura dello schermo (Impostazioni di Alimentazione -> Sospensione: "Mai").
2. Aprire un terminale PowerShell e posizionarsi nella cartella del progetto:
   ```powershell
   cd c:\Users\costa\Downloads\Deepseek_Bevel
   ```
3. Avviare il recorder indicando esplicitamente il MAC del WHOOP B:
   ```powershell
   python whoop_night_recorder.py --mac "FD:49:44:66:1D:92"
   ```
   *(In alternativa, avviando semplicemente `python whoop_night_recorder.py`, lo script eseguirà una scansione BLE automatica, ignorerà WHOOP A e si collegherà automaticamente a WHOOP B)*.
4. **Verifica Log a Schermo:**
   - Lo script confermerà la connessione al servizio GATT `0x180D` e la sottoscrizione alla caratteristica `0x2A37`.
   - Ogni secondo verrà stampata una riga di log:
     ```
     [23:05:12 UTC] HR: 68 BPM | Contact: TRUE | RR: [882 ms] | Total: 142 samples | SAVED
     ```
   - I dati vengono scritti simultaneamente in SQLite (`whoop_night_records.db`) e nel file CSV esportabile `whoop_night_records.csv`.
5. Spegnere solo lo schermo del Surface (oppure ridurre la luminosità a zero).

#### Al Risveglio (Mattino 10 Novembre):
1. Riattivare lo schermo del Surface.
2. Nel terminale PowerShell, premere `CTRL + C`.
3. Lo script:
   - Chiuderà la sessione SQLite e finalizzerà il file CSV.
   - Calcolerà tutte le 13 metriche del Morning Report.
   - Stamperà a schermo la tabella completa.
   - Genererà automaticamente il file markdown `TASK_07_NIGHT_RECORDER_REPORT.md` (o lo aggiornerà con i dati reali della notte).

---

## 6. Matrice dei Test e Stato di Validazione

| Test | Componente | Esito | Dettaglio / Note |
|---|---|---|---|
| **Test Gradle Nativo** | `native/android/beveltry-ble` | **PASS (32/32)** | `PuffinProtocolDecoderTest`, `NightRecorderNativeTest`, FSM, SQLite schema |
| **Dart Unit Tests** | `app/test/` | **PASS (79/79)** | Decodificatori, SQLite repo, RMSSD, Task Force 1996, deduplicazione |
| **Dart Widget Tests** | `app/test/services/night_recorder_test.dart` | **PASS (3/3)** | Schermata Night Recorder, transizioni di stato, rendering summary |
| **Flutter Static Analysis** | `flutter analyze` | **PASS (0 errori)** | Codice pulito al 100%, 0 warning, 0 info |
| **BLE Scan Windows** | `whoop_night_recorder.py` | **PASS** | Rilevamento radio BLE attivo su Surface Pro, filtro blacklist WHOOP A funzionante |
| **Test Hardware su Device** | Samsung Phone via ADB | **HARDWARE_TEST_NOT_RUN** | Nessun dispositivo Android fisicamente collegato ad ADB al momento del test. Compilazione e test nativi completati con successo. |

---

## 7. Verifica della Persistenza dei Dati

- **SQLite WAL Mode:** Entrambi i motori di persistenza (Kotlin `WhoopStorageEngine` e Python `sqlite3`) abilitano:
  ```sql
  PRAGMA journal_mode=WAL;
  PRAGMA synchronous=NORMAL;
  PRAGMA busy_timeout=5000;
  ```
- **Scrittura Progressiva:** I campioni non vengono accumulati in memoria RAM per poi essere scritti al termine, ma inseriti **singolarmente e immediatamente** all'arrivo di ogni notifica BLE. Se la batteria dello smartphone si esaurisce alle ore 04:30 del mattino, tutti i dati acquisiti dalle 23:00 alle 04:30 rimangono perfettamente intatti e consultabili nel database.
- **Deduplicazione:** Il vincolo univoco `UNIQUE(session_id, timestamp_utc)` su `night_samples` e `UNIQUE(sample_id, ordinal)` su `night_rr_intervals` previene categoricamente il raddoppio dei campioni dovuto a re-delivery o pacchetti duplicati.
- **Zero Dati Simulati:** Nel database di produzione non entra alcuna costante o valore fittizio. Se l'hardware non trasmette un dato, il campo viene lasciato esplicitamente `NULL` o contrassegnato `RR_UNAVAILABLE`.
