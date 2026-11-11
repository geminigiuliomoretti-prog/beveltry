# PROTOCOLLO DI COLLAUDO REALE SAMSUNG — TASK 08C
## Beveltry Always-On Recorder per WHOOP 5.0 (Dispositivo B)

**Dispositivo:** Smartphone Samsung Galaxy (One UI 6+ / Android 14+)  
**Fascia WHOOP:** Dispositivo B (MAC: `FD:49:44:66:1D:92`, Serial: `WBB5AP-5AG0558675`)  
**APK di test:** `app/build/app/outputs/flutter-apk/app-debug.apk`  
**Package:** `com.beveltry.beveltry`

---

## 1. PREREQUISITI E CONFIGURAZIONE SAMSUNG ONE UI

Prima di iniziare i test, è essenziale impostare le eccezioni del risparmio energetico di Samsung, che altrimenti terminerebbe il Foreground Service a schermo spento:

1. **Aggiornamento APK (senza disinstallare l'app):**
   ```bash
   adb install -r -d app/build/app/outputs/flutter-apk/app-debug.apk
   ```
2. **Batteria senza restrizioni:**
   - Vai in: **Impostazioni → Applicazioni → Beveltry → Batteria**.
   - Seleziona **«Senza restrizioni»** (Unrestricted).
3. **Applicazioni mai in sospensione (Never sleeping apps):**
   - Vai in: **Impostazioni → Assistenza dispositivo → Batteria → Limiti per l'uso in background**.
   - Seleziona **«Applicazioni mai in sospensione»** (Never sleeping apps).
   - Tocca il pulsante **`+`**, seleziona **Beveltry** e conferma con **Aggiungi**.
4. **Verifica Permessi:**
   - Apri Beveltry.
   - Accetta permessi: Dispositivi vicini (`BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN`) e Notifiche (`POST_NOTIFICATIONS`).

---

## 2. ATTIVAZIONE ALWAYS-ON

1. Apri l'app Beveltry.
2. Dalla Dashboard, tocca l'icona **Always-On** nella barra superiore (o il banner dedicato).
3. Nella schermata **Registrazione Automatica**, attiva lo switch **«Abilita Registrazione Continua»**.
4. **Verifica osservabilità a 3 livelli:**
   - **Foreground Service:** deve mostrare `ATTIVO (connectedDevice)` verde.
   - **Link BLE GATT:** deve mostrare `GATT_CONNECTED` o `SUBSCRIBING_HR`.
   - **Flusso 0x2A37:** entro pochi secondi deve passare a `STREAMING (HR/RR attivi)` verde con battito in tempo reale (es. `72 bpm | 845 ms`).
5. **Verifica notifica persistente:**
   - Abbassa la tendina notifiche di Android.
   - Deve essere presente la notifica: **«Beveltry — Registrazione WHOOP attiva»** con frequenza cardiaca e pulsante **«Disattiva Always-On»**.

---

## 3. PROTOCOLLO DEI 5 TEST REALI

---

### TEST 1 — Acquisizione a Schermo Spento (30 Minuti)
*Obiettivo: Verificare che il Foreground Service acquisisca campioni continui senza entrare in Doze mode.*

1. Assicurati che lo stato sia `STREAMING` e la notifica sia attiva.
2. Indossa il WHOOP B al polso.
3. Spegni lo schermo dello smartphone con il tasto di accensione.
4. Lascia lo smartphone fermo sulla scrivania per **30 minuti**.
5. Riaccendi lo schermo e apri Beveltry.
6. Vai nella scheda **Diagnostica**:
   - Controlla **Campioni HR totali**: deve essere aumentato di circa 1800 campioni (~1 campione/sec per 30 min).
   - Controlla **Gap totali rilevati**: deve essere 0 o un numero minimo di brevi oscillazioni.
7. **Esito atteso:** Acquisizione ininterrotta a schermo spento.

---

### TEST 2 — Disconnessione e Out-of-Range (Allontanamento Fascia)
*Obiettivo: Verificare il comportamento del backoff esponenziale e la riconnessione automatica senza blocchi o leak di memoria.*

1. Con lo streaming attivo, allontana il WHOOP B dallo smartphone (oppure inseriscilo in una scatola metallica / gabbia di Faraday) per **5–10 minuti**.
2. Osserva lo stato di Beveltry e la notifica:
   - Lo stato passa a `RECONNECT_WAIT`.
   - L'attesa di riconnessione scala progressivamente: `0s → 2s → 5s → 15s → 30s → 60s`.
3. Riporta il WHOOP B vicino allo smartphone.
4. Entro un ciclo di backoff (max 60 secondi):
   - La connessione deve ripristinarsi autonomamente (`CONNECTING` → `GATT_CONNECTED` → `SUBSCRIBING_HR` → `STREAMING`).
   - Il timer di backoff si resetta a 0 secondi alla ricezione del primo campione valido.
5. In **Diagnostica**, verifica che l'evento di disconnessione sia stato registrato con relativo timestamp e motivazione.
6. **Esito atteso:** Recupero automatico della sessione senza intervento dell'utente.

---

### TEST 3 — Bluetooth Disattivato e Riattivato
*Obiettivo: Verificare che il `BootAndBleReceiver` gestisca l'evento di spegnimento e riaccensione dell'adattatore radio.*

1. Con registrazione attiva, apri la tendina dei comandi rapidi di Samsung e **disattiva il Bluetooth**.
2. Osserva Beveltry:
   - Lo stato transita immediatamente a `BLUETOOTH_DISABLED`.
   - La notifica aggiorna il testo segnalando il Bluetooth non disponibile.
3. Attendi 15 secondi.
4. **Riattiva il Bluetooth** dai comandi rapidi.
5. Il `BootAndBleReceiver` intercetta `BluetoothAdapter.ACTION_STATE_CHANGED`:
   - Il `RecordingCoordinator` riavvia la sequenza di associazione e connessione.
   - Lo stato torna su `CONNECTING` e poi `STREAMING`.
6. **Esito atteso:** Resilienza completa al toggle del Bluetooth.

---

### TEST 4 — Chiusura dell'Interfaccia Flutter (Swipe-Out dalle App Recenti)
*Obiettivo: Verificare che il processo background continui a registrare anche se l'interfaccia utente viene rimossa dalla memoria.*

1. Con registrazione attiva e campioni in arrivo, torna alla Home dello smartphone.
2. Apri la schermata **Applicazioni recenti** di Android e fai uno **swipe verso l'alto per chiudere Beveltry**.
3. Verifica la tendina notifiche di Android:
   - La notifica **«Beveltry — Registrazione WHOOP attiva»** **DEVE rimanere visibile** e continuare ad aggiornare il battito cardiaco.
4. Attendi 5 minuti con l'app chiusa.
5. Riapri l'app Beveltry:
   - L'interfaccia deve collegarsi al service già attivo.
   - Il contatore campioni deve includere tutti i dati registrati durante i 5 minuti di assenza dell'interfaccia.
6. **Esito atteso:** Il Foreground Service è indipendente dal ciclo di vita della UI Flutter.

---

### TEST 5 — Riavvio Completo dello Smartphone (Reboot Recovery)
*Obiettivo: Verificare il ripristino dell'acquisizione dopo lo spegnimento e riaccensione del sistema operativo.*

1. Assicurati che Always-On sia impostato su **ON**.
2. Riavvia lo smartphone Samsung (Riavvia / Restart).
3. Sblocca lo smartphone al boot (necessario per decrittografare il database privato `Credential Encrypted Storage`).
4. Entro 1–2 minuti dall'avvio:
   - Il `BootAndBleReceiver` riceve `ACTION_BOOT_COMPLETED`.
   - Il receiver avvia `WhoopConnectionService` e pianifica `WhoopMaintenanceWorker`.
   - La notifica di Beveltry ricompare nella tendina notifiche.
   - Il sistema si riconnette a WHOOP B non appena l'adattatore Bluetooth è pronto.
5. Apri Beveltry e verifica che il segmento precedente risulti chiuso e un nuovo segmento sia in corso di registrazione.
6. **Esito atteso:** Continuità Always-On anche attraverso un riavvio del dispositivo.

---

## 4. VERIFICA DATABASE SQLITE VIA ADB

Per verificare direttamente sul database SQLite che i campioni, i segmenti e gli eventi siano stati salvati correttamente:

```bash
# Entra nella shell dell'app o estrai il database
adb exec-out run-as com.beveltry.beveltry cat databases/whoop_local.db > test_whoop_local.db

# Verifica la presenza delle nuove tabelle e record
sqlite3 test_whoop_local.db "SELECT * FROM automatic_recording_settings;"
sqlite3 test_whoop_local.db "SELECT id, datetime(start_time_utc/1000, 'unixepoch'), samples_count, status FROM recording_segments ORDER BY id DESC LIMIT 5;"
sqlite3 test_whoop_local.db "SELECT datetime(timestamp_utc/1000, 'unixepoch'), event_type, details FROM connection_events ORDER BY id DESC LIMIT 10;"
sqlite3 test_whoop_local.db "SELECT count(*), min(heart_rate), max(heart_rate) FROM hr_samples;"
```

---

## 5. CONCLUSIONE DEL COLLAUDO

Una volta eseguiti con successo i 5 test sopra descritti, Beveltry è certificato per l'acquisizione continua e resiliente sia di giorno che durante la notte, **azzerando definitivamente il rischio di perdere sessioni di sonno non avviate manualmente**.
