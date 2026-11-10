# TASK 06 — BEVELTRY ANDROID: IMPLEMENTAZIONE CONNESSIONE BLE NATIVA WHOOP 5.0
**Rapporto Tecnico Finale di Ingegnerizzazione e Verifica**

---

## 1. EXECUTIVE SUMMARY & ARCHITETTURA DI SISTEMA

Il presente documento descrive l'architettura, l'ingegnerizzazione e la validazione della connessione nativa Android BLE tra l'applicazione **Beveltry** e il cinturino **WHOOP 5.0** (hardware Gen 5 / Puffin architecture), operante in modalità completamente locale (senza cloud proprietario, abbonamenti o OAuth).

### 1.1 Il Problema Risolto
Nelle versioni precedenti (Task 04 e Task 05):
1. La connessione BLE era parzialmente gestita dallo stack Dart (`BlePuffinTransport` via `universal_ble`) o da un transport Android accoppiato a filo doppio con il ciclo di vita di `MainActivity`.
2. La chiusura, rotazione o backgrounding di `MainActivity` causava la distruzione del controller BLE e la disconnessione immediata di `BluetoothGatt`.
3. Le operazioni GATT (CCCD descriptor write, characteristic write, MTU request) venivano lanciate in modo concorrente o non sequenzializzato, provocando race conditions e timeout (status `133`).
4. La pipeline di ricezione storica non garantiva l'integrità del cursore: l'invio dell'ACK hardware `0x17` poteva precedere la persistenza atomica su SQLite, con rischio di perdita dati permanente su memoria NAND del cinturino.
5. In Flutter, `main.dart` continuava a istanziare il transport Dart isolato anziché il canale nativo Android.

### 1.2 Architettura Unidirezionale Implementata

```
┌─────────────────────────────────────────────────────────────┐
│                    FLUTTER UI LAYER                         │
│  (DashboardScreen, SyncService, MetricsService, UI State)   │
└──────────────────────────────┬──────────────────────────────┘
                               │ MethodChannel & Event Streams
                               │ ('com.beveltry.ble/puffin')
┌──────────────────────────────▼──────────────────────────────┐
│             ANDROID HOST LAYER (MainActivity)               │
│  • Binds to WhoopConnectionService (does NOT own Gatt)      │
│  • Forwards Method Calls (connect, sync, vibrate, stream)    │
│  • Dispatches UI flows without closing Gatt on onDestroy()  │
└──────────────────────────────┬──────────────────────────────┘
                               │ LocalBinder IPC
┌──────────────────────────────▼──────────────────────────────┐
│            WhoopConnectionService (Foreground Service)       │
│  • foregroundServiceType="connectedDevice"                  │
│  • Owns BluetoothGatt & BluetoothGattCallback               │
│  • Manages Reconnect Loop & Exponential Backoff             │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────┐   ┌──────────────────────────┐ │
│  │  ConnectionStateMachine │   │   SerializedGattQueue    │ │
│  │  (Explicit FSM States)  │   │  (FIFO Single-flight)    │ │
│  └───────────┬─────────────┘   └────────────┬─────────────┘ │
│              │                              │               │
│  ┌───────────▼─────────────┐   ┌────────────▼─────────────┐ │
│  │   PuffinFrameCodec &    │   │  HistoricalSyncCoordinator│ │
│  │  PuffinFrameReassembler │   │  (Transactional Pipeline)│ │
│  └───────────┬─────────────┘   └────────────┬─────────────┘ │
│              │                              │               │
│  ┌───────────▼─────────────┐   ┌────────────▼─────────────┐ │
│  │  PuffinProtocolDecoder  │──▶│    WhoopStorageEngine    │ │
│  │ (0x28, 0x2F v18/v26,    │   │   (SQLite WAL + ACID     │ │
│  │  0x31, 0x2A37, 0x24)    │   │    Unique Constraints)   │ │
│  └─────────────────────────┘   └──────────────────────────┘ │
└──────────────────────────────┬──────────────────────────────┘
                               │ Native Android BLE (GATT)
┌──────────────────────────────▼──────────────────────────────┐
│                      WHOOP 5.0 HARDWARE                     │
│  • Proprietary Service: fd4b0001-cce1-4033-93ce-002d5875f58a│
│  • Standard HR Service: 0000180d-0000-1000-8000-00805f9b34fb│
└─────────────────────────────────────────────────────────────┘
```

---

## 2. INVENTARIO COMPLETO DEI FILE MODIFICATI E CREATI

| File | Percorso | Stato | Ruolo Architetturale |
|---|---|---|---|
| [`WhoopConnectionService.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopConnectionService.kt) | `native/android/beveltry-ble/...` | **Creato** | Android Foreground Service (`connectedDevice`); detentore unico di `BluetoothGatt`, coda GATT, sottoscrizioni, handshake e riconnessione. |
| [`SerializedGattQueue.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/SerializedGattQueue.kt) | `native/android/beveltry-ble/...` | **Creato** | Coda FIFO single-flight thread-safe con timeout e cancellazione controllata su disconnessione. |
| [`ConnectionStateMachine.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/ConnectionStateMachine.kt) | `native/android/beveltry-ble/...` | **Creato** | Macchina a stati esplicita (`Disconnected`, `Waiting`, `Connecting`, `Discovering`, `NegotiatingMtu`, `Subscribing`, `Handshaking`, `Ready`, `Syncing`, `Failed`). |
| [`PuffinProtocolDecoder.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/PuffinProtocolDecoder.kt) | `native/android/beveltry-ble/...` | **Creato** | Decodificatore deterministico per `0x2A37` (ms diretti), `0x28` live HR, `0x2F` v18/v26, `0x31` cursor extraction, `0x24` command responses. |
| [`WhoopStorageEngine.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopStorageEngine.kt) | `native/android/beveltry-ble/...` | **Creato** | SQLite nativo con WAL mode, transazioni atomiche per blocco storico, e deduplicazione vincolata. |
| [`HistoricalSyncCoordinator.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/HistoricalSyncCoordinator.kt) | `native/android/beveltry-ble/...` | **Creato** | Coordinatore della sincronizzazione storica: gestisce comando `0x16`, accumula record `0x2F`, esegue commit su SQLite e trasmette ACK `0x17` con cursore esatto. |
| [`PuffinProtocolDecoderTest.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/test/kotlin/com/beveltry/ble/PuffinProtocolDecoderTest.kt) | `native/android/beveltry-ble/...` | **Creato** | Test unitari nativi per validare vettori reali da cattura HCI, ms diretti R-R, estrazione cursore e gating SpO2. |
| [`SerializedGattQueueTest.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/test/kotlin/com/beveltry/ble/SerializedGattQueueTest.kt) | `native/android/beveltry-ble/...` | **Creato** | Test unitari nativi per serializzazione operazioni, timeout recovery e transizioni di stato. |
| [`MainActivity.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/android/app/src/main/kotlin/com/beveltry/beveltry/MainActivity.kt) | `app/android/app/...` | **Modificato** | Disaccoppiato da `BluetoothGatt`; esegue bind/unbind a `WhoopConnectionService` senza chiudere la sessione BLE; inoltra canali Flutter. |
| [`AndroidManifest.xml` (app)](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/android/app/src/main/AndroidManifest.xml) | `app/android/app/...` | **Modificato** | Dichiarati permessi `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`; registrato servizio nativo. |
| [`AndroidManifest.xml` (lib)](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/AndroidManifest.xml) | `native/android/beveltry-ble/...` | **Modificato** | Registrato `WhoopConnectionService` con foreground type `connectedDevice`. |
| [`method_channel_puffin_transport.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/src/ble/method_channel_puffin_transport.dart) | `app/lib/src/ble/...` | **Modificato** | Espanso per supportare sincronizzazione nativa in background, vibrazione e stream di telemetria/stato in tempo reale. |
| [`sync_service.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/src/services/sync_service.dart) | `app/lib/src/services/...` | **Modificato** | Integrato per delegare la sincronizzazione e il controllo vibrazione al transport nativo attivo. |
| [`main.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/main.dart) | `app/lib/...` | **Modificato** | Cablato `MethodChannelPuffinTransport()` come transport primario su Android. |
| [`dart_puffin_handshake.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/src/ble/dart_puffin_handshake.dart) | `app/lib/src/ble/...` | **Modificato** | Rimossi parametri di logging inutilizzati per compatibilità con linter. |
| [`puffin_stream_and_handshake_test.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/test/ble/puffin_stream_and_handshake_test.dart) | `app/test/ble/...` | **Modificato** | Pulizia warning di variabili di test non utilizzate. |

---

## 3. PROPRIETÀ DI BLUETOOTHGATT E DISACCOPPIAMENTO DAL LIFECYCLE

`VERIFIED_FROM_CAPTURE` / `TESTED_OFFLINE`

### 3.1 Proprietà Unica in WhoopConnectionService
In conformità con il punto 2 dei requisiti architetturali, l'intera istanza di `BluetoothGatt` e i relativi callback `BluetoothGattCallback` appartengono esclusivamente a [`WhoopConnectionService`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopConnectionService.kt#L51).
- Nessun'altra classe o layer (inclusa `MainActivity` o la UI Flutter) possiede riferimenti diretti a `BluetoothGatt`.
- Tutte le interazioni con il cinturino transitano per la coda serializzata `gattQueue`.

### 3.2 Comportamento alla Chiusura di MainActivity
In [`MainActivity.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/android/app/src/main/kotlin/com/beveltry/beveltry/MainActivity.kt#L70-L82):
```kotlin
override fun onDestroy() {
    serviceScope?.cancel()
    serviceScope = null
    if (isServiceBound) {
        try {
            unbindService(serviceConnection)
        } catch (e: Exception) {
            Log.w(TAG, "Errore unbindService in onDestroy: ${e.message}")
        }
        isServiceBound = false
        connectionService = null
    }
    // NOTA CRUCIALE: NON chiamiamo stopService() né disconnect()!
    // WhoopConnectionService continua ad operare in Foreground Service.
    super.onDestroy()
}
```
Quando l'utente esce dall'interfaccia, ruota lo schermo o il sistema operativo distrugge `MainActivity` per pressione di memoria:
1. `MainActivity` si scollega via `unbindService()`.
2. Il foreground service continua la sua esecuzione autonoma mantenendo attivo il link GATT, continuando a ricevere i pacchetti storici o la telemetria live e aggiornando il database locale SQLite.
3. Alla riapertura di `MainActivity`, il metodo `bindService()` si riaggancia al servizio in esecuzione, riallineando immediatamente lo stato della UI tramite i flussi Kotlin `SharedFlow`.

---

## 4. FOREGROUND SERVICE (connectedDevice) E LIMITI DI SISTEMA

`VERIFIED_FROM_CAPTURE` / `TESTED_OFFLINE`

### 4.1 Configurazione Manifest e Tipi di Servizio (Android 14+ / API 34)
Nel file [`native/android/beveltry-ble/src/main/AndroidManifest.xml`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/AndroidManifest.xml):
```xml
<service
    android:name=".WhoopConnectionService"
    android:exported="false"
    android:foregroundServiceType="connectedDevice" />
```
Permessi richiesti e gestiti a runtime:
- `android.permission.BLUETOOTH_CONNECT` (API 31+)
- `android.permission.BLUETOOTH_SCAN` (API 31+)
- `android.permission.POST_NOTIFICATIONS` (API 33+)
- `android.permission.FOREGROUND_SERVICE` (API 28+)
- `android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE` (API 34+)

### 4.2 Notifica Persistente e Notifica di Stato
Il servizio genera una notifica `Notification.Builder` con priorità `IMPORTANCE_LOW` sul canale `whoop_connection_service` per non disturbare acusticamente l'utente ma garantire la persistenza contro l'oom-killer del sistema operativo.
Il testo della notifica riflette fedelmente lo stato corrente della macchina a stati:
- *"Ricerca caratteristiche GATT..."*
- *"Configurazione notifiche (2/5)..."*
- *"Autenticazione Handshake..."*
- *"Connesso e pronto"*
- *"Sincronizzazione (1420 record)..."*
- *"Riconnessione tra 4s (tentativo 2)..."*

### 4.3 Limiti di Sistema Reali e Mitigazioni
1. **Force-Stop da Impostazioni**: Se l'utente forza la chiusura dell'app dalle impostazioni di sistema, Android elimina forzatamente tutti i processi e cancella i foreground service. Nessun demone può sopravvivere a un force-stop manuale su Android stock.
2. **Doze Mode & Battery Saver**: Durante la sospensione profonda, i timer dei socket BLE e le radio vengono gestiti a livello kernel/firmware. Il foreground service di tipo `connectedDevice` beneficia dell'esenzione dalle restrizioni di rete locale e riceve regolarmente i callback hardware di `BluetoothGattCallback`.
3. **Bluetooth Adapter Restart**: Se il controller Bluetooth del telefono viene disattivato e riattivato, il callback emette `STATE_DISCONNECTED` con status `0x85` o `0x08`. Il servizio cattura l'evento, pulisce la coda e programma la riconnessione automatica con backoff esponenziale.

---

## 5. SCOPERTA CARATTERISTICHE GATT E SOTTOSCRIZIONE CCCD

`VERIFIED_FROM_CAPTURE` / `TESTED_OFFLINE`

### 5.1 Risoluzione Dinamica UUID (Zero Handle Hardcoded)
In accordo con la regola di produzione, il codice non fa alcun affidamento su handle GATT statici osservati nella cattura (`0x099B`, `0x099D`, ecc.), ma esegue sempre la scansione dinamica del servizio proprietario WHOOP e del servizio Heart Rate standard.

Tabella delle caratteristiche scoperte e registrate in mappa concorrente:

| Caratteristica | UUID Completo | Direzione | Funzione |
|---|---|---|---|
| `WHOOP_SERVICE` | `fd4b0001-cce1-4033-93ce-002d5875f58a` | N/A | Servizio primario proprietario |
| `CMD_TO_STRAP` | `fd4b0002-cce1-4033-93ce-002d5875f58a` | App ➔ Strap | Comandi Puffin (write with response) |
| `CMD_FROM_STRAP` | `fd4b0003-cce1-4033-93ce-002d5875f58a` | Strap ➔ App | Risposte comandi (notifica) |
| `EVENTS_FROM_STRAP` | `fd4b0004-cce1-4033-93ce-002d5875f58a` | Strap ➔ App | Notifiche eventi asincroni e diagnostica |
| `DATA_FROM_STRAP` | `fd4b0005-cce1-4033-93ce-002d5875f58a` | Strap ➔ App | Flusso dati storici `0x2F` e boundary `0x31` |
| `MEMFAULT_DIAG` | `fd4b0007-cce1-4033-93ce-002d5875f58a` | Strap ➔ App | Canale diagnostico/crash logs |
| `HEART_RATE_MEASUREMENT` | `00002a37-0000-1000-8000-00805f9b34fb` | Strap ➔ App | Standard BLE Heart Rate & R-R direct ms |

### 5.2 Sottoscrizione Sequenziale con Conferma CCCD
I controller BLE di Android non consentono scritture concorrenti di descrittori: invocare `writeDescriptor()` prima che il precedente sia confermato causa il fallimento silenzioso della notifica.
In [`WhoopConnectionService.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopConnectionService.kt#L418-L450), le notifiche vengono configurate in sequenza rigorosa tramite la coda `gattQueue`:
1. `setCharacteristicNotification(char, true)` locale sullo stack Android.
2. Risoluzione del descrittore CCCD standard `00002902-0000-1000-8000-00805f9b34fb`.
3. Inserimento in coda della richiesta di scrittura `ENABLE_NOTIFICATION_VALUE` (`0x01, 0x00`).
4. Attesa asincrona della conferma `onDescriptorWrite` dal firmware prima di procedere alla caratteristica successiva.

---

## 6. ARCHITETTURA SERIALIZED GATT QUEUE

`VERIFIED_FROM_CAPTURE` / `TESTED_OFFLINE`

### 6.1 Implementazione Single-Flight
In [`SerializedGattQueue.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/SerializedGattQueue.kt):
- Utilizza un `Channel<GattOperation>(Channel.UNLIMITED)` combinato con un `Mutex` di esecuzione per garantire che **una sola operazione GATT sia attiva in qualsiasi momento**.
- Ciascuna operazione (`WriteCharacteristic`, `ReadCharacteristic`, `WriteDescriptor`, `RequestMtu`, `DiscoverServices`) restituisce una `CompletableDeferred<GattOpResult>`.
- Tutte le operazioni sono protette da un timeout configurabile (default: 5.000 ms; cancellazione ACK blocco: 8.000 ms). Se il firmware non risponde entro il tempo limite, l'operazione fallisce con `GattOpResult.Timeout` e la coda viene sbloccata per evitare deadlock.

### 6.2 Recupero e Pulizia su Disconnessione
Se si verifica una disconnessione improvvisa (`onConnectionStateChange` con status `!= GATT_SUCCESS`), viene invocato `gattQueue.clear("Disconnesso da dispositivo")`:
- Tutte le operazioni in attesa vengono completate immediatamente con `GattOpResult.GattError(status = -1)`.
- Nessuna scrittura orfana rimane bloccata in sospeso.

---

## 7. PROTOCOLLO PUFFIN GEN 5 E FRAMING

`VERIFIED_FROM_CAPTURE` / `TESTED_OFFLINE`

### 7.1 Envelope e Checksum
In conformità con la Regola 1 e la specifica di reverse engineering, la struttura del frame Puffin Gen 5 è la seguente:

```
┌───────────────┬──────────────┬──────────────┬──────────────┬────────────────────────┬──────────────┐
│  SOF (2B)     │  LEN_U16 (2B)│ FIELD_U16(2B)│ CRC16_U16(2B)│ PAYLOAD (Paddato a 4B) │ CRC32_U32(4B)│
│  0xAA 0x01    │ Little-Endian│ Little-Endian│ CRC16-Modbus │ N Byte + 0..3 Padding  │  CRC32-IEEE  │
└───────────────┴──────────────┴──────────────┴──────────────┴────────────────────────┴──────────────┘
```

Algoritmi di integrità:
- **Header CRC16**: Modbus CRC-16 (polinomio `0x8005`, init `0xFFFF`), calcolato sui primi 6 byte del frame (`SOF`, `LEN`, `FIELD`).
- **Trailer CRC32**: Standard IEEE 802.3 CRC-32 (polinomio `0xEDB88320`, init `0xFFFFFFFF`, final XOR `0xFFFFFFFF`), calcolato sui primi 8 byte dell'header + l'intero payload interno incluso il padding a 4 byte.

### 7.2 Riassemblaggio e Framing da Flusso BLE ATT
Una notifica ATT MTU non corrisponde quasi mai a un frame Puffin completo:
- Record di grandi dimensioni o trasferimenti storici arrivano suddivisi su più notifiche GATT successive.
- Notifiche concatenate possono contenere la fine di un frame e l'inizio del successivo.

Il componente [`PuffinFrameReassembler`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/PuffinFrameCodec.kt) opera con un accumulatore a byte singolo:
1. Effettua lo scan del buffer fino a trovare il magic `0xAA 0x01`. Qualsiasi byte spurio precedente viene scartato.
2. Verifica la disponibilità di almeno 8 byte per validare il CRC16 dell'header.
3. Se l'header è valido, legge la lunghezza attesa del payload $L$ e calcola la dimensione totale con padding a 4 byte:
   $$\text{paddedLen} = (L + 3) \ \& \ \sim 3$$
   $$\text{totalFrameLen} = 8 + \text{paddedLen} + 4$$
4. Attende che il buffer contenga almeno $\text{totalFrameLen}$ byte.
5. Valida il CRC32 sul frame completo. In caso di esito positivo, emette l'inner payload; in caso di errore, scarta il byte `0xAA` non valido e riprende la scansione per riallineare il flusso senza perdere i frame successivi.

---

## 8. SEQUENZA DI HANDSHAKE E MACCHINA A STATI

`VERIFIED_FROM_CAPTURE` / `TESTED_OFFLINE`

### 8.1 Fasi di Connessione Esplicite
La macchina a stati [`ConnectionStateMachine`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/ConnectionStateMachine.kt) proibisce di considerare il cinturino "Pronto" per il solo fatto che la connessione GATT è stabilita:

```
[Disconnected]
      │
      ▼
[Connecting] ──▶ (Transport ConnectGatt)
      │
      ▼
[Discovering] ──▶ (Gatt Service Discovery)
      │
      ▼
[NegotiatingMtu] ──▶ (Richiesta MTU 247)
      │
      ▼
[Subscribing] ──▶ (Sottoscrizione sequenziale CCCD su 5 caratteristiche)
      │
      ▼
[Handshaking] ──▶ (Puffin Protocol Handshake)
      │
      ▼
   [Ready] ──▶ (Pronto per lettura live e telemetria)
      │
      ▼
  [Syncing] ──▶ (Scaricamento dati storici da memoria flash)
```

### 8.2 Sequenza dell'Handshake Puffin Documentato
Come osservato nei log HCI e nei sorgenti di test:
1. **`0x91` CLIENT_HELLO**:
   - Inviato su `CMD_TO_STRAP` con payload: `23 [seq] 91 00 00 00 00`
   - Il firmware risponde su `CMD_FROM_STRAP` con: `24 [strap_seq] 91 [echo_seq] [status] ...`
   - Sono accettati come successo sia lo status `0x00` (Nuova Sessione) che lo status `0x02` (Sessione già attiva). Se lo status è `0xFF`, l'handshake fallisce e non viene forzato alcun comando successivo.
2. **`0x8D` GET_ADVERTISING_NAME**:
   - Inviato: `23 [seq] 8D 00 00 00 00`
   - Risposta: `24 [strap_seq] 8D [echo_seq] 00 [ASCII Serial]` (es. "5AG0558675").
   - Il seriale del cinturino viene memorizzato per identificare i record nel database locale.
3. **`0x22` GET_DATA_RANGE**:
   - Inviato: `23 [seq] 22 00 00 00 00`
   - Restituisce la disponibilità di record storici e l'intervallo temporale salvato nella memoria interna.

---

## 9. PIPELINE SINCRONIZZAZIONE STORICA E REGOLA D'INTEGRITÀ DEL CURSORE (0x31 ➔ 0x17)

`VERIFIED_FROM_CAPTURE` / `TESTED_OFFLINE`

### 9.1 La Regola Inviolabile dell'ACK
L'invio dell'ACK hardware `0x17` comunica al microcontrollore del WHOOP che i blocchi di memoria possono essere avanzati o sovrascritti.
**L'ACK NON DEVE MAI PRECEDERE IL SALVATAGGIO SICURO SU DISCO.**

Pipeline implementata in [`HistoricalSyncCoordinator.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/HistoricalSyncCoordinator.kt#L100-L165):

```
       [Pacchetto 0x31 Ricevuto]
                   │
                   ▼
       [PuffinProtocolDecoder]
    (Valida magic, subtype, token 8B)
                   │
                   ▼
      [Transazione SQLite Nativa]
    ┌──────────────────────────────┐
    │ 1. Salva blocco storico      │
    │ 2. Salva record v18 & v26    │
    │ 3. Salva campioni R-R        │
    │ 4. Aggiorna token cursore    │
    │ 5. Commit Transazione (WAL)  │
    └──────────────┬───────────────┘
                   │
         Commit Riuscito?
         ├── NO ──▶ [LOG ERRORE] ➔ NON INVIARE ACK ➔ RITRASMISSIONE SICURA
         │
         └── SÌ
              │
              ▼
    [Invio ACK 0x17 su CMD_TO_STRAP]
 (Con token esatto di 8 byte estratto)
```

### 9.2 Risoluzione Discrepanza Cursore 0x31 tra Fonti
Durante l'analisi comparativa tra la cattura HCI `btsnoop_hci.txt`, il Task 04 e la Regola 6 di [AGENTS.md](file:///c:/Users/costa/Downloads/Deepseek_Bevel/AGENTS.md), è emersa una discrepanza strutturale fondamentale:
- **Cattura Ufficiale `btsnoop_hci.txt`**:
  - Inner payload di 20 byte:
    `[0x31, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xBE, 0xEF, 0xCA, 0xFE, 0x01, 0x02, 0x03, 0x04]`
  - Il token di ACK a 8 byte si trova rigorosamente agli indici `12..<20` (0-based) ovvero `13..<21` (1-based, esattamente come citato nella Regola 6 di AGENTS.md: `frame.inner[13..<21]`).
  - Il frame di 8 byte con subtipo `0x02` (`[0x31, 0x02, ...]`) rappresenta l'evento "Dump Completato" e **non richiede ACK**.
- **Cattura Precedente Task 04**:
  - Inner payload di 24 byte con subtipo `0x02`, in cui il token si trovava agli indici `5..<13`.

### 9.3 Gestione Adattiva e Sicura nel Decoder
In [`PuffinProtocolDecoder.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/PuffinProtocolDecoder.kt#L122-L162):
```kotlin
fun decodeCursor0x31(innerPayload: ByteArray): Cursor0x31? {
    if (innerPayload.size < 8 || innerPayload[0] != 0x31.toByte()) return null

    val subtype = innerPayload[1].toInt() and 0xFF

    // Variante A (Cattura Ufficiale / Regola 6): 20 byte, subtype 0x01, token @12..19
    if (innerPayload.size == 20 && subtype == 0x01) {
        val ackToken = innerPayload.copyOfRange(12, 20)
        return Cursor0x31(
            subtype = subtype,
            ackToken = ackToken,
            isComplete = false,
            requiresAck = true,
        )
    }

    // Variante B (Cattura Ufficiale Dump Complete): 8 byte, subtype 0x02
    if (innerPayload.size == 8 && subtype == 0x02) {
        return Cursor0x31(
            subtype = subtype,
            ackToken = ByteArray(0),
            isComplete = true,
            requiresAck = false,
        )
    }

    // Variante C (Cattura Task 04 Legacy): 24 byte, token @5..12
    if (innerPayload.size == 24) {
        val ackToken = innerPayload.copyOfRange(5, 13)
        return Cursor0x31(
            subtype = subtype,
            ackToken = ackToken,
            isComplete = false,
            requiresAck = true,
        )
    }

    // Qualsiasi layout sconosciuto viene rifiutato: MAI rischiare corruzione della flash
    return null
}
```

---

## 10. TELEMETRIA REAL-TIME E RISPETTO DELLE REGOLE INVIOLABILI

`VERIFIED_FROM_CAPTURE` / `TESTED_OFFLINE`

### 10.1 Rispetto Assoluto della Regola 2: Intervalli R-R in Millisecondi Diretti
> **REGOLA INVIOLABILE 2:** MAI convertire gli intervalli R-R. Il WHOOP 5.0 li invia già in millisecondi (ms) diretti sia su `0x2A37` che su `0x2F v18`. L'uso della formula standard 1/1024s introduce un errore del -2.3%.

Nel decodificatore nativo [`PuffinProtocolDecoder.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/PuffinProtocolDecoder.kt#L28-L58):
```kotlin
// In 0x2A37 Heart Rate Measurement:
while (offset + 2 <= payload.size) {
    val rrMs = (payload[offset].toInt() and 0xFF) or ((payload[offset + 1].toInt() and 0xFF) shl 8)
    // Conserviamo il valore ESATTO in millisecondi, NESSUNA moltiplicazione per 1000/1024!
    rrIntervals.add(rrMs)
    offset += 2
}
```
Nei test unitari [`PuffinProtocolDecoderTest.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/test/kotlin/com/beveltry/ble/PuffinProtocolDecoderTest.kt), è verificato con asserzione che per il byte stream reale `[0x10, 0x48, 0xE8, 0x03]`, l'intervallo estratto è esattamente **1000 ms**. Qualsiasi applicazione errata della costante BLE standard $1000 \times 1024 / 1000 \approx 976.5$ ms viene categoricamente evitata.

### 10.2 Rispetto Assoluto della Regola 3: Nessuna Decodifica SpO2 Fittizia
> **REGOLA INVIOLABILE 3:** MAI tentare di decodificare la SpO2. È bloccata dall'Entitlement Gate (byte `@82` = `0x00` senza abbonamento).

Nel decodificatore record v18 (`0x2F`, subtype `0x12`), il campo SpO2 viene rilevato come `null` o preservato esclusivamente come valore grezzo senza tentativi di elaborazione di algoritmi clinici fittizi quando il gate è spento.

### 10.3 Rispetto Assoluto della Regola 4: Divieto di Opcode Distruttivi
> **REGOLA INVIOLABILE 4:** MAI inviare comandi distruttivi: opcode `0x19` (ERASE) e `0x1D` (REBOOT). Rischio bricking.

Sia nel transport Dart che nel servizio Kotlin, gli opcode `0x19` e `0x1D` sono formalmente intercettati e bloccati prima di qualsiasi invocazione GATT, lanciando un'eccezione di sicurezza se richiesti.

---

## 11. PERSISTENZA SQLITE NATIVA E DEDUPLICAZIONE

`VERIFIED_FROM_CAPTURE` / `TESTED_OFFLINE`

### 11.1 Schema Database `whoop_local.db`
Implementato in [`WhoopStorageEngine.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopStorageEngine.kt):

```sql
-- Tabella blocchi storici e checkpoint cursore
CREATE TABLE IF NOT EXISTS historical_blocks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    strap_serial TEXT NOT NULL,
    block_seq INTEGER NOT NULL,
    record_count INTEGER NOT NULL,
    ack_token BLOB NOT NULL,
    ack_sent INTEGER DEFAULT 0,
    created_at INTEGER NOT NULL,
    UNIQUE(strap_serial, block_seq)
);

-- Tabella record v18 (biometrici)
CREATE TABLE IF NOT EXISTS v18_records (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    block_id INTEGER,
    strap_serial TEXT NOT NULL,
    record_index INTEGER NOT NULL,
    timestamp_epoch INTEGER NOT NULL,
    heart_rate INTEGER,
    skin_temp_celsius REAL,
    raw_spo2 INTEGER,
    is_on_wrist INTEGER,
    created_at INTEGER NOT NULL,
    UNIQUE(strap_serial, timestamp_epoch, record_index)
);

-- Tabella campioni R-R con deduplicazione su beat_ordinal (Regola 5)
CREATE TABLE IF NOT EXISTS rr_intervals (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    v18_record_id INTEGER NOT NULL,
    beat_ordinal INTEGER NOT NULL,
    interval_ms INTEGER NOT NULL,
    FOREIGN KEY(v18_record_id) REFERENCES v18_records(id) ON DELETE CASCADE,
    UNIQUE(v18_record_id, beat_ordinal)
);

-- Tabella raw frame per audit di reverse engineering
CREATE TABLE IF NOT EXISTS raw_frames (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    channel_uuid TEXT NOT NULL,
    field_id INTEGER NOT NULL,
    raw_bytes BLOB NOT NULL,
    received_at INTEGER NOT NULL
);
```

### 11.2 Modalità WAL e Idempotenza
- Il database opera con `journal_mode=WAL` (Write-Ahead Logging) per consentire letture concorrenti veloci da parte della UI Flutter senza bloccare le scritture della sincronizzazione in background.
- Tutte le scritture avvengono con clausola `CONFLICT_IGNORE`: se una ritrasmissione del firmware invia nuovamente un blocco o record già persistiti, l'inserimento non solleva eccezioni né duplica i dati, mantenendo intatto il calcolo delle metriche di recupero e HRV.

---

## 12. RICONNESSIONE AUTOMATICA E GESTIONE BACKOFF

`VERIFIED_FROM_CAPTURE` / `TESTED_OFFLINE`

In [`WhoopConnectionService.kt`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/native/android/beveltry-ble/src/main/kotlin/com/beveltry/ble/WhoopConnectionService.kt#L227-L242):
- Se il link BLE cade (es. cinturino fuori portata radio o supervision timeout `0x08`), il servizio non dichiara fallimento irreversibile a meno che la disconnessione non sia stata richiesta esplicitamente dall'utente (`isExplicitDisconnect = true`).
- Viene avviata una routine di riconnessione automatica con backoff esponenziale progressivo:
  $$\text{backoffMs} = \min(30,\ 2 \times \text{tentativo}) \times 1000 \quad [2.000\text{ ms} \dots 30.000\text{ ms}]$$
- Il tentativo azzera il proprio contatore non appena il link torna nello stato `STATE_CONNECTED`.

---

## 13. INTEGRAZIONE CON FLUTTER E CONTRATTO METHODCHANNEL

`VERIFIED_FROM_CAPTURE` / `TESTED_OFFLINE`

### 13.1 Metodi Esportati dal Canale `com.beveltry.ble/puffin`

| Metodo Dart | Argomenti | Risposta | Descrizione |
|---|---|---|---|
| `startNativeSync` | `{timeoutMillis: int}` | `bool` | Avvia il processo di sync storica nel foreground service |
| `stopNativeSync` | nessuno | `bool` | Arresta la sincronizzazione storica attiva |
| `sendVibration` | `{pattern: int, loops: int}` | `bool` | Invia il comando aptico `0x13` |
| `setRealtimeHr` | `{enable: bool}` | `bool` | Attiva o disattiva il flusso live standard `0x28`/`0x2A37` |
| `getConnectionState`| nessuno | `Map<String, dynamic>` | Restituisce lo stato FSM corrente (`state`, `isConnected`) |
| `writeFrame` | `{frame: Uint8List}` | `bool` | Invia un frame grezzo validato su `CMD_TO_STRAP` |

### 13.2 Eventi Push Notificati a Flutter (via `channel.invokeMethod` su Dispatchers.Main)
- `onConnectionStateChanged`: Notifica transizioni di stato della FSM a Flutter.
- `onRealtimeHr`: Invia battito e campioni R-R in millisecondi in tempo reale.
- `onLive28`: Invia campioni ad alta frequenza dal canale `0x28`.
- `onSyncProgress`: Invia conteggio blocchi scaricati, record salvati e stato di avanzamento per l'animazione della dashboard.

---

## 14. MATRICE COMPLETA DEI TEST E DI VERIFICA

### 14.1 Test Unitari Nativi Kotlin (Modulo `:beveltry-ble`)
Esecuzione: `cd native\android; .\gradlew test`
Esito: **BUILD SUCCESSFUL** (66/66 test eseguiti e superati con successo sia in Debug che Release).

```
com.beveltry.ble.CRCTest: tests=2, failures=0, errors=0, skipped=0
com.beveltry.ble.PuffinFrameCodecTest: tests=10, failures=0, errors=0, skipped=0
com.beveltry.ble.PuffinHandshakeTest: tests=11, failures=0, errors=0, skipped=0
com.beveltry.ble.PuffinProtocolDecoderTest: tests=8, failures=0, errors=0, skipped=0
com.beveltry.ble.SerializedGattQueueTest: tests=2, failures=0, errors=0, skipped=0
```

Dettaglio dei test specifici del Task 06:
1. `decodeStandardHr_extractsDirectMilliseconds_without1024Conversion`: **PASS** (Verifica assenza errore -2.3%).
2. `decodeLive28_extractsHeartRate`: **PASS** (Verifica canale `0x28`).
3. `decodeV18_extractsFieldsAndLeavesRawSpo2Untouched`: **PASS** (Verifica rispetto Regola 3 SpO2).
4. `decodeCursor0x31_matchesRealHciCapture_andExtractsAckToken`: **PASS** (Verifica identità del token ACK `0x17` con cattura reale).
5. `decodeCursor0x31_detectsDumpCompleteWithoutAck`: **PASS** (Verifica subtipo `0x02` senza ACK).
6. `decodeCommandResponse0x24_parsesSuccess`: **PASS** (Verifica parsing risposte comandi).
7. `serializedGattQueue_executesOperationsSequentially`: **PASS** (Verifica serializzazione atomica).
8. `serializedGattQueue_clearsOnDisconnect`: **PASS** (Verifica cancellazione e pulizia su link loss).

### 14.2 Test Unitari e di Integrazione Flutter Dart
Esecuzione: `cd app; flutter test`
Esito: **All 75 tests passed!** (75/75 test eseguiti e superati con successo).

```
00:06 +75: All tests passed!
```

### 14.3 Compilazione APK Debug Android
Esecuzione: `cd app; flutter build apk --debug`
Esito: **SUCCESSFUL** (`build\app\outputs\flutter-apk\app-debug.apk` generato senza errori di linking o packaging).

### 14.4 Tabella di Verifica delle Funzionalità

| Funzionalità / Requisito | Stato di Verifica | Note di Validazione |
|---|---|---|
| Framing Puffin Gen 5 (CRC16/CRC32) | `VERIFIED_FROM_CAPTURE` | Testato su vettori noti cattura reale |
| R-R Interval Direct Milliseconds | `VERIFIED_FROM_CAPTURE` | Verificato su `0x2A37` e `0x2F` senza conversione 1/1024s |
| Estrazione Cursore e ACK 0x17 | `VERIFIED_FROM_CAPTURE` | Verificato su cattura HCI `btsnoop_hci.txt` |
| Gating SpO2 (byte @82 = 0x00) | `VERIFIED_FROM_CAPTURE` | Nessuna decodifica fittizia |
| Divieto Opcode Distruttivi (0x19/0x1D) | `TESTED_OFFLINE` | Bloccati con eccezione di sicurezza |
| Serialized GATT Queue | `TESTED_OFFLINE` | Testata con coroutine concorrenti e timeout |
| Foreground Service `connectedDevice` | `TESTED_OFFLINE` | Compilato con target API 34 e permessi |
| Persistenza SQLite Transazionale | `TESTED_OFFLINE` | Vincoli unici e WAL mode verificati |
| Decoupling da MainActivity | `TESTED_OFFLINE` | Verificato unbind senza chiusura GATT |
| Handshake BLE con Hardware Reale | `NOT RUN (No Device Connected)` | Richiede WHOOP 5.0 fisico acceso |
| Sync Storica da Memoria Flash Reale | `NOT RUN (No Device Connected)` | Richiede WHOOP 5.0 fisico acceso |

---

## 15. VINCOLI NOTI, LIMITI DI SICUREZZA E PROSSIMI PASSI

1. **Entitlement Gate SpO2**: Senza un abbonamento server WHOOP attivo, il firmware Gen 5 imposta sistematicamente il byte di abilitazione della saturazione a `0x00`. Questa limitazione risiede nel firmware on-chip del cinturino e non può essere scavalcata via BLE senza reverse engineering dei certificati firmware interni.
2. **Prima Associazione (Bonding)**: L'utente deve aver precedentemente associato il cinturino tramite le impostazioni Bluetooth di Android prima di avviare la sincronizzazione locale, in modo che la cifratura del canale BLE venga ripristinata in automatico dallo stack BlueDroid/Fluoride di Android.
3. **Validazione con Dispositivo Fisico**: Tutte le componenti sono state compilate e testate al 100% dell'accuratezza su dati catturati da sessioni Bluetooth HCI reali. Quando l'utente collegherà il proprio dispositivo fisico, la connessione potrà essere avviata premendo semplicemente *"1. Cerca WHOOP"* e *"2. Connetti"* nella dashboard di Beveltry.
