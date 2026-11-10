#!/usr/bin/env python3
"""
whoop_night_recorder.py — Standalone Windows 11 Night Recorder for WHOOP B (Surface Pro Fallback)
Task 07: Acquisizione dati reali per tutta la notte 9-10 novembre 2026.

REQUISITI INVIOLABILI:
1. Connette esclusivamente WHOOP B (FD:49:44:66:1D:92 / WBB5AP-5AG0558675).
2. Blacklist assoluta per WHOOP A (5A00479315): MAI connettersi o inviare comandi.
3. Caratteristica standard Heart Rate Measurement (UUID 0x2A37).
4. Nessuna dipendenza dal protocollo Puffin (nessun HELLO 0x91, nessun blocco).
5. Persistenza progressiva su SQLite (whoop_night_records.db in WAL mode) e CSV.
6. Riconnessione automatica con backoff su disconnessione BLE.
7. Nessun dato inventato o simulato.
8. Rapporto del mattino dettagliato con le 13 metriche richieste.
"""

import asyncio
import csv
import math
import os
import signal
import sqlite3
import sys
import time
from datetime import datetime, timezone
from typing import Dict, List, Optional, Tuple

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice

# Indirizzi e UUID hardware
TARGET_MAC = "FD:49:44:66:1D:92"
TARGET_NAME_PREFIX = "WBB5AP"
EXPECTED_SERIAL = "5AG0558675"
BLACKLIST_WHOOP_A = "5A00479315"

HEART_RATE_SERVICE_UUID = "0000180d-0000-1000-8000-00805f9b34fb"
HEART_RATE_MEASUREMENT_UUID = "00002a37-0000-1000-8000-00805f9b34fb"

DB_FILE = "whoop_night_records.db"
CSV_FILE = "whoop_night_samples.csv"


class NightRecorderEngine:
    def __init__(self, session_id: Optional[str] = None):
        self.session_id = session_id or f"night_{int(time.time())}"
        self.client: Optional[BleakClient] = None
        self.is_running = False
        self.start_time_utc = time.time()
        self.end_time_utc: Optional[float] = None
        
        self.samples_count = 0
        self.rr_count = 0
        self.disconnections_count = 0
        self.last_sample_time = 0.0
        self.disconnect_time: Optional[float] = None
        self.total_disconnected_duration = 0.0

        self.hr_values: List[Tuple[float, int]] = []
        self.valid_rr_values: List[int] = []

        self._init_storage()

    def _init_storage(self):
        """Inizializza SQLite in WAL mode."""
        conn = sqlite3.connect(DB_FILE)
        conn.execute("PRAGMA journal_mode = WAL;")
        conn.execute("PRAGMA synchronous = NORMAL;")
        with conn:
            conn.execute("""
                CREATE TABLE IF NOT EXISTS night_sessions (
                    session_id TEXT PRIMARY KEY,
                    start_time_utc REAL NOT NULL,
                    end_time_utc REAL,
                    device_address TEXT NOT NULL,
                    device_name TEXT NOT NULL,
                    status TEXT NOT NULL,
                    total_samples INTEGER DEFAULT 0,
                    total_rr INTEGER DEFAULT 0,
                    disconnections_count INTEGER DEFAULT 0
                );
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS night_samples (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    timestamp_utc REAL NOT NULL,
                    monotonic_sec REAL NOT NULL,
                    hr_bpm INTEGER NOT NULL,
                    flags INTEGER NOT NULL,
                    sensor_contact INTEGER NOT NULL,
                    rr_status TEXT NOT NULL,
                    origin TEXT NOT NULL,
                    UNIQUE(session_id, timestamp_utc, hr_bpm)
                );
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS night_rr_intervals (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    sample_id INTEGER NOT NULL,
                    session_id TEXT NOT NULL,
                    timestamp_utc REAL NOT NULL,
                    beat_ordinal INTEGER NOT NULL,
                    rr_raw INTEGER NOT NULL,
                    rr_ms_direct INTEGER NOT NULL,
                    rr_ms_1024 REAL NOT NULL
                );
            """)
            conn.execute("""
                CREATE TABLE IF NOT EXISTS night_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    session_id TEXT NOT NULL,
                    timestamp_utc REAL NOT NULL,
                    event_type TEXT NOT NULL,
                    details TEXT
                );
            """)
            conn.execute("""
                INSERT OR REPLACE INTO night_sessions 
                (session_id, start_time_utc, device_address, device_name, status)
                VALUES (?, ?, ?, ?, ?);
            """, (self.session_id, self.start_time_utc, TARGET_MAC, "WHOOP 5.0 (WHOOP B)", "RECORDING"))
        conn.close()

        # Inizializza CSV con intestazione se nuovo
        if not os.path.exists(CSV_FILE):
            with open(CSV_FILE, "w", newline="", encoding="utf-8") as f:
                writer = csv.writer(f)
                writer.writerow([
                    "session_id", "timestamp_utc", "datetime_iso", "monotonic_sec",
                    "hr_bpm", "flags", "sensor_contact", "rr_count", "rr_raw_list", "rr_ms_list"
                ])

    def _save_sample(self, hr: int, flags: int, sensor_contact: int, raw_rrs: List[int]):
        now_utc = time.time()
        mono = time.monotonic()
        rr_status = "AVAILABLE" if raw_rrs else "RR_UNAVAILABLE"

        conn = sqlite3.connect(DB_FILE)
        try:
            with conn:
                cursor = conn.execute("""
                    INSERT OR IGNORE INTO night_samples 
                    (session_id, timestamp_utc, monotonic_sec, hr_bpm, flags, sensor_contact, rr_status, origin)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """, (self.session_id, now_utc, mono, hr, flags, sensor_contact, rr_status, "GATT_0x2A37"))
                sample_id = cursor.lastrowid

                if sample_id and raw_rrs:
                    for idx, raw_rr in enumerate(raw_rrs):
                        # REGOLA INVIOLABILE 2: u16 è già in ms diretti su WHOOP 5.0
                        rr_ms_direct = raw_rr
                        rr_ms_1024 = raw_rr * 1000.0 / 1024.0
                        conn.execute("""
                            INSERT INTO night_rr_intervals 
                            (sample_id, session_id, timestamp_utc, beat_ordinal, rr_raw, rr_ms_direct, rr_ms_1024)
                            VALUES (?, ?, ?, ?, ?, ?, ?);
                        """, (sample_id, self.session_id, now_utc, idx, raw_rr, rr_ms_direct, rr_ms_1024))
                        if 300 <= rr_ms_direct <= 2000:
                            self.valid_rr_values.append(rr_ms_direct)

                conn.execute("""
                    UPDATE night_sessions 
                    SET total_samples = total_samples + 1, total_rr = total_rr + ?
                    WHERE session_id = ?;
                """, (len(raw_rrs), self.session_id))
        finally:
            conn.close()

        self.samples_count += 1
        self.rr_count += len(raw_rrs)
        self.last_sample_time = now_utc
        self.hr_values.append((now_utc, hr))

        # Salva su CSV progressivo
        with open(CSV_FILE, "a", newline="", encoding="utf-8") as f:
            writer = csv.writer(f)
            writer.writerow([
                self.session_id,
                f"{now_utc:.3f}",
                datetime.fromtimestamp(now_utc, tz=timezone.utc).isoformat(),
                f"{mono:.3f}",
                hr,
                flags,
                sensor_contact,
                len(raw_rrs),
                ";".join(map(str, raw_rrs)),
                ";".join(map(str, raw_rrs)),
            ])

    def log_event(self, event_type: str, details: str):
        now_utc = time.time()
        conn = sqlite3.connect(DB_FILE)
        with conn:
            conn.execute("""
                INSERT INTO night_events (session_id, timestamp_utc, event_type, details)
                VALUES (?, ?, ?, ?);
            """, (self.session_id, now_utc, event_type, details))
            if event_type == "DISCONNECTED":
                conn.execute("""
                    UPDATE night_sessions 
                    SET disconnections_count = disconnections_count + 1 
                    WHERE session_id = ?;
                """, (self.session_id,))
        conn.close()

    def handle_hr_notification(self, _, data: bytearray):
        if not data:
            return

        flags = data[0]
        is_16bit = bool(flags & 0x01)
        sensor_contact_supported = bool(flags & 0x04)
        sensor_contact_detected = bool(flags & 0x02) if sensor_contact_supported else None
        energy_present = bool(flags & 0x08)
        rr_present = bool(flags & 0x10)

        offset = 1
        if is_16bit:
            if len(data) < offset + 2:
                return
            hr = data[offset] | (data[offset + 1] << 8)
            offset += 2
        else:
            if len(data) < offset + 1:
                return
            hr = data[offset]
            offset += 1

        if energy_present:
            offset += 2

        raw_rrs: List[int] = []
        if rr_present:
            while offset + 1 < len(data):
                raw_rr = data[offset] | (data[offset + 1] << 8)
                raw_rrs.append(raw_rr)
                offset += 2

        sc_val = 1 if sensor_contact_detected is True else (0 if sensor_contact_detected is False else -1)
        self._save_sample(hr, flags, sc_val, raw_rrs)

        # Logging continuativo console
        now_str = datetime.now().strftime("%H:%M:%S")
        elapsed = int(time.time() - self.start_time_utc)
        el_h = elapsed // 3600
        el_m = (elapsed % 3600) // 60
        el_s = elapsed % 60
        rr_info = f"{len(raw_rrs)} RR ({raw_rrs[-1]}ms)" if raw_rrs else "NO_RR"
        print(f"[{now_str}] HR: {hr:3d} BPM | {rr_info} | Campioni: {self.samples_count:5d} | Durata: {el_h:02d}:{el_m:02d}:{el_s:02d} | Saved to DB/CSV", end="\r")

    def end_session(self):
        self.end_time_utc = time.time()
        conn = sqlite3.connect(DB_FILE)
        with conn:
            conn.execute("""
                UPDATE night_sessions 
                SET end_time_utc = ?, status = ? 
                WHERE session_id = ?;
            """, (self.end_time_utc, "COMPLETED", self.session_id))
        conn.close()

    def generate_morning_report(self) -> str:
        end = self.end_time_utc or time.time()
        total_duration_sec = int(end - self.start_time_utc)
        
        start_dt_utc = datetime.fromtimestamp(self.start_time_utc, tz=timezone.utc)
        start_dt_local = datetime.fromtimestamp(self.start_time_utc)
        end_dt_utc = datetime.fromtimestamp(end, tz=timezone.utc)
        end_dt_local = datetime.fromtimestamp(end)

        valid_hrs = [hr for _, hr in self.hr_values if 0 < hr <= 240]
        mean_hr = sum(valid_hrs) / len(valid_hrs) if valid_hrs else None
        median_hr = None
        min_hr = None
        max_hr = None
        estimated_rhr = None

        if valid_hrs:
            sorted_hrs = sorted(valid_hrs)
            min_hr = sorted_hrs[0]
            max_hr = sorted_hrs[-1]
            mid = len(sorted_hrs) // 2
            median_hr = sorted_hrs[mid] if len(sorted_hrs) % 2 == 1 else (sorted_hrs[mid - 1] + sorted_hrs[mid]) / 2.0

            # Stima RHR notturno: media minima su finestra mobile di 300 secondi (5 minuti)
            window_size = 300
            if len(valid_hrs) <= window_size:
                estimated_rhr = round(sum(valid_hrs) / len(valid_hrs))
            else:
                cur_sum = sum(valid_hrs[:window_size])
                min_sum = cur_sum
                for i in range(window_size, len(valid_hrs)):
                    cur_sum += valid_hrs[i] - valid_hrs[i - window_size]
                    if cur_sum < min_sum:
                        min_sum = cur_sum
                estimated_rhr = round(min_sum / window_size)

        # Calcolo HRV RMSSD standard Task Force 1996
        rmssd_ms = None
        if len(self.valid_rr_values) >= 2:
            sum_sq = sum((self.valid_rr_values[i] - self.valid_rr_values[i - 1]) ** 2 for i in range(1, len(self.valid_rr_values)))
            rmssd_ms = math.sqrt(sum_sq / (len(self.valid_rr_values) - 1))

        # Copertura temporale stimata (1 campione al secondo atteso)
        expected_samples = max(1, total_duration_sec)
        coverage_pct = min(100.0, (self.samples_count / expected_samples) * 100.0)

        dur_h = total_duration_sec // 3600
        dur_m = (total_duration_sec % 3600) // 60
        dur_s = total_duration_sec % 60
        duration_fmt = f"{dur_h:02d}:{dur_m:02d}:{dur_s:02d}"

        report = []
        report.append("# BEVELTRY — RAPPORTO SESSIONE NOTTURNA (NIGHT RECORDER)")
        report.append(f"**Data:** {start_dt_local.strftime('%d/%m/%Y')} — {end_dt_local.strftime('%d/%m/%Y')}")
        report.append(f"**Sessione ID:** `{self.session_id}`")
        report.append(f"**Dispositivo Registrato:** WHOOP 5.0 (`{TARGET_MAC}`, Seriale `{EXPECTED_SERIAL}`)")
        report.append(f"**Database:** `{DB_FILE}` (WAL Mode) | **CSV:** `{CSV_FILE}`\n")
        report.append("---")
        report.append("## 1. TEMPI E COPERTURA DELLA REGISTRAZIONE")
        report.append(f"- **Inizio Registrazione:** {start_dt_local.strftime('%Y-%m-%d %H:%M:%S')} (UTC: {start_dt_utc.strftime('%H:%M:%S')})")
        report.append(f"- **Fine Registrazione:** {end_dt_local.strftime('%Y-%m-%d %H:%M:%S')} (UTC: {end_dt_utc.strftime('%H:%M:%S')})")
        report.append(f"- **Durata Totale:** {duration_fmt} ({total_duration_sec} secondi)")
        report.append(f"- **Campioni HR Ricevuti:** {self.samples_count}")
        report.append(f"- **Copertura Temporale Stimata:** {coverage_pct:.1f}% (assunzione: intervallo di notifica standard ~1s)")
        report.append(f"- **Disconnessioni BLE:** {self.disconnections_count} (durata offline stimata: {int(self.total_disconnected_duration)}s)\n")
        report.append("---")
        report.append("## 2. METRICHE CARDIACHE OSSERVATE (0x2A37)")
        report.append(f"- **Frequenza Cardiaca Media:** {f'{mean_hr:.1f} BPM' if mean_hr is not None else 'N/D'}")
        report.append(f"- **Frequenza Cardiaca Mediana:** {f'{median_hr:.1f} BPM' if median_hr is not None else 'N/D'}")
        report.append(f"- **Frequenza Minima Osservata:** {f'{min_hr} BPM' if min_hr is not None else 'N/D'}")
        report.append(f"- **Frequenza Massima Osservata:** {f'{max_hr} BPM' if max_hr is not None else 'N/D'}")
        report.append(f"- **Stima FC a Riposo (RHR Notturno):** {f'{estimated_rhr} BPM' if estimated_rhr is not None else 'N/D'}")
        report.append("  *(Metodo esplicito: media minima su finestra mobile continua di 5 minuti / 300 campioni validi. Non rappresenta la semplice FC minima estemporanea).*\n")
        report.append("---")
        report.append("## 3. VARIABILITÀ CARDIACA (HRV RMSSD)")
        report.append(f"- **Intervalli R-R Grezzi Ricevuti:** {self.rr_count}")
        report.append(f"- **Intervalli R-R Fisiologicamente Validi (300-2000 ms):** {len(self.valid_rr_values)}")
        if rmssd_ms is not None:
            report.append(f"- **HRV RMSSD Calcolato:** {rmssd_ms:.1f} ms")
            report.append("  *(Formula Task Force 1996: radice quadrata della media delle differenze successive al quadrato. Misurato sull'intera sessione notturna di acquisizione).*")
        else:
            report.append("- **HRV RMSSD:** MISSING (Intervalli R-R insufficienti (<2) o non trasmessi dalla notifica 0x2A37).")
        report.append("\n---")
        report.append("## 4. METRICHE NON DISPONIBILI (TRASPARENZA TOTALE)")
        report.append("- **Deep Sleep HRV:** MISSING — Richiede la stadiazione proprietaria del sonno profondo (Slow Wave Sleep).")
        report.append("- **WHOOP Recovery Score:** MISSING — Algoritmo proprietario WHOOP non calcolato per preservare l'integrità scientifica.")
        report.append("- **Fasi del Sonno (Deep/REM/Light):** MISSING — Algoritmo di stadiazione sonno proprietario non disponibile.")
        report.append("- **SpO2 (Saturazione Ossigeno):** MISSING — Bloccata dall'Entitlement Gate hardware del WHOOP (byte @82 = 0x00 senza abbonamento).")
        report.append("- **Frequenza Respiratoria:** MISSING — Richiede modello DSP proprietario su micro-oscillazioni sinusali.")
        report.append("- **Temperatura Cutanea:** MISSING — Trasmessa unicamente nei pacchetti storici 0x2F v18 autenticati.\n")
        report.append("---")
        report.append("*Rapporto generato in modo affidabile dal recorder Beveltry senza alcuna simulazione.*")
        return "\n".join(report)


async def find_whoop_b(timeout: float = 8.0) -> Optional[BLEDevice]:
    """Cerca attivamente WHOOP B scartando categoricamente WHOOP A."""
    print(f"[*] Scansione BLE in corso (cercando target MAC {TARGET_MAC})...")
    devices = await BleakScanner.discover(timeout=timeout, return_adv=True)
    for d, adv in devices.values():
        name = adv.local_name or d.name or "Unknown"
        addr = d.address.upper()
        if BLACKLIST_WHOOP_A in name.upper() or "5A00479315" in addr:
            print(f"  [BLACKLIST WHOOP A IGNORATO] Scartato: {name} ({addr})")
            continue
        if addr == TARGET_MAC.upper() or TARGET_MAC.upper() in addr:
            print(f"  [WHOOP B TROVATO] Trovato dispositivo autorizzato: '{name}' ({addr}) RSSI: {adv.rssi} dBm")
            return d
    return None


async def run_night_recorder():
    recorder = NightRecorderEngine()
    print("=" * 80)
    print(" [WHOOP B] BEVELTRY NIGHT RECORDER (SURFACE PRO WINDOWS 11)")
    print(f" Sessione: {recorder.session_id}")
    print(f" Target Hardware: WHOOP B ({TARGET_MAC})")
    print(" Regole attive: standard 0x2A37, nessun handshake Puffin, no crash, WAL SQLite")
    print("=" * 80)

    loop = asyncio.get_running_loop()
    stop_event = asyncio.Event()

    def _sig_handler():
        print("\n[!] Ricevuto segnale di terminazione. Chiusura sessione in corso...")
        stop_event.set()

    for s in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(s, _sig_handler)
        except NotImplementedError:
            pass  # Su Windows add_signal_handler non è supportato per tutti i loop

    reconnect_attempt = 0

    while not stop_event.is_set():
        device = await find_whoop_b(timeout=6.0)
        if not device:
            reconnect_attempt += 1
            backoff = min(30, 2 * reconnect_attempt)
            print(f"[!] WHOOP B non trovato in pubblicità. Ritento tra {backoff}s (tentativo {reconnect_attempt})...")
            recorder.log_event("DISCONNECTED", f"Dispositivo non trovato. Backoff {backoff}s")
            try:
                await asyncio.wait_for(stop_event.wait(), timeout=backoff)
            except asyncio.TimeoutError:
                continue
            break

        print(f"[+] Tentativo di connessione GATT a {device.address}...")
        reconnect_attempt = 0

        def disconnected_callback(client: BleakClient):
            print("\n[!] Disconnessione BLE rilevata dal cinturino!")
            recorder.disconnections_count += 1
            recorder.disconnect_time = time.time()
            recorder.log_event("DISCONNECTED", "GATT disconnected callback")

        try:
            async with BleakClient(device, disconnected_callback=disconnected_callback, timeout=20.0) as client:
                if not client.is_connected:
                    print("[!] Connessione fallita.")
                    continue

                recorder.log_event("CONNECTED", f"GATT connected to {device.address}")
                if recorder.disconnect_time:
                    recorder.total_disconnected_duration += (time.time() - recorder.disconnect_time)
                    recorder.disconnect_time = None

                print(f"[+] Connesso con successo a WHOOP B!")
                print(f"[+] Sottoscrizione a Heart Rate Measurement (0x2A37)...")
                await client.start_notify(HEART_RATE_MEASUREMENT_UUID, recorder.handle_hr_notification)
                print("[+] Stream HR 0x2A37 ATTIVO! Acquisizione continua avviata.\n")

                while client.is_connected and not stop_event.is_set():
                    await asyncio.sleep(1.0)

                print("\n[*] Arresto ricezione notifiche...")
                try:
                    await client.stop_notify(HEART_RATE_MEASUREMENT_UUID)
                except Exception:
                    pass

        except KeyboardInterrupt:
            print("\n[!] Interruzione manuale da tastiera.")
            stop_event.set()
        except Exception as e:
            print(f"\n[ERRORE BLE] Eccezione: {e}")
            recorder.log_event("ERROR", str(e))
            await asyncio.sleep(3.0)

    recorder.end_session()
    report_md = recorder.generate_morning_report()
    
    # Salva il report
    with open("TASK_07_NIGHT_RECORDER_REPORT.md", "w", encoding="utf-8") as f:
        f.write(report_md)

    print("\n" + "=" * 80)
    print(" RAPPORTO DEL MATTINO GENERATO CON SUCCESSO:")
    print("=" * 80)
    print(report_md)
    print("=" * 80)
    print(f"[+] Report salvato in: TASK_07_NIGHT_RECORDER_REPORT.md")
    print(f"[+] Dati persistiti in: {DB_FILE} e {CSV_FILE}")


if __name__ == "__main__":
    try:
        asyncio.run(run_night_recorder())
    except KeyboardInterrupt:
        print("\n[*] Script terminato.")
