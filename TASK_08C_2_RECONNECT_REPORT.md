# TASK 08C.2 — FIX BLE RECONNECTION & STALE STREAMING
## Rapporto Tecnico di Audit, Watchdog Monotono, Gestione Adattatore Bluetooth e Riconnessione BLE Resiliente

**Data:** 11 Novembre 2026  
**Stato Verifica:** `IMPLEMENTED_NOT_DEVICE_TESTED`  
**Dispositivo Target:** WHOOP 5.0 (Dispositivo B, MAC: `FD:49:44:66:1D:92`, Serial: `WBB5AP-5AG0558675`)  
**Package:** `com.beveltry.beveltry` (firma debug preservata, `applicationId` invariato, nessun data wipe)

---

## 1. Causa Identificata e Catena Causale del Guasto

L'audit approfondito sul comportamento di spegnimento e riaccensione dell'adattatore Bluetooth su Samsung Android ha individuato una catena causale articolata su sei livelli:

### A. Blocco Broadcast Impliciti Android 8.0+ (API 26+) per Manifest Receiver
- **Causa Radice Primaria:** `BootAndBleReceiver` era registrato in `AndroidManifest.xml` per ricevere l'azione `BluetoothAdapter.ACTION_STATE_CHANGED`. A partire da Android 8.0 (API 26), il sistema operativo blocca la consegna della maggior parte dei broadcast impliciti ai receiver dichiarati staticamente nel manifest.
- **Effetto:** Quando l'utente disattivava il Bluetooth dal pannello rapido del Samsung, `BootAndBleReceiver.onReceive` **non veniva mai invocato**. Né il servizio `WhoopConnectionService` né l'app ricevevano la notifica a livello di receiver manifest.

### B. Assenza di un BroadcastReceiver Dinamico Registrato a Runtime nel Servizio
- **Problema:** Né `WhoopConnectionService` né `MainActivity` registravano dinamicamente un `BroadcastReceiver` con `registerReceiver(..., IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))` durante il ciclo di vita del Foreground Service.
- **Effetto:** Il Foreground Service era completamente all'oscuro dello stato hardware dell'adattatore Bluetooth (`STATE_TURNING_OFF`, `STATE_OFF`, `STATE_TURNING_ON`, `STATE_ON`).

### C. Assenza di Watchdog di Freschezza del Flusso HR (Phantom Streaming)
- **Problema:** Il flag `isStreaming` in `RecordingCoordinator` e nella UI veniva impostato a `true` alla ricezione del primo pacchetto HR e **non veniva mai invalidato** finché non sopraggiungeva una disconnessione esplicita. Se il flusso di pacchetti si arrestava bruscamente (es. spegnimento BT, allontanamento radio, blocco firmware), la UI e il coordinator continuavano a considerare il flusso come attivo.
- **Effetto:** La UI mostrava "STREAMING" e "PERSISTING" con campioni vecchi di oltre 100 secondi, ingannando l'utente e il sistema di monitoraggio.

### D. Mancato Reset di Stato e Mancata Chiusura GATT in `RecordingCoordinator`
- **Problema:** In `RecordingCoordinator.onBluetoothStateChanged(false)`, il metodo si limitava a impostare una variabile locale, senza azzerare `isStreaming`, `isPersisting`, `isGattConnected`, né invocare l'azione di disconnessione verso il layer GATT sottostante.
- **Effetto:** I flag rimanevano congelati nel vecchio stato attivo.

### E. Blocco della Macchina a Stati `BleStateMachine`
- **Problema:** Nel metodo `triggerConnection()`, era presente il controllo:
  ```kotlin
  if (currentState is BleState.Streaming) return
  ```
  Poiché la macchina a stati non era stata informata dello stallo o dello spegnimento del Bluetooth, rimaneva bloccata in `BleState.Streaming`. Quando l'utente riaccendeva il Bluetooth, ogni tentativo di connessione automatica veniva abortito sul nascere poiché il sistema riteneva erroneamente di essere già in streaming.

### F. Riuso di Handle `BluetoothGatt` Obsoleto e Race Condition sulle Callback
- **Problema:** Quando l'adattatore Bluetooth Android viene spento e riacceso, tutti gli handle `BluetoothGatt` nativi precedentemente aperti dal processo vengono invalidati a livello HAL/BlueDroid/Fluoride. Se non vengono chiusi esplicitamente con `gatt.close()` e sostituiti da una nuova istanza, qualsiasi operazione successiva fallisce con errore di stato 133 o rimane sospesa a tempo indeterminato.
- **Effetto:** La coda serializzata `SerializedGattQueue` conteneva operazioni pendenti mai completate, e la nuova connessione non riusciva ad allocare un canale pulito.

---

## 2. File e Righe Modificati

| File | Righe / Componenti | Dettaglio Tecnico della Modifica |
| :--- | :--- | :--- |
| `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/BleStateMachine.kt` | `BleEvent`, `transition()` | • Aggiunti eventi `BluetoothTurningOff`, `StreamStale`, `ConnectionTimeout`<br>• Transizione controllata da `Streaming` a `ReconnectWait` su evento `StreamStale`<br>• Timeout di connessione (20s) da `Connecting`/`Subscribing` verso `ReconnectWait`<br>• Idempotenza su `BluetoothTurnedOn` in stato `Associated` |
| `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/SerializedGattQueue.kt` | `clear()` | • Drenaggio completo del channel di accodamento<br>• Completamento con fallimento controllato di tutti i `CompletableDeferred` pendenti per sbloccare le coroutine in attesa |
| `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/BootAndBleReceiver.kt` | `onReceive()` | • Gestione esplicita di `BluetoothAdapter.STATE_TURNING_OFF` per disconnessione tempestiva prima del blackout radio |
| `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopConnectionService.kt` | `bluetoothStateReceiver`, `gattSessionGeneration`, `handleBluetoothDisabled/Enabled` | • Registrazione dinamica a runtime di `bluetoothStateReceiver` in `onCreate()` (con flag `RECEIVER_EXPORTED` su Android 13+) e unregister in `onDestroy()`<br>• Tracciamento generazionale `gattSessionGeneration` (`AtomicInteger`) e `activeCallbackGeneration`: scarto immediato di callback ritardate da vecchi handle GATT<br>• Chiusura esplicita `gatt.close()`, svuotamento coda, log evento `GATT_CLOSED`<br>• Notifica istantanea al `RecordingCoordinator` |
| `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/RecordingCoordinator.kt` | Watchdog freschezza, Concurrency supervisor, Reconnect backoff | • Introduzione di `STREAM_FRESHNESS_TIMEOUT_MS = 6000L` e verifica ogni 2.000 ms basata su `SystemClock.elapsedRealtime()`<br>• Funzione `handleStreamStale(elapsedMs)`: log `STREAM_STALE`, chiusura segmento, azzeramento flag streaming/persisting, schedulazione riconnessione controllata<br>• Timeout di connessione a 20 secondi (`startConnectingTimeout`) con log `CONNECTION_TIMEOUT`<br>• Preservazione rigorosa dell'impostazione utente `isAlwaysOnEnabled = true` durante gli spegnimenti BT<br>• Flag `wasReconnected`: emissione eventi speciali `FIRST_HR_AFTER_RECONNECT` e `FIRST_HR_PERSISTED_AFTER_RECONNECT` alla ripresa |
| `app/android/app/src/main/kotlin/com/beveltry/beveltry/MainActivity.kt` | `onAlwaysOnUpdate()` | • Inoltro dei campi `isStreamStale` e `isBluetoothEnabled` verso il layer Flutter |
| `app/lib/screens/always_on_screen.dart` | UI 6-Layer Status, Event filter list | • Distinzione completa in 6 livelli indipendenti: FGS, Adattatore BT, Connessione GATT, Sottoscrizione CCCD, Flusso Notifiche (con badge STALE arancione e secondi trascorsi), Persistenza SQLite<br>• Aggiunta dei filtri diagnostici per tutti i nuovi eventi del ciclo di vita BLE |
| `native/android/beveltry-ble/src/test/kotlin/com/beveltry/ble/AlwaysOnRecorderTest.kt` | 10 Test Unitari di Simulazione | • Suite completa di 10 scenari: spegnimento BT, stallo notifiche >6s, recupero sessione dopo riaccensione, scarto callback obsolete, backoff esponenziale, preservazione Always-On |
| `app/test/services/always_on_recorder_test.dart` | Test Widget Flutter | • Verifica rendering simultaneo dei 6 livelli di stato e visualizzazione corretta degli indicatori di stallo e riconnessione |

---

## 3. Test Automatici Realmente Eseguiti

Tutte le suite di test automatiche sono state eseguite localmente con successo pieno:

### A. Suite Unitaria Kotlin Android (`native/android`)
Comando:
```powershell
Set-Location native/android; ./gradlew :beveltry-ble:testDebugUnitTest
```
- **Esito:** `BUILD SUCCESSFUL in 22s`
- **Risultato:** **52/52 test superati (100% pass)**.
- **Scenari coperti in `AlwaysOnRecorderTest`:**
  1. `scenario 1: normal streaming and persisting flags active` -> PASS
  2. `scenario 2: freshness watchdog marks stream stale after 6000ms inactivity` -> PASS
  3. `scenario 3: bluetooth turning off cleans up state and logs technical event` -> PASS
  4. `scenario 4: bluetooth off does not trigger connection attempt` -> PASS
  5. `scenario 5: bluetooth on schedules controlled reconnection` -> PASS
  6. `scenario 6: first sample after reconnect logs special recovery event` -> PASS
  7. `scenario 7: stale gatt callbacks from older generation are dropped` -> PASS
  8. `scenario 8: connection timeout after 20s schedules backoff retry` -> PASS
  9. `scenario 9: coordinator preserves always on flag across bluetooth disable` -> PASS
  10. `scenario 10: ui state reports stale stream and disabled bluetooth accurately` -> PASS

### B. Analisi Statica del Codice Flutter (`app/`)
Comando:
```powershell
Set-Location app; flutter analyze
```
- **Esito:** `No issues found! (ran in 10.4s)` (0 errori, 0 warning, 0 issue di formattazione).

### C. Suite di Test Flutter (`app/`)
Comando:
```powershell
Set-Location app; flutter test
```
- **Esito:** `All tests passed! (ran in 40.2s)`
- **Risultato:** **114/114 test superati (100% pass)**, inclusi:
  - `test/services/always_on_recorder_test.dart`: rendering dei 6 layer diagnostici, aggiornamento reactive del MethodChannel e transizioni di stallo.
  - Test di regressione DSP e Sleep Lab con dati reali WHOOP.

---

## 4. Architettura dei 6 Livelli di Stato Indipendenti

La UI e il Coordinator non utilizzano più un unico stato aggregato che confondeva la connessione GATT con l'arrivo reale dei campioni. Sono ora esposti 6 livelli verificabili indipendentemente:

```
[1] Foreground Service      : ATTIVO (FGS in esecuzione, Notifica di sistema visibile)
[2] Adattatore Bluetooth    : ABILITATO (Hardware radio attivo / DISABILITATO quando OFF)
[3] Connessione GATT        : CONNESSO (GATT Session valida / DISCONNESSO / RICONNESSIONE)
[4] Sottoscrizione 0x2A37   : ATTIVA (Descrittore CCCD 0x2902 confermato con successo)
[5] Flusso Notifiche HR     : ATTIVO (<6s da ultimo battito) / STALE (>6s senza campioni)
[6] Persistenza SQLite      : ATTIVA (Segmento aperto, record inseriti in whoop_local.db)
```

### Logica del Freshness Watchdog (Watchdog Monotono)
- Frequenza campionamento WHOOP B: ~1 Hz (1 notifica al secondo).
- Soglia Watchdog: `STREAM_FRESHNESS_TIMEOUT_MS = 6000L` (6 secondi di tolleranza per consentire eventuali re-delivery BLE o brevi drop radio).
- Orologio di riferimento: `SystemClock.elapsedRealtime()` (monotono, immune da cambi di fuso o sync NTP).
- Azione al superamento della soglia:
  1. `isStreamStale = true`, `isStreaming = false`, `isPersisting = false`.
  2. Scrittura evento `STREAM_STALE` nel database SQLite.
  3. Chiusura del segmento corrente in `whoop_local.db` per preservare l'integrità temporale dei dati.
  4. Schedulazione della riconnessione controllata tramite `BleStateMachine`.

---

## 5. Procedura di Verifica Hardware sul Samsung

### Prerequisiti
- Smartphone Samsung Android con Bluetooth attivo.
- Fascia WHOOP B indossata al polso o con sensore a contatto con la pelle.
- Schermo del dispositivo sbloccato sulla schermata **Always-On Recorder** di Beveltry.

### Passo 1: Verifica Stato Iniziale a Regime
1. Verificare che tutti e 6 gli indicatori siano verdi:
   - Foreground Service: `ATTIVO`
   - Adattatore Bluetooth: `ABILITATO`
   - Connessione GATT: `CONNESSO`
   - Sottoscrizione 0x2A37: `ATTIVA`
   - Flusso Notifiche HR: `ATTIVO (< 2s)`
   - Persistenza SQLite: `ATTIVA`
2. Verificare che il contatore campioni HR aumenti regolarmente di 1 al secondo.

### Passo 2: Test Disattivazione Bluetooth (Bluetooth OFF)
1. Abbassare la tendina delle notifiche e **disattivare il Bluetooth**.
2. **Cosa osservare immediatamente in Beveltry:**
   - L'indicatore Adattatore Bluetooth passa a rosso: `DISABILITATO`.
   - L'indicatore Connessione GATT passa a grigio: `DISCONNESSO`.
   - Gli indicatori Flusso Notifiche e Persistenza **smettono immediatamente di mostrare STREAMING/PERSISTING**.
   - Nella lista Eventi Tecnici compaiono in sequenza:
     - `BLUETOOTH_TURNING_OFF` (o `BLUETOOTH_OFF`)
     - `GATT_CLOSED`
3. Verificare che l'interruttore "Abilita Always-On" resti regolarmente su **ON**.
4. Attendere 15-20 secondi: confermare che l'app non vada in crash e non tenti loop aggressivi di riconnessione.

### Passo 3: Test Riattivazione Bluetooth (Bluetooth ON)
1. Riattivare il Bluetooth dalla tendina delle impostazioni rapide del Samsung.
2. **Cosa osservare in Beveltry (entro 3-8 secondi):**
   - Nella lista eventi compare: `BLUETOOTH_ON`.
   - Compare `RECONNECT_SCHEDULED` seguito da `RECONNECT_ATTEMPT` con nuova generazione di sessione GATT.
   - Si susseguono rapidamente gli eventi:
     - `GATT_CONNECTED`
     - `SERVICES_DISCOVERED`
     - `HR_CHAR_FOUND`
     - `CCCD_WRITE_SUCCESS`
     - `FIRST_HR_AFTER_RECONNECT`
     - `FIRST_HR_PERSISTED_AFTER_RECONNECT`
   - Tutti e 6 i livelli tornano verdi.
   - Il contatore campioni HR e battiti RR riprende a salire regolarmente.
   - Il valore "Ultimo campione" torna stabilmente a `0s fa` / `1s fa`.

### Passo 4: Criteri di Superamento (PASS Criteria)
- [ ] Nessuna segnalazione di "STREAMING" mentre il Bluetooth è disattivato.
- [ ] Nessun crash di processo o eccezione non gestita.
- [ ] Riconnessione completamente autonoma senza dover riaprire l'app o toccare alcun pulsante.
- [ ] Preservazione della configurazione Always-On attiva.
- [ ] Integrità del database: i dati registrati prima dello spegnimento restano intatti e interrogabili in Sleep Lab.

---

## 6. Dettagli APK e Comando di Installazione

- **Percorso Artifact APK:** `app/build/app/outputs/flutter-apk/app-debug.apk`
- **Dimensione:** 179.998.564 byte (~180 MB)
- **Data e Ora Compilazione:** 11 Novembre 2026, 12:55:32 CET
- **SHA-256:** `71A46FD4B9B4973347D4AED6BD35EA3D669C3885AA7D9DC809BD6B066301D5AB`
- **Package Name:** `com.beveltry.beveltry`
- **Modalità Installazione:** Aggiornamento in-place (`-r`) senza cancellazione dati o disinstallazione (`-d` allow version downgrade if needed).

### Comando di Installazione via ADB:
```bash
adb install -r -d app/build/app/outputs/flutter-apk/app-debug.apk
```

---

## 7. Stato Finale

**Stato:** `IMPLEMENTED_NOT_DEVICE_TESTED`

Tutti i componenti logici, architetturali, i test unitari Kotlin (52/52), l'analisi statica e i test di integrazione Flutter (114/114) sono verificati e completati con successo. Il sistema è pronto per la validazione sul dispositivo fisico Samsung con WHOOP B.
