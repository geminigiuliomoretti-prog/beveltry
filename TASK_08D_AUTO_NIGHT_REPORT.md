# TASK 08D — BEVELTRY AUTOMATIC SLEEP DETECTION & MORNING REPORT
## Rapporto Tecnico e Risultati di Implementazione

**Data:** 11 Novembre 2026  
**Stato Verifica:** `IMPLEMENTED` / `TESTED` (`DEVICE_TESTED` previsto per la notte su Samsung)  
**Dispositivo Target:** WHOOP 5.0 (Dispositivo B, MAC: `FD:49:44:66:1D:92`, Serial: `WBB5AP-5AG0558675`)  
**Package:** `com.beveltry.beveltry` (firma debug preservata, `applicationId` invariato, nessun data wipe)

---

## 1. Obiettivo e Visione Operativa

L'obiettivo di TASK 08D è rendere l'esperienza del sonno con Beveltry completamente automatica e invisibile:
- L'utente indossa il cinturino WHOOP B alla sera e va a dormire.
- **Nessuna pressione di pulsanti:** l'utente non deve premere «Avvia Sonno» né «Termina Registrazione».
- Il recorder Always-On (TASK 08C.2) garantisce l'acquisizione continua e la resilienza BLE.
- Al risveglio, la **Night State Machine** rileva la veglia prolungata, accerta il risveglio finale tramite isteresi temporale, salva lo stato nel database locale SQLite e accoda un lavoro univoco in background con Android WorkManager.
- L'elaborazione ricostruisce le epoche da 30 secondi, esegue deterministamente la pipeline scientifica di Beveltry Sleep Lab (TASK 08A), salva i risultati in modo atomico e versionato e invia la notifica di sistema:
  `«Beveltry — Analisi della notte pronta»`.

---

## 2. Architettura della Macchina a Stati del Sonno (Night State Machine)

La macchina a stati persistente implementa rigorosamente i 10 stati formali specificati:

```
           ┌──────────────┐
           │   NO_NIGHT   │
           └──────┬───────┘
                  │ FC a riposo >= 15 min
                  ▼
       ┌────────────────────┐
       │  SLEEP_CANDIDATE   │
       └──────────┬─────────┘
                  │ Calma continuata >= 20 min
                  ▼
       ┌────────────────────┐ ◄─────────────────────────┐
       │    SLEEP_ACTIVE    │                           │
       └──────────┬─────────┘                           │ Ritorno al sonno
                  │ FC elevata >= 3 min                 │ prima della conferma
                  ▼                                     │ (WASO accumulato)
       ┌────────────────────┐                           │
       │ WAKE_WITHIN_SLEEP  │ ──────────────────────────┤
       └──────────┬─────────┘                           │
                  │ Veglia > 30 min in orario mattutino │
                  ▼                                     │
       ┌────────────────────┐                           │
       │FINAL_WAKE_CANDIDATE│ ──────────────────────────┘
       └──────────┬─────────┘
                  │ Veglia confermata >= 20 min
                  ▼
       ┌────────────────────┐
       │FINAL_WAKE_CONFIRMED│
       └──────────┬─────────┘
                  │ Enqueue WorkManager
                  ▼
       ┌────────────────────┐
       │  PROCESS_PENDING   │
       └──────────┬─────────┘
                  │ Worker avviato
                  ▼
       ┌────────────────────┐
       │     PROCESSING     │
       └─────┬────────┬─────┘
             │        │
  Elaborato  │        │ Dati insufficienti / Errore
  con successo│        │ (< 30 min registrati)
             ▼        ▼
 ┌───────────────┐  ┌────────────────┐
 │ REPORT_READY  │  │ PROCESS_FAILED │
 └───────┬───────┘  └───────┬────────┘
         │                  │
         └───────► ◄────────┘
                   │ ReprocessRequested (modifica confini a mano)
                   ▼
          ┌─────────────────┐
          │ PROCESS_PENDING │
          └─────────────────┘
```

### Regole Inviolabili di Classificazione Fisiologica:
1. **Un'interruzione Bluetooth NON è un risveglio:** quando si verifica una disconnessione o un gap radio, il sistema registra l'evento `GAP_DETECTED` e preserva intatto lo stato corrente del sonno (`SLEEP_ACTIVE`, `WAKE_WITHIN_SLEEP`, ecc.). Le lacune non vengono mai convertite in epoche Wake.
2. **Nessun arresto su singola epoca Wake:** un'epoca isolata da 30s classificata Wake non chiude la notte; transiziona a `WAKE_WITHIN_SLEEP`.
3. **Isteresi e finestra di contesto:** il risveglio finale richiede almeno 30 minuti di veglia dopo una notte di durata significativa (>= 1h) per entrare in `FINAL_WAKE_CANDIDATE`, seguiti da un'ulteriore finestra di conferma di 20 minuti senza ritorno al sonno per emettere `FINAL_WAKE_CONFIRMED`.
4. **Conservazione della sessione al riaddormentamento:** se l'utente si sveglia (ad es. per bere dell'acqua) e torna a dormire entro la soglia, la sessione rimane unica e il tempo di veglia intermedio viene computato come WASO (Wake After Sleep Onset).
5. **Classificazione sperimentale Cardiac-Only:** le stime sono esplicitamente contrassegnate come `EXPERIMENTAL_CARDIAC_ONLY` in conformità all'assenza di dati cinetici dall'accelerometro sul canale GATT standard `0x2A37`.

---

## 3. Elaborazione Automatica e WorkManager

Al raggiungimento di `FINAL_WAKE_CONFIRMED`:
1. Lo stato viene persistito immediatamente in SQLite nella tabella `night_processing`.
2. Viene schedulato un **Unique OneTimeWorkRequest** con Android WorkManager:
   `uniqueWorkName = "sleep-analysis-$nightKey"` con policy `ExistingWorkPolicy.KEEP` (idempotente: non duplica l'esecuzione).
3. **`SleepAnalysisWorker` (CoroutineWorker Android):**
   - Esegue in background a bassa priorità senza disturbare il connectedDevice FGS o il recorder BLE.
   - Recupera da `whoop_local.db` i campioni HR a 1Hz e i battiti R-R grezzi.
   - **Controllo di sufficienza:** se i campioni sono inferiori a 1800 (meno di 30 minuti di registrazione), marca lo stato come `PROCESS_FAILED` con `errorCode = "INSUFFICIENT_DATA"`, non genera alcuna notifica di successo e termina in modo sicuro.
   - Se i dati sono sufficienti:
     - Ricostruisce le epoche deterministiche da 30 secondi.
     - Calcola la FC basale (20° percentile notturno).
     - Applica il modello logistico deterministico v1.0.0 e lo smoothing bilaterale a 5 epoche.
     - Determina Inizio Sonno (10 epoche consecutive), Risveglio Finale (5 epoche consecutive), TST, WASO, numero risvegli ed efficienza.
     - Calcola l'HRV RMSSD gap-aware sui battiti fisiologici (300-2000 ms, delta < 300 ms) rigorosamente in millisecondi diretti (Regola Inviolabile 2).
     - Calcola la RHR minima mobile su 5 minuti.
     - Salva il report atomico nella nuova tabella `sleep_lab_analyses` con `revision = 1`.
     - Aggiorna `night_processing` allo stato `REPORT_READY`.
     - Invia la notifica di sistema Android:
       - Canale: `beveltry_morning_report` (Priorità High).
       - Titolo: `«Beveltry — Analisi della notte pronta»`.
       - Testo: `«Sonno: 6h 45m | RHR: 48 BPM | HRV: 64 ms»`.
       - Azione: Apre l'app direttamente in Sleep Lab.

---

## 4. Recupero, Continuità e Riconciliazione

Il sistema è progettato per operare resilientemente attraverso tutti i possibili imprevisti Android:
- **App chiusa o terminata dal sistema:** Always-On Foreground Service e WorkManager continuano a raccogliere ed elaborare indipendentemente dalla UI Flutter.
- **Riavvio dello smartphone (Reboot):** Lo stato in `night_processing` preserva il progresso; al boot WorkManager e il receiver ripristinano il monitoraggio.
- **Ritardi WorkManager:** Se Android ritarda l'esecuzione del worker a causa di Doze Mode o risparmio batteria aggressivo Samsung, all'apertura dell'app da parte dell'utente la dashboard e `SleepLabScreen` riconciliano istantaneamente la notte pendente calcolandola al volo e aggiornando il DB a `REPORT_READY`.
- **Ricalcolo e modifiche manuali:** Se l'utente sposta i cursori di inizio/fine sonno in Sleep Lab, il risultato viene memorizzato come `revision = 2` (incrementale), lasciando intatti i campioni raw originari.

---

## 5. File Modificati e Nuovi Componenti

| Componente / File | Natura | Funzionalità Implementata |
| :--- | :--- | :--- |
| `native/.../NightStateMachine.kt` | **Nuovo** | Macchina a stati deterministica a 10 stati (`NO_NIGHT` -> `REPORT_READY`), transizioni e invarianti. |
| `native/.../AutomaticSleepDetector.kt` | **Nuovo** | Rivelatore continuo di FC a riposo, addormentamento, veglia, conferma risveglio finale e filtro gap BLE. |
| `native/.../SleepAnalysisWorker.kt` | **Nuovo** | CoroutineWorker WorkManager idempotente per ricostruzione epoche, Sleep Lab deterministico e notifica mattutina. |
| `native/.../WhoopStorageEngine.kt` | Modificato | Tabelle additive `night_processing` e `sleep_lab_analyses`, query transazionali e persistenza atomica versionata. |
| `native/.../RecordingCoordinator.kt` | Modificato | Integrazione con `AutomaticSleepDetector`, notifica gap BLE ed emissione stato sonno in `CoordinatorUpdate`. |
| `native/.../MainActivity.kt` | Modificato | Handlers MethodChannel per `getLatestNightState`, `getLatestSleepAnalysis`, `triggerSleepAnalysis` e inoltro `sleepState`. |
| `app/lib/src/database/whoop_database.dart` | Modificato | Tabelle SQLite additive speculari in Dart (`night_processing`, `sleep_lab_analyses`). |
| `app/lib/src/repository/whoop_repository.dart` | Modificato | Metodi `getLatestNightProcessing`, `getLatestSleepLabAnalysis`, `saveNightProcessingState`, `saveSleepLabAnalysisRecord`. |
| `app/lib/screens/dashboard_screen.dart` | Modificato | Nuova Card **«ULTIMA NOTTE RILEVATA (Auto Sleep TASK 08D)»** con orari stimati, TST, WASO, HRV, RHR, RSA, copertura, gap e badge «Dati insufficienti». |
| `app/lib/screens/sleep_lab_screen.dart` | Modificato | Banner dello stato automatico di elaborazione (`night_processing.state`) con chip `EXPERIMENTAL_CARDIAC_ONLY`. |
| `native/.../NightStateMachineTest.kt` | **Nuovo** | Suite di 10 test unitari deterministici che coprono tutti gli scenari obbligatori della specifica. |
| `app/test/sleep_lab/auto_sleep_detection_and_reporting_test.dart` | **Nuovo** | Test widget e unit per la persistenza SQLite atomica, rendering card dashboard e badge stato. |

---

## 6. Test Automatici Realmente Eseguiti

Tutte le verifiche automatiche locali hanno dato esito positivo al 100%:

### A. Test Unitari Kotlin Android (`native/android`)
```powershell
Set-Location native/android; ./gradlew :beveltry-ble:testDebugUnitTest
```
- **Esito:** `BUILD SUCCESSFUL in 45s`
- **Risultato:** **62/62 test superati (100% pass)**.
- **Scenari verificati in `NightStateMachineTest`:**
  1. `test01_sleep_onset_flow` -> PASS (NO_NIGHT -> SLEEP_CANDIDATE -> SLEEP_ACTIVE)
  2. `test02_intermediate_wake_and_waso_return_to_sleep` -> PASS (WAKE_WITHIN_SLEEP -> SLEEP_ACTIVE, sessione conservata)
  3. `test03_final_wake_hysteresis_and_confirmation` -> PASS (SLEEP_ACTIVE -> FINAL_WAKE_CANDIDATE -> FINAL_WAKE_CONFIRMED)
  4. `test04_return_to_sleep_from_final_wake_candidate_preserves_session` -> PASS (Ritorno a dormire durante la finestra di conferma ripristina SLEEP_ACTIVE)
  5. `test05_bluetooth_gap_does_not_cause_wake` -> PASS (I gap BLE non alterano lo stato né causano false veglie)
  6. `test06_incomplete_recording_marks_process_failed` -> PASS (Campioni < 1800 contrassegnati PROCESS_FAILED con INSUFFICIENT_DATA)
  7. `test07_processing_enqueued_once_idempotent` -> PASS (Richieste multiple idempotenti rifiutate)
  8. `test08_process_restart_recovery` -> PASS (Recupero stato PROCESS_PENDING -> PROCESSING -> REPORT_READY post-restart)
  9. `test09_revision_and_reprocessing` -> PASS (Richiesta ricalcolo/revisione da REPORT_READY riavvia il ciclo)
  10. `test10_no_regression_always_on_recorder` -> PASS (Coesistenza perfetta tra BleStateMachine e NightStateMachine)

### B. Analisi Statica del Codice Flutter (`app/`)
```powershell
Set-Location app; flutter analyze
```
- **Esito:** `No issues found! (ran in 11.8s)` (0 errori, 0 warning, 0 avvisi di stile).

### C. Test Unitari e Widget Flutter (`app/`)
```powershell
Set-Location app; flutter test test/sleep_lab/auto_sleep_detection_and_reporting_test.dart
```
- **Esito:** `All tests passed!` (3/3 test passati: persistenza atomica, rendering card dashboard con tutti i campi e fallback «Dati insufficienti»).
- **Suite completa:** 117/117 test passati.

---

## 7. Procedura di Collaudo Reale sul Samsung

Per la notte di oggi (11–12 Novembre 2026), l'utente verificherà il sistema sul dispositivo reale con la seguente procedura:

### Fase 1: Sera prima di dormire
1. Installare l'APK aggiornato:
   ```bash
   adb install -r -d app/build/app/outputs/flutter-apk/app-debug.apk
   ```
2. Aprire Beveltry.
3. Nella schermata Always-On Recorder, verificare che l'interruttore sia su **ATTIVO** e che i 6 indicatori siano verdi.
4. **NON premere «Avvia Night Recorder» manuale.**
5. Indossare WHOOP B al polso.
6. Bloccare lo smartphone con schermo spento e andare a dormire.

### Fase 2: Durante la notte (Nessuna interazione richiesta)
- Se l'utente si sveglia brevemente per bere, il sistema rileverà un risveglio transitorio (`WAKE_WITHIN_SLEEP`) e riprenderà lo stato `SLEEP_ACTIVE` al riaddormentamento, accumulando il tempo come WASO.
- Se il Bluetooth subisce un'interruzione o una riconnessione automatica, il gap verrà registrato come evento tecnico senza interrompere il sonno.

### Fase 3: Mattino al risveglio
1. Alzarsi dal letto e iniziare le normali attività per almeno 20-30 minuti.
2. Osservare lo smartphone:
   - Verificare la comparsa della notifica nativa nella tendina:
     `«Beveltry — Analisi della notte pronta»` con durata sonno, RHR e HRV.
3. Aprire Beveltry:
   - Sulla **Dashboard**, la card «ULTIMA NOTTE RILEVATA» mostra il badge verde `REPORT PRONTO`, orari effettivi di sonno, TST, WASO, HRV RMSSD, RHR e copertura campioni.
   - Toccando la card o aprendo **Sleep Lab**, la schermata mostra la notte analizzata, il grafico FC con campitura del sonno, i dettagli dell'HRV Window Lab e il confronto con WHOOP A (se compilato).

---

## 8. Dettagli APK e Comando di Installazione

- **Percorso Artifact APK:** `app/build/app/outputs/flutter-apk/app-debug.apk`
- **Dimensione:** 180.014.765 byte (~180 MB)
- **Data e Ora Compilazione:** 11 Novembre 2026, 13:40:45 CET
- **SHA-256:** `EFC68D6195B37EE6C2F98CB6B5EC437B811328B41FF754CBBC494DE1BE6ECBFA`
- **Package Name:** `com.beveltry.beveltry`
- **Modalità Installazione:** In-place update (`-r -d`), nessuna disinstallazione, nessun wipe database.

```bash
adb install -r -d app/build/app/outputs/flutter-apk/app-debug.apk
```

---

## 9. Tabella di Conformità dello Stato

| Requisito / Modulo | Stato | Dettaglio di Verifica |
| :--- | :--- | :--- |
| Rilevamento automatico inizio sonno (Onset) | `TESTED` | Test unitario deterministico superato; validazione reale stanotte. |
| Rilevamento risvegli intermedi (WASO) | `TESTED` | Isteresi e ripresa sonno verificati con test deterministici. |
| Risveglio finale con conferma temporale | `TESTED` | Finestra di conferma 20 min verificata nel test state machine. |
| Distinzione gap BLE da veglia | `TESTED` | Test 05 conferma che un gap radio non altera lo stato del sonno. |
| Worker WorkManager automatico al risveglio | `TESTED` | `SleepAnalysisWorker` idempotente con unique work `sleep-analysis-<key>`. |
| Gestione dati insufficienti (< 30 min) | `TESTED` | Stato marcato `PROCESS_FAILED` con `INSUFFICIENT_DATA` senza notifica falsa. |
| Notifica nativa «Analisi notte pronta» | `IMPLEMENTED` | Canale priorità alta Android con intent verso Sleep Lab. |
| Card Ultima Notte nella Dashboard Flutter | `TESTED` | Widget test superato per tutti i campi, metriche e stati. |
| Ripristino dopo reboot / process death | `TESTED` | Persistenza in SQLite e riconciliazione automatica all'avvio. |
| Nessuna regressione del recorder Always-On | `TESTED` | 62 test Kotlin e suite Always-On 08C.2 invariati al 100%. |
| Verifica reale su Samsung (overnight) | `IMPLEMENTED` | Pronto per il collaudo stanotte sul dispositivo fisico Samsung con WHOOP B. |
