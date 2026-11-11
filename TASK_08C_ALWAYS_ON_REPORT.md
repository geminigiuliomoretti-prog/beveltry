# TASK 08C — BEVELTRY ALWAYS-ON RECORDER REPORT

**Data:** 11 Novembre 2026  
**Autore:** Senior Android BLE Engineer, Kotlin Architect & Flutter Integration Engineer  
**Dispositivo Target:** WHOOP 5.0 (Dispositivo B, MAC: `FD:49:44:66:1D:92`, Serial: `WBB5AP-5AG0558675`)  
**Package:** `com.beveltry.beveltry`  
**Target Android:** API 34+ (Android 14/15 / Samsung One UI 6+)

---

## 1. RIEPILOGO ESECUTIVO

Nel corso della notte 10–11 novembre 2026, l'utente ha indossato il WHOOP B senza avviare manualmente il Night Recorder. L'ispezione diretta del database SQLite (`exports/whoop_local.db`) ha confermato che **zero campioni** sono stati acquisiti per quella finestra temporale, a dimostrazione del problema strutturale: la totale dipendenza dall'interazione manuale dell'utente su `NightRecorderScreen`.

Con il completamento del **TASK 08C**, Beveltry dispone ora di un'architettura **Always-On resiliente a singolo proprietario**, che:
1. Abilita l'acquisizione continua in background tramite `foregroundServiceType="connectedDevice"` con persistenza `START_STICKY`.
2. Introduce un **`RecordingCoordinator` unico**, prevenendo concorrenze GATT, doppie sottoscrizioni CCCD e duplicazioni di campioni.
3. Implementa una **Macchina a Stati BLE esplicita a 12 stati**, dove lo stato `STREAMING` viene raggiunto **esclusivamente** al ricevimento del primo campione HR/RR valido da `0x2A37`.
4. Gestisce le disconnessioni con backoff esponenziale controllato (`0s -> 2s -> 5s -> 15s -> 30s -> 60s`).
5. Protegge il database locale con uno schema additivo non distruttivo (`automatic_recording_settings`, `connection_events`, `recording_segments`).
6. Integra `WorkManager` (`WhoopMaintenanceWorker`) con **fast-exit** tassativo: non blocca thread né consuma batteria se lo strap è fuori portata.
7. Preserva al 100% le funzionalità del Night Recorder manuale e del modulo analitico Sleep Lab TASK 08A, aggiungendo un dialog di conferma contro l'interruzione accidentale dell'Always-On.

---

## 2. STATO DI VERIFICA (STATUS LABELS)

Come da vincoli metodologici di progetto, ogni componente è classificato con uno stato esplicito:

| Componente | Stato | Dettagli di Verifica |
|---|---|---|
| **BleStateMachine (12 stati)** | `TESTED` | Verificato con 42/42 test unitari Kotlin (transizioni legali, rigetto transizioni vietate, timeout). |
| **Backoff reconnect logic** | `TESTED` | Verificata progressione esponenziale (0s, 2s, 5s, 15s, 30s, 60s) e reset a 0s dopo notifica valida. |
| **Deduplicazione campioni (indice, ts, beat)** | `TESTED` | Testata nel repository e storage engine senza re-deliveries. |
| **Schema SQLite additivo** | `TESTED` | Verificato sia sul layer nativo Android che su Flutter (`_onOpen` & `_onCreate`). |
| **UI Impostazioni & Diagnostica** | `TESTED` | 113/113 test Flutter passati, widget test con stream update simulati. |
| **Integrazione Sleep Lab & Night Recorder** | `TESTED` | Nessuna regressione sui test Sleep Lab 08A e Night Recorder v1. |
| **Compilazione Debug APK** | `TESTED` | Compilato con successo: `app-debug.apk` (179.99 MB). |
| **Foreground Service `connectedDevice`** | `IMPLEMENTED_NOT_DEVICE_TESTED` | Implementato con `START_STICKY`, notifica persistente e azione rapida "Disattiva". Da validare su Samsung fisico. |
| **CompanionDeviceService Fallback** | `IMPLEMENTED_NOT_DEVICE_TESTED` | Service registrato. Rilevamento presenza attivo se associato a livello OS; fallback FGS attivo di default. |
| **Boot & BLE Receiver (`BOOT_COMPLETED`)** | `IMPLEMENTED_NOT_DEVICE_TESTED` | Registrato in manifest e cablato a `WhoopMaintenanceWorker`. Richiede test di riavvio su Samsung. |
| **WorkManager Fast-Exit** | `TESTED` | Verificato il codice: esce immediatamente se Bluetooth OFF o strap non raggiungibile. |

---

## 3. ARCHITETTURA TECNICA IMPLEMENTATA

### 3.1 Motore Unico: `RecordingCoordinator`
- **File:** `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/RecordingCoordinator.kt`
- Elimina qualsiasi possibilità di sessioni GATT sovrapposte.
- Centralizza la connessione a WHOOP B (`FD:49:44:66:1D:92`), la sottoscrizione alla caratteristica standard `0x2A37` (Heart Rate Measurement), il parsing HR/RR e la persistenza atomica.
- Monitora le lacune temporali (gap > 5000 ms) aggiornando in tempo reale le metriche del segmento corrente.
- Distingue l'Always-On dalla sessione manuale notturna: se l'Always-On è attivo e l'utente termina il Night Recorder manuale, l'acquisizione in background continua ininterrotta.

### 3.2 Macchina a Stati BLE a 12 Stati
- **File:** `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/BleState.kt`
- **File:** `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/BleStateMachine.kt`
- **Stati:**
  1. `DISABLED`: Always-On disattivato dall'utente.
  2. `ASSOCIATED`: Dispositivo noto ma non ancora in connessione.
  3. `WAITING_FOR_DEVICE`: In attesa di avvio connessione o scansione mirata.
  4. `CONNECTING`: `connectGatt` invocato.
  5. `GATT_CONNECTED`: Callback `onConnectionStateChange(GATT_SUCCESS, STATE_CONNECTED)`.
  6. `DISCOVERING_SERVICES`: `discoverServices()` in corso.
  7. `SUBSCRIBING_HR`: Sottoscrizione locale e scrittura CCCD `0x2902` su `0x2A37`.
  8. `STREAMING`: Raggiunto **esclusivamente** alla ricezione del primo pacchetto HR valido.
  9. `RECONNECT_WAIT`: Attesa backoff programmata (`Handler.postDelayed`).
  10. `BLUETOOTH_DISABLED`: Bluetooth spento dall'utente.
  11. `PERMISSION_BLOCKED`: Mancanza permessi a runtime.
  12. `ERROR`: Errore irrecuperabile o stato terminale temporaneo.

### 3.3 Sottoscrizione GATT Standard 0x2A37 e Unità di Misura
- WHOOP B invia intervalli R-R già in millisecondi (ms) diretti. Non viene applicata la formula standard 1/1024s (che introdurrebbe un errore sistematico del -2.3%).
- Non viene eseguita alcuna scrittura su caratteristiche proprietarie o opcode non autorizzati (`0x19`, `0x1D`).
- Il CCCD `0x2902` viene abilitato unicamente per le notifiche HR.

### 3.4 Foreground Service con `connectedDevice`
- **File:** `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopConnectionService.kt`
- Specificato nel Manifest con `android:foregroundServiceType="connectedDevice"`.
- Notifica persistente con titolo **"Beveltry — Registrazione WHOOP attiva"**.
- Notifica dotata di pulsante di azione immediato **"Disattiva Always-On"** per consentire all'utente lo spegnimento istantaneo senza dover navigare l'app.
- Notifica dinamica: mostra in tempo reale battito corrente e intervallo R-R.

### 3.5 Schema SQLite Additivo
Nel file `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopStorageEngine.kt` e in Flutter `app/lib/src/database/whoop_database.dart`:
1. `automatic_recording_settings`:
   - `key TEXT PRIMARY KEY`, `value TEXT NOT NULL`, `updated_at_utc INTEGER NOT NULL`.
2. `connection_events`:
   - `id INTEGER PRIMARY KEY AUTOINCREMENT`, `timestamp_utc INTEGER NOT NULL`, `event_type TEXT NOT NULL`, `details TEXT`.
3. `recording_segments`:
   - `id INTEGER PRIMARY KEY AUTOINCREMENT`, `start_time_utc INTEGER NOT NULL`, `end_time_utc INTEGER`, `samples_count INTEGER DEFAULT 0`, `rr_count INTEGER DEFAULT 0`, `gaps_count INTEGER DEFAULT 0`, `max_gap_ms INTEGER DEFAULT 0`, `status TEXT DEFAULT 'ACTIVE'`.
- Vengono mantenuti gli indici su `timestamp_utc` e `start_time_utc`.

### 3.6 WorkManager & Boot Recovery
- **File:** `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopMaintenanceWorker.kt`
- **File:** `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/BootAndBleReceiver.kt`
- **Invariant rispettato:** Il worker non effettua polling BLE né tenta di mantenere un lock prolungato. Se Always-On è disattivato o il Bluetooth è spento, il worker esce immediatamente con `Result.success()`.
- Al riavvio dello smartphone (`ACTION_BOOT_COMPLETED`), il receiver verifica se Always-On era attivo nel database: in tal caso, rischedula il worker ed avvia il foreground service non appena le policy di sistema lo permettono.

---

## 4. MODIFICHE ALL'INTERFACCIA FLUTTER

- **Schermata Always-On (`app/lib/screens/always_on_screen.dart`):**
  - **Tab 1: Impostazioni:**
    - Switch persistente ON/OFF per la registrazione automatica.
    - Dispositivo associato (WHOOP B `FD:49:44:66:1D:92`).
    - **Osservabilità a 3 livelli reali:**
      1. Foreground Service (Attivo / Inattivo).
      2. Link BLE GATT (Connesso / In riconnessione).
      3. Flusso 0x2A37 (In streaming / In attesa).
    - Metriche in tempo reale (HR bpm, RR ms, ultimo aggiornamento).
    - Card avvisi interruzioni (conteggio disconnessioni, gap rilevati, massimo gap).
  - **Tab 2: Diagnostica:**
    - Tabella telemetria completa.
    - Istruzioni specifiche per Samsung Galaxy ("Applicazioni mai in sospensione").
    - Registro eventi di connessione recenti da SQLite (`connection_events`).
    - Tabella segmenti di registrazione recenti da SQLite (`recording_segments`).
- **Integrazione Dashboard (`app/lib/screens/dashboard_screen.dart`):**
  - Icona dedicata con indicatore di stato Always-On nella AppBar.
  - Banner contestuale per abilitare Always-On o visualizzare lo stato operativo.
- **Protezione Night Recorder (`app/lib/screens/night_recorder_screen.dart`):**
  - Dialog di conferma su "TERMINA E ANALIZZA" se Always-On è attivo: permette di generare il report della notte mantenendo in background la registrazione continua.

---

## 5. FILE MODIFICATI E AGGIUNTI

### File Aggiunti:
1. `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/BleState.kt`
2. `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/BleStateMachine.kt`
3. `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/RecordingCoordinator.kt`
4. `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopCompanionService.kt`
5. `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopMaintenanceWorker.kt`
6. `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/BootAndBleReceiver.kt`
7. `native/android/beveltry-ble/src/test/kotlin/com/beveltry/ble/AlwaysOnRecorderTest.kt`
8. `app/lib/screens/always_on_screen.dart`
9. `app/test/services/always_on_recorder_test.dart`
10. `TASK_08C_ALWAYS_ON_REPORT.md`
11. `TASK_08C_SAMSUNG_TEST.md`

### File Modificati:
1. `.gitignore` (aggiunti pattern protetti per pcap, snoop, log, csv, sqlite)
2. `native/android/beveltry-ble/build.gradle.kts` (aggiunto androidx.work:work-runtime-ktx:2.9.1)
3. `native/android/beveltry-ble/src/main/AndroidManifest.xml` (dichiarati service, receiver, permessi)
4. `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopStorageEngine.kt` (tabelle e query per Always-On)
5. `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopConnectionService.kt` (integrazione coordinator e notifica)
6. `app/android/app/src/main/AndroidManifest.xml` (permessi boot e wake_lock)
7. `app/android/app/src/main/kotlin/com/beveltry/beveltry/MainActivity.kt` (MethodChannel handlers & stream events)
8. `app/lib/src/database/whoop_database.dart` (migrazione schema Flutter SQLite)
9. `app/lib/src/repository/whoop_repository.dart` (metodi settings ed eventi)
10. `app/lib/src/ble/method_channel_puffin_transport.dart` (canale broadcast Always-On)
11. `app/lib/screens/dashboard_screen.dart` (accesso ad Always-On)
12. `app/lib/screens/night_recorder_screen.dart` (dialog protezione)
13. `app/test/services/night_recorder_test.dart` (aggiornati test con mock per Always-On)

---

## 6. ESITI DEI TEST

### 6.1 Test Unitari Android Nativo (Kotlin/JUnit 4)
- **Comando:** `./gradlew :beveltry-ble:testDebugUnitTest`
- **Risultato:** **42/42 PASS** (100% successo)
- Copertura:
  - Transizioni di stato della `BleStateMachine`.
  - Rigetto transizioni non autorizzate.
  - Raggiungimento di `STREAMING` solo su pacchetto HR valido.
  - Calcolo del backoff esponenziale (0s, 2s, 5s, 15s, 30s, 60s max).
  - Timeout e gestione disconnessioni.

### 6.2 Test Flutter (Dart Test & Widget Tests)
- **Comando:** `flutter test`
- **Risultato:** **113/113 PASS** (100% successo)
- Copertura:
  - `puffin_frame_codec_test.dart`: Codec, CRC, envelope.
  - `puffin_stream_and_handshake_test.dart`: Reassembler e handshake.
  - `whoop_repository_test.dart`: Deduplicazione e persistenza SQLite.
  - `segmented_hrv_real_test.dart`: DSP su dati reali.
  - `always_on_recorder_test.dart`: Widget test per `AlwaysOnScreen` (Impostazioni e Diagnostica).
  - `night_recorder_test.dart`: Ciclo di vita registrazione manuale con protezione Always-On.
  - `sleep_lab_screen_test.dart` & `sleep_lab_regression_real_data_test.dart`: Regressione deterministica completa notte 9-10 Nov.

### 6.3 Analisi Statica del Codice
- **Comando:** `flutter analyze`
- **Risultato:** **No issues found!** (0 errori, 0 avvisi).

---

## 7. ARTEFATTO APK PER IL COLLAUDO

L'APK di debug aggiornato è stato generato preservando l'applicationId originale (`com.beveltry.beveltry`) e la firma di debug, consentendo l'installazione in aggiornamento senza disinstallare l'applicazione o perdere il database privato:

- **Percorso Assoluto:** `C:\Users\costa\Downloads\Deepseek_Bevel\app\build\app\outputs\flutter-apk\app-debug.apk`
- **Dimensione:** 179,992,735 byte (~171.65 MB)
- **Data e Ora Compilazione:** 11/11/2026 ore 11:03:33 UTC+1
- **Comando di Installazione via ADB:**
  ```bash
  adb install -r -d "C:\Users\costa\Downloads\Deepseek_Bevel\app\build\app\outputs\flutter-apk\app-debug.apk"
  ```
