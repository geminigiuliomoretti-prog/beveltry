# TASK 08A — BEVELTRY SLEEP LAB: FONDAMENTA E ANALISI NOTTURNA
## Rapporto Tecnico e Risultati di Implementazione

**Data:** 10 Novembre 2026  
**Branch Git:** `feature/sleep-lab-v1`  
**Checkpoint di Base:** Tag Git `night-recorder-v1` (Commit `56f4d19`)  
**Stato Build APK:** Compilato con successo (`app/build/app/outputs/flutter-apk/app-debug.apk`)  
**Suite di Test:** 109 test superati su 109 (100% PASS)  
**Analisi Statica:** 0 errori, 0 avvisi (`flutter analyze` pulito)  

---

## 1. File Modificati e Creati

### 1.1 Nuovi Moduli Beveltry Sleep Lab (`app/lib/src/sleep_lab/`)
- [`epoch_engine.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/src/sleep_lab/epoch_engine.dart): Motore deterministico di epoche da 30 secondi. Gestisce orari UTC, fuso locale, ricostruzione temporale fisiologica dei battiti R-R, calcolo di HR media/mediana/variabilità/pendenza, copertura campioni e flag di qualità (`EpochQualityFlag`).
- [`cardiac_sleep_wake_estimator.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/src/sleep_lab/cardiac_sleep_wake_estimator.dart): Stimatore sperimentale di sonno e veglia v1.0.0 basato esclusivamente sulla fisiologia cardiaca. Calcola la probabilità continua per epoca, la latenza di addormentamento, inizio sonno (Sleep Onset), risveglio finale (Sleep Offset), risvegli intermedi (WASO), durata totale del sonno (TST) ed efficienza. Include il supporto alla correzione manuale dei confini.
- [`hrv_window_lab.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/src/sleep_lab/hrv_window_lab.dart): Laboratorio comparativo delle finestre HRV. Calcola l'RMSSD segmentato gap-aware sull'intero intervallo di sonno (ms diretti e conversione SIG 1024), la distribuzione statistica delle finestre mobili da 5 minuti (mediana, media, min, max) e predispone i 5 candidati Deep/SWS (bloccati su `UNAVAILABLE` in assenza di stadiazione validata).
- [`respiration_and_rhr.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/src/sleep_lab/respiration_and_rhr.dart): Calcolo di RHR (minimo mobile su 5 minuti e media notturna) e stimatore sperimentale della frequenza respiratoria basato sull'Aritmia Sinusale Respiratoria (RSA) tramite trasformata spettrale su finestre continue da 4 minuti con filtro SNR $\ge 2.0$.
- [`whoop_a_comparison.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/src/sleep_lab/whoop_a_comparison.dart): Modello persistente per l'acquisizione dei dati ufficiali del cinturino WHOOP A e calcolo differenziale rigoroso limitato alle sole metriche scientificamente comparabili.
- [`sleep_lab_models.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/src/sleep_lab/sleep_lab_models.dart): Modello aggregatore principale (`SleepLabAnalysis`) e metriche aggregate di integrità del segnale (`SleepLabDataQuality`).
- [`sleep_lab_service.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/src/sleep_lab/sleep_lab_service.dart): Servizio orchestratore che interroga SQLite, esegue l'intera pipeline downstream senza toccare il Night Recorder, gestisce la persistenza dei confini manuali e dei record di confronto.

### 1.2 Interfaccia Grafica Flutter (`app/lib/screens/`)
- [`sleep_lab_screen.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/screens/sleep_lab_screen.dart): Schermata completa Sleep Lab con selettore notti, riepilogo confini sonno, correzione orari a mano, grafico CustomPainter FC con sovrimpressione sonno/veglia, card stadiazione (con avviso esplicito UNAVAILABLE), card HRV Window Lab, RHR e respirazione RSA, indicatori di qualità segnale e tabella di verifica incrociata con WHOOP A.
- [`dashboard_screen.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/screens/dashboard_screen.dart): Aggiunti pulsante rapido nella AppBar e banner violetto dedicato a *Beveltry Sleep Lab (Task 08A)*.
- [`night_recorder_screen.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/screens/night_recorder_screen.dart): Aggiunti pulsante nella AppBar e bottone d'azione rapido *"Apri in Beveltry Sleep Lab"* al termine della registrazione o alla visualizzazione del report.

### 1.3 Persistenza e Database (`app/lib/src/`)
- [`whoop_database.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/src/database/whoop_database.dart): Migrazione idempotente e non distruttiva (`CREATE TABLE IF NOT EXISTS`) per `whoop_a_comparisons` e `sleep_lab_manual_boundaries`, invocata sia in creazione che in apertura (`_onOpen`).
- [`whoop_repository.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/lib/src/repository/whoop_repository.dart): Metodi per estrarre campioni HR e battiti RR grezzi di sessione, salvare e recuperare confini sonno manuali e memorizzare i confronti WHOOP A.

### 1.4 Suite di Test Unitari e Regressione (`app/test/`)
- [`epoch_engine_test.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/test/sleep_lab/epoch_engine_test.dart): Test per determinismo, attraversamento della mezzanotte, ricostruzione fisiologica RR multipli, epoche incomplete e flag di qualità.
- [`cardiac_sleep_wake_estimator_test.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/test/sleep_lab/cardiac_sleep_wake_estimator_test.dart): Test per probabilità continue, latenza di addormentamento, differenziazione WASO vs risveglio finale, efficienza e override manuale.
- [`hrv_window_lab_test.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/test/sleep_lab/hrv_window_lab_test.dart): Test per RMSSD intero sonno (diretto e 1024), finestre da 5 minuti, indisponibilità candidati Deep e calcolo condizionato con maschera SWS.
- [`respiration_and_rhr_test.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/test/sleep_lab/respiration_and_rhr_test.dart): Test per RHR minimo mobile, rivelazione frequenza sinusoidale RSA a 15 RPM, gestione dati rumorosi e determinismo.
- [`whoop_a_comparison_test.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/test/sleep_lab/whoop_a_comparison_test.dart): Test per serializzazione SQLite e calcolo deltas su sole grandezze comparabili.
- [`sleep_lab_service_and_db_test.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/test/sleep_lab/sleep_lab_service_and_db_test.dart): Test d'integrazione SQLite in-memory della pipeline completa e consistenza ripetuta.
- [`sleep_lab_regression_real_data_test.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/test/sleep_lab/sleep_lab_regression_real_data_test.dart): Regressione automatica sul dataset reale `exports/whoop_local.db` acquisito dal cinturino WHOOP B.
- [`sleep_lab_screen_test.dart`](file:///c:/Users/costa/Downloads/Deepseek_Bevel/app/test/screens/sleep_lab_screen_test.dart): Test widget del rendering grafico, stato vuoto e stato con sessione attiva.

---

## 2. Audit dei Segnali Disponibili

Dall'ispezione del codice e dall'analisi del database reale della notte 9–10 Novembre 2026 (`night_1794264340726`):

| Segnale / Sensore | Disponibilità Reale WHOOP B | Origine / Canale | Note Tecniche |
|---|---|---|---|
| **Frequenza Cardiaca (HR)** | **DISPONIBILE (100%)** | BLE GATT standard `0x2A37` | 32.701 campioni su 32.701,8 s (99,997% copertura). Frequenza nominale 1 Hz. |
| **Intervalli R-R** | **DISPONIBILE (83,9%)** | BLE GATT standard `0x2A37` | 27.424 intervalli R-R grezzi. Valori inviati già in millisecondi diretti (Regola Inviolabile 2). 27.421 battiti fisiologici [300, 2000] ms (99,989%). |
| **RR Multipli per Notifica** | **DISPONIBILE** | `0x2A37` byte offset | 26.728 notifiche con 1 RR, 343 con 2 RR, 2 con 3 RR, 1 con 4 RR. Ricostruzione fisiologica arretrata completata. |
| **Contatto Sensore** | **NON DISPONIBILE (-1)** | `0x2A37` flag bit 1-2 | Il firmware WHOOP 5.0 imposta `sensor_contact = -1` (funzionalità non supportata sul servizio standard). |
| **Accelerometro Triassiale** | **NON DISPONIBILE** | Puffin `0x2F v18` | Hardware presente fisicamente, ma non accessibile sul canale GATT standard 0x2A37. Richiede offload autenticato Puffin. |
| **Giroscopio** | **NON DISPONIBILE** | Puffin proprietario | Idem. Non trasmesso su GATT standard. |
| **Forma d'Onda Ottica (PPG)** | **NON DISPONIBILE** | Puffin `0x26` | Disponibile solo tramite sottoscrizione proprietaria a 24 Hz, non attiva durante la notte standard. |
| **Temperatura Cutanea** | **NON DISPONIBILE** | Puffin `0x2F v18` | Presente solo nei pacchetti storici v18 autenticati. |
| **SpO2 (Ossimetria)** | **BLOCCATA** | Hardware / Firmware | Bloccata dall'Entitlement Gate (byte `@82` = `0x00`). Regola Inviolabile 3. |

---

## 3. Metriche Funzionanti (`MEASURED` ed `ESTIMATED`)

Tutte le metriche sotto indicate sono calcolate in modo trasparente e riproducibile a partire dai dati registrati:

1. **Epoche deterministiche da 30 secondi:** 1.091 epoche calcolate per la notte reale, con 1.090 epoche utilizzabili (99,9% utilizzabilità).
2. **Ricostruzione orario fisiologico battiti:** Arretramento temporale deterministico dei battiti appartenenti a notifiche aggregate (`t_beat = t_notif - sum(rr_successivi)`).
3. **Inizio e Fine Sonno:** Individuati tramite filtro logistico e transizione continua di 10 epoche stabili.
4. **Durata Sonno (TST) e Veglia (WASO):** Somma delle epoche classificate nell'intervallo effettivo.
5. **Efficienza del Sonno:** Rapporto deterministico $TST / (TST + WASO) \times 100$.
6. **Conteggio Risvegli Intermedi:** Transizioni contigue veglia all'interno dell'intervallo di sonno.
7. **Latenza di Addormentamento:** Tempo trascorso tra l'inizio registrazione e l'onset del sonno.
8. **HRV RMSSD Intero Sonno (ms diretti):** 98,6 ms calcolati con segmentazione gap-aware (Task Force 1996, nessuna unione di lacune).
9. **HRV RMSSD Intero Sonno (standard SIG 1024):** 96,3 ms ($RMSSD \times 1000 / 1024$).
10. **HRV Finestre Mobili 5 Minuti (Rolling Window):** 338 finestre valutate; mediana, media, minimo e massimo calcolati rigorosamente.
11. **RHR Minimo su 5 Minuti (`MEASURED`):** 48 BPM (minimo della media mobile su 300 campioni validi).
12. **RHR Media su Tutto il Sonno (`MEASURED`):** 54,8 BPM.
13. **Percentuale di Copertura Temporale:** 99,997%.
14. **Confronto Incrociato WHOOP A:** Schermata per inserimento manuale e tabella automatica di scostamento delta.
15. **Correzione Manuale Confini Sonno:** Permette di testare l'impatto di onset/offset personalizzati senza alterare i dati nel database.

---

## 4. Metriche Sperimentali (`EXPERIMENTAL` ed `EXPERIMENTAL_CARDIAC_ONLY`)

1. **Sleep/Wake v1 (`EXPERIMENTAL_CARDIAC_ONLY`):**
   - Modello di classificazione sonno/veglia a 30 secondi basato unicamente su:
     - Scostamento FC rispetto al 20° percentile basale ($HR_{elev}$).
     - Deviazione standard FC nell'epoca ($HR_{std}$).
     - Pendenza lineare istantanea ($HR_{slope}$).
     - Smoothing bilaterale a 5 epoche (2,5 minuti).
   - È esplicitamente etichettato `EXPERIMENTAL_CARDIAC_ONLY` per evidenziare l'assenza di dati cinetici (accelerometro).
2. **Frequenza Respiratoria Notturna RSA (`EXPERIMENTAL`):**
   - Stima basata sulla modulazione ciclica del battito cardiaco indotta dal respiro (Aritmia Sinusale Respiratoria).
   - Finestre mobili da 4 minuti (240 s) ricampionate a 4 Hz su griglia uniforme.
   - Analisi di potenza DFT nella banda respiratoria fisiologica [0,15 Hz – 0,45 Hz] (9 – 27 RPM).
   - Controllo qualità rigido: $SNR = P_{peak} / P_{mean} \ge 2.0$, almeno 120 battiti per finestra e nessuna lacuna $> 3,0$ s.
   - Risultato sul dataset reale: **13,5 RPM** mediana notturna con 338 finestre valide su 338.

---

## 5. Metriche Non Disponibili (`UNAVAILABLE`) e Motivazione Scientifica

In conformità ai requisiti etici e scientifici di Beveltry, **nessuna metrica viene simulata con formule fittizie o percentuali arbitrarie**:

| Metrica | Stato | Motivazione Scientifica Rigorosa |
|---|---|---|
| **Fasi Light / Deep / REM** | `UNAVAILABLE` | La stadiazione in 4 stadi richiede un modello combinato di accelerometria multiasse e fotopletismografia ottica PPG (previsto per TASK 08B). Non sono state applicate percentuali inventate. |
| **HRV SWS B2 (`rmssd_all_deep`)** | `UNAVAILABLE` | Dipende dall'identificazione comprovata di tutte le epoche Deep. |
| **HRV SWS B3 (`rmssd_last_deep_episode`)** | `UNAVAILABLE` | Dipende dall'identificazione dell'ultimo episodio Deep. |
| **HRV SWS B4 (`rmssd_last5_deep`)** | `UNAVAILABLE` | Metodo pubblico WHOOP: richiede gli ultimi 5 minuti dell'ultimo Slow-Wave Sleep. |
| **HRV SWS B5 (`rmssd_best5_last_deep`)** | `UNAVAILABLE` | Metodo brevetto WHOOP: richiede la migliore finestra di 5 minuti nell'ultimo SWS. |
| **HRV SWS B6 (`rmssd_weighted_late_deep`)** | `UNAVAILABLE` | Media dinamica pesata verso la fine del sonno profondo. |
| **RHR Ultimo Deep** | `UNAVAILABLE` | Richiede la localizzazione affidabile dell'ultimo episodio profondo. |
| **Clone Recovery Score WHOOP** | `UNAVAILABLE` | Algoritmo proprietario a pesi sconosciuti. Non clonabile seriamente senza uno studio longitudinale dedicato. |
| **SpO2 (Saturazione)** | `UNAVAILABLE` | Bloccata hardware dal firmware su dispositivi non attivi. |

---

## 6. Risultati dei Test Eseguiti

### 6.1 Sintesi Test Suite Flutter
```
00:00 +0: PuffinFrameCodec Tests (7 test) .............................. PASS
00:01 +7: DartPuffinHandshake & Reassembler (7 test) .................. PASS
00:02 +14: WhoopRepository & Persistence Tests (16 test) ................ PASS
00:04 +30: Segmented HRV & Task Force 1996 Tests (16 test) ............ PASS
00:06 +46: V18 / V26 Decoders Tests (18 test) .......................... PASS
00:09 +64: MetricsService Integration Tests (10 test) ................. PASS
00:15 +74: NightRecorderScreen Widget Tests (4 test) ................... PASS
00:18 +78: EpochEngine 30s Tests (6 test) .............................. PASS
00:20 +84: CardiacSleepWakeEstimator Tests (5 test) .................... PASS
00:22 +89: HrvWindowLab Tests (4 test) ................................. PASS
00:23 +93: Respiration & RHR Tests (4 test) ............................ PASS
00:24 +97: WhoopAComparison Tests (2 test) ............................. PASS
00:26 +99: SleepLabService & Database Tests (3 test) ................... PASS
00:28 +102: SleepLab Regression Test Real Dataset (1 test) ............. PASS
00:30 +103: SleepLabScreen Widget Tests (2 test) ....................... PASS
00:31 +105: DashboardScreen Widget Tests (4 test) ...................... PASS
---------------------------------------------------------------------------------
Totale: 109 test superati su 109 (0 falliti, 0 saltati).
```

### 6.2 Risultato Regressione sul Dataset Reale (`night_1794264340726`)
- **Durata registrata:** 9 ore, 5 minuti e 1,8 secondi (22:45:40 UTC – 07:50:42 UTC).
- **Campioni HR validi:** 32.701 campioni (0 gap > 2 secondi).
- **Intervalli R-R:** 27.424 campioni grezzi, 27.421 fisiologici.
- **Epoche 30s:** 1.091 create, 1.090 utilizzabili (99,9%).
- **Baseline FC notturna (20° percentile):** 52,6 BPM.
- **Sleep Onset rilevato:** 01:12 UTC (02:12 locale). *Non confonde l'inizio della registrazione con il sonno!*
- **Sleep Offset rilevato:** 07:49 UTC (08:49 locale).
- **Tempo di Sonno (TST):** 5 ore e 18 minuti (318 min).
- **Veglia durante la notte (WASO):** 1 ora e 19 minuti (79 min).
- **Risvegli intermedi:** 35 eventi.
- **Efficienza del sonno:** 80,1%.
- **HRV RMSSD Intero Sonno:** 98,6 ms (SIG 1024: 96,3 ms).
- **RHR Minimo 5-Min:** 48 BPM.
- **Frequenza Respiratoria (RSA):** 13,5 RPM (338 finestre spettrali valide su 338).

---

## 7. Percorso APK Compilato

Il binario debug per l'installazione su smartphone Samsung è generato e verificato:
- **Percorso assoluto:** `C:\Users\costa\Downloads\Deepseek_Bevel\app\build\app\outputs\flutter-apk\app-debug.apk`
- **Dimensione:** 179.961.519 byte (~171,6 MB con simboli debug).
- **Application ID:** `com.beveltry.beveltry` (preservato identico).
- **Firma:** Debug keystore standard Android.

---

## 8. Limiti Noti

1. **Specificità della Veglia (Wake Specificity):**
   - Poiché il canale standard 0x2A37 fornisce solo segnali cardiaci, periodi di veglia rilassata a letto (con FC bassa e stabile) possono essere classificati come sonno dallo stimatore cardiaco puro. L'aggiunta dell'accelerometria risolverà questo limite.
2. **Mancanza di Stadiazione Deep/REM:**
   - I candidati HRV formalizzati dal brevetto WHOOP (`rmssd_last5_deep`, `rmssd_best5_last_deep`) rimangono bloccati su `UNAVAILABLE` finché non sarà implementato un modello validato di classificazione delle fasi.
3. **Calibrazione Personalizzata:**
   - I coefficienti logistici correnti ($HR_{elev}, HR_{std}, HR_{slope}$) derivano dalla letteratura actigrafica e cardiovascolare generale; beneficeranno di un affinamento longitudinale man mano che verranno raccolte 10–20 notti accoppiate con WHOOP A.

---

## 9. Raccomandazione Tecnica per TASK 08B (Fasi Light / Deep / REM)

Per implementare la stadiazione del sonno in 4 stadi senza inventare dati:

1. **Integrazione Dati Cinetici (Accelerometria):**
   - Attivare la cattura dei dati cinetici triassiali: o tramite la formalizzazione del canale proprietario Puffin `0x2F v18` dal WHOOP B, oppure tramite l'accelerometro interno dello smartphone/smartwatch registrato in background.
2. **Architettura a Finestre Temporali Indipendenti:**
   - Mantenere la risoluzione di output a **30 secondi per epoca** (allineata alla convenzione standard PSG e WHOOP).
   - Calcolare le feature spettrali HRV e respiratorie su finestre contestuali più ampie (2–5 minuti) centrate sull'epoca, evitando di stimare la variabilità cardiaca solo su 30 secondi.
3. **Classificatore a 4 Stadi:**
   - Implementare un classificatore probabilistico (es. Random Forest o LightGBM quantizzato) addestrato su feature validate:
     - *Cardiache:* Mediana HR, deviazione standard, RMSSD locale, entropia approssimata.
     - *Respiratorie:* Frequenza mediana, varianza della frequenza respiratoria (REM presenta respirazione irregolare rispetto a Deep).
     - *Cinetiche:* Magnitude dell'accelerazione, conteggio superamento soglia zero-crossing.
     - *Temporali:* Posizione dell'epoca nella notte (il Deep prevale nel primo terzo, il REM nell'ultimo terzo).
4. **Sblocco Automatico dei Candidati HRV SWS:**
   - Al raggiungimento di una classificazione Deep comprovata ($\ge 10$ epoche consecutive), il motore attiverà automaticamente i calcoli di `rmssd_last5_deep` e `rmssd_best5_last_deep`, permettendo il confronto diretto e definitivo con il valore ufficiale di WHOOP A.
