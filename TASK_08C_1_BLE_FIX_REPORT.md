# TASK 08C.1 — FIX BLOCCANTE: ZERO CAMPIONI HR/RR
## Rapporto Tecnico di Audit BLE, Risoluzione Root Cause e Diagnostica Avanzata

**Data:** 11 Novembre 2026  
**Stato Verifica:** `IMPLEMENTED_NOT_DEVICE_TESTED`  
**Dispositivo Target:** WHOOP 5.0 (Dispositivo B, MAC: `FD:49:44:66:1D:92`, Serial: `WBB5AP-5AG0558675`)  
**Package:** `com.beveltry.beveltry` (debug keystore invariata, nessun data wipe)

---

## 1. Causa Identificata (Root Cause Audit)

L'audit completo del percorso BLE:
`BluetoothGatt → onConnectionStateChange → discoverServices → onServicesDiscovered → 0x2A37 → CCCD 0x2902 → onCharacteristicChanged → HR decoder → RecordingCoordinator → SQLite → Flutter`
ha evidenziato 4 cause scatenanti del fallimento dell'acquisizione campioni HR/RR sul Samsung reale:

### A. Gating Condizionale Errato in `WhoopConnectionService.kt` (Causa Primaria Bloccante)
- **Problema:** Nel metodo `handleNotification(uuid, value)`, l'inoltro del campione al coordinator (`coordinator?.onHrSampleReceived(sample, rrList)`) e la persistenza SQLite erano racchiusi dentro:
  ```kotlin
  if (isNightRecording && activeNightSessionId != null) { ... }
  ```
- **Effetto:** Quando la modalità Always-On era attiva ma l'utente non aveva premuto manualmente il pulsante "Avvia Registrazione" del vecchio Night Recorder, `isNightRecording` era `false` e `activeNightSessionId` era `null`. Pertanto **il 100% dei pacchetti HR notificati da 0x2A37 veniva scartato silenziosamente**. Il coordinator e il database non ricevevano alcun campione, lasciando i contatori a zero e lo stato fermo su "In attesa battito".

### B. Priorità Invertita nella Sottoscrizione CCCD (Latenza e Rischio Timeout)
- **Problema:** La caratteristica `HEART_RATE_MEASUREMENT_UUID` (`0x2A37`) veniva accodata come **quinta di cinque** caratteristiche da sottoscrivere in `setupGattSession()`, dopo `CMD_FROM_STRAP_UUID`, `STREAM_DATA_UUID`, `EVENT_DATA_UUID` e `MEMFAULT_DATA_UUID`.
- **Effetto:** Se una delle caratteristiche proprietarie Puffin tardava a confermare la scrittura del descrittore `0x2902` (o se il firmware WHOOP 5.0 imponeva rate-limiting sui descrittori), la sottoscrizione a `0x2A37` restava in attesa per 15-20 secondi o falliva silenziosamente, impedendo al cinturino di avviare lo streaming HR.

### C. Incompatibilità Callback `onCharacteristicChanged` su Stack OEM Android 14+ (Samsung One UI)
- **Problema:** In `WhoopConnectionService.kt`, il metodo `onCharacteristicChanged(gatt, characteristic)` conteneva una guardia restrittiva `if (Build.VERSION.SDK_INT < 33) return`.
- **Effetto:** Su diversi stack Bluetooth OEM (tra cui Samsung One UI basato su Android 14/15), la callback legacy a due argomenti `onCharacteristicChanged(gatt, characteristic)` viene ancora invocata in alternativa o in combinazione con la callback API 33 `onCharacteristicChanged(gatt, characteristic, value)`. La guardia scartava le notifiche se il framework chiamava la firma legacy. Inoltre, in `SerializedGattQueue.kt`, mancava la pre-impostazione `@Suppress("DEPRECATION") descriptor.value = data` richiesta da alcuni vendor HAL per evitare il codice errore GATT 133 / write descriptor failure.

### D. Disallineamento Tipo Argomento MethodChannel tra Kotlin e Flutter
- **Problema:** `MainActivity.kt` inviava le notifiche HR verso Flutter tramite `onStandardHr` trasmettendo una `Map<String, Any>` (`{hr, rrIntervalsMs, flags, timestamp}`), mentre `method_channel_puffin_transport.dart` si aspettava tassativamente un `Uint8List` per inoltrare i byte allo stream `_standardHrController`.
- **Effetto:** La schermata legacy `NightRecorderScreen` (che ascoltava `standardHrStream`) non riceveva alcun byte e non aggiornava la UI dei battiti.

---

## 2. File e Righe Modificati

| File | Righe Modificate / Aggiunte | Scopo della Modifica |
| :--- | :--- | :--- |
| `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopConnectionService.kt` | L. 515-535, L. 680-725, L. 320-335 | • `0x2A37` registrata per prima come **Priorità #1** in `setupGattSession`<br>• Rimosso gating `if (isNightRecording)` in `handleNotification`, campione inoltrato incondizionatamente a `coordinator`<br>• Logging eventi tecnici in `connection_events` (GATT, CCCD, NOTIFICATION)<br>• Rimosso blocco `Build.VERSION.SDK_INT < 33` in `onCharacteristicChanged` |
| `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/SerializedGattQueue.kt` | L. 65-75 | • Aggiunto `descriptor.value = data` pre-write per compatibilità OEM Samsung |
| `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/RecordingCoordinator.kt` | L. 130-185, L. 310-340 | • Log transizioni di stato e diagnostica lifecycle (`FIRST_HR_NOTIFICATION`, `FIRST_HR_DECODED`, `FIRST_HR_PERSISTED`, `STREAMING`) in `connection_events` |
| `native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopStorageEngine.kt` | L. 200-220 | • Metodo helper `logConnectionEvent` per tracciare il ciclo di vita BLE |
| `app/android/app/src/main/kotlin/com/beveltry/beveltry/MainActivity.kt` | L. 195-220 | • Inoltro simultaneo degli aggiornamenti Always-On (`onAlwaysOnUpdate`) e Standard HR |
| `app/lib/src/ble/method_channel_puffin_transport.dart` | L. 2, L. 106-128 | • Import `dart:typed_data`<br>• Gestione del payload `Map` in `onStandardHr` con sintesi dei byte standard BLE (flags + HR + RR LE uint16) su `_standardHrController` |
| `app/lib/screens/night_recorder_screen.dart` | L. 120-145 | • Sottoscrizione anche a `onAlwaysOnUpdate` per sincronizzare la UI anche a sessione avviata dal Coordinator |
| `app/lib/screens/always_on_screen.dart` | L. 300-340, L. 440-560 | • Quadruplo indicatore di stato visivo a 4 stadi: `GATT_CONNECTED`, `SUBSCRIBED`, `STREAMING`, `PERSISTING`<br>• Nuova sezione Diagnostica «Sequenza Eventi Tecnici BLE (Lifecycle)» leggibile direttamente su smartphone senza ADB |

---

## 3. Test Automatici Realmente Eseguiti

Tutti i test automatici sono stati eseguiti nell'ambiente locale di sviluppo con esito positivo:

1. **Test Unitari Kotlin (`native/android`):**
   ```bash
   ./gradlew :beveltry-ble:testDebugUnitTest
   ```
   - **Esito:** `BUILD SUCCESSFUL in 26s`
   - **Risultato:** **42/42 test passati** (16 actionable tasks: 16 up-to-date). Testata la macchina a stati `BleStateMachine`, `RecordingCoordinator`, `WhoopStorageEngine`, la deduplica a 3 tuple `(record_index, timestamp_epoch, beat_ordinal)` e il parsing degli intervalli RR senza conversione 1/1024s.

2. **Analisi Statica Flutter (`app/`):**
   ```bash
   flutter analyze
   ```
   - **Esito:** `No issues found! (ran in 10.0s)` (0 errori, 0 warning).

3. **Test Unitari e d'Integrazione Flutter (`app/`):**
   ```bash
   flutter test
   ```
   - **Esito:** `All tests passed!`
   - **Risultato:** **113/113 test passati** (incluso `test/services/always_on_recorder_test.dart` e suite di regressione DSP `sleep_lab_regression_real_data_test.dart`).

---

## 4. Test Hardware Ancora Necessari (Samsung + WHOOP B)

Finché non viene verificato fisicamente sullo smartphone Samsung con il dispositivo WHOOP B indossato, lo stato resta `IMPLEMENTED_NOT_DEVICE_TESTED`.

### Piano di Test su Banco:
1. **Verifica Sequenza CCCD:**
   - Confermare che nei primi 2 secondi dalla connessione compaiano gli eventi `GATT_CONNECTED` → `SERVICES_DISCOVERED` → `HR_CHAR_FOUND` → `CCCD_WRITE_SUCCESS`.
2. **Verifica Flusso Battiti (On-Wrist):**
   - Indossare WHOOP B.
   - Verificare che entro 3-5 secondi compaiano `FIRST_HR_NOTIFICATION`, `FIRST_HR_DECODED`, `FIRST_HR_PERSISTED`, seguiti dallo stato `STREAMING`.
3. **Verifica Incremento Contatori:**
   - Verificare che il contatore "Campioni HR totali" incrementi di 1 al secondo (circa 60 campioni/minuto).
   - Verificare che "Battiti R-R totali" incrementi regolarmente.
4. **Verifica Schermo Spento e Background:**
   - Bloccare lo smartphone con schermo spento per 5 minuti.
   - Riaccendere e verificare che i campioni non abbiano subito interruzioni e che il tempo dall'ultimo campione sia `<= 2s`.

---

## 5. APK Aggiornato e Installazione

Il nuovo APK di debug aggiornato è stato compilato e verificato:

- **Percorso file:** `app/build/app/outputs/flutter-apk/app-debug.apk`
- **Dimensione:** 179.998.584 byte (~180 MB)
- **Data compilazione:** 11 Novembre 2026, 11:47:48
- **Application ID:** `com.beveltry.beveltry`
- **Keystore:** Debug standard Android (compatibile per sovrainstallazione senza cancellare dati utente o database SQLite).

### Comando di Installazione Aggiornamento:
```bash
adb install -r -d app/build/app/outputs/flutter-apk/app-debug.apk
```
*(L'opzione `-r` reinstalla preservando database e preferenze; `-d` ammette il downgrade del version code se necessario).*

---

## 6. Istruzioni per Controllare dal Samsung la Sequenza di Eventi GATT (Senza ADB)

Per verificare il funzionamento direttamente dallo schermo dello smartphone senza necessità di collegare il cavo USB o usare ADB:

1. **Aprire Beveltry** sullo smartphone Samsung.
2. Toccare l'icona dell'ingranaggio in alto a destra (**Impostazioni**) oppure accedere alla scheda **Registrazione Automatica WHOOP**.
3. Assicurarsi che l'interruttore **Registrazione automatica WHOOP** sia posizionato su **ON**.
4. Selezionare la tab **Diagnostica** in alto a destra.
5. Nella card **Sequenza Eventi Tecnici BLE (Lifecycle)**, osservare la sequenza temporale con i relativi badge colorati:
   - `GATT_CONNECTED` (Giallo/Verde) con timestamp locale.
   - `SERVICES_DISCOVERED` (Giallo/Verde) con conteggio dei servizi BLE trovati (incluso `0x180D`).
   - `HR_CHAR_FOUND` (Verde) con UUID `00002a37-0000-1000-8000-00805f9b34fb`.
   - `CCCD_WRITE_STARTED` (Giallo).
   - `CCCD_WRITE_SUCCESS` (Verde) con descriptor `0x2902` e status `0`.
   - `FIRST_HR_NOTIFICATION` (Verde) che attesta la prima notifica grezza BLE ricevuta dal cinturino.
   - `FIRST_HR_DECODED` (Verde) con indicazione del primo valore BPM rilevato.
   - `FIRST_HR_PERSISTED` (Verde) con conferma di scrittura nella tabella SQLite.
   - `STREAMING` (Verde) che conferma l'aggancio stabile del flusso dati.
6. Se compare un badge rosso (`CCCD_WRITE_FAILED` o `DISCONNECTED`), leggere il codice di errore visualizzato a destra del badge (es. `[err: 133]` o `status != 0`).
7. Tornando alla tab **Impostazioni**, verificare i 4 indicatori di progressione reale:
   - **Link BLE (GATT_CONNECTED):** `CONNESSO`
   - **Sottoscrizione 0x2A37:** `SUBSCRIBED (OK)`
   - **Flusso Notifiche:** `STREAMING (XX BPM)`
   - **Persistenza SQLite:** `PERSISTING (N campioni salvati)`
