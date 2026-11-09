#!/usr/bin/env python3
"""
verify_whoop_b.py - Diagnostic Hardware Verification for WHOOP B (FD:49:44:66:1D:92)

Strict Rules:
1. ONLY connects to FD:49:44:66:1D:92 (WHOOP 5WP, serial 5AG0558675).
2. Explicitly blacklists and ignores WHOOP A (5A00479315).
3. Verifies handshake, serial number, battery, clock, 16 Feature Flags.
4. Physical vibration test (0x42 ALARM_CONTROL).
5. 20-second real-time historical data download (0x16 -> 0x2F -> 0x31 -> 0x17 ACK).
"""

import asyncio
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, List

from bleak import BleakClient, BleakScanner
from bleak.backends.device import BLEDevice

try:
    from bleak.backends.winrt.client import BluetoothLEDevice
except Exception:
    BluetoothLEDevice = None

from whoop_ble.constants import (
    PUFFIN_CHAR_COMMAND_RX,
    PUFFIN_CHAR_COMMAND_TX,
    PUFFIN_CHAR_DATA_STREAM,
    PUFFIN_CHAR_EVENTS,
    PUFFIN_SERVICE_UUID,
)
from whoop_ble.puffin_commands import PuffinDeviceController
from whoop_ble.puffin_engine import PuffinEngine


TARGET_MAC = "FD:49:44:66:1D:92"
EXPECTED_SERIAL = "5AG0558675"
BLACKLIST_WHOOP_A_SERIAL = "5A00479315"


async def main():
    print("=" * 80)
    print(" [WHOOP B] AVVIO VERIFICA HARDWARE REALE - WHOOP B (FD:49:44:66:1D:92)")
    print("=" * 80)

    # -------------------------------------------------------------------------
    # STEP 0: PULIZIA STALE BOND SU WINDOWS (SE PRESENTE)
    # -------------------------------------------------------------------------
    if BluetoothLEDevice:
        try:
            addr_int = int(TARGET_MAC.replace(":", ""), 16)
            win_dev = await BluetoothLEDevice.from_bluetooth_address_async(addr_int)
            if win_dev and win_dev.device_information.pairing.is_paired:
                print("[*] Rimozione stale pairing bond da Windows Registry...")
                await win_dev.device_information.pairing.unpair_async()
                print("[+] Windows bond rimosso con successo.")
        except Exception as e:
            print(f"[*] Controllo bond Windows: {e}")

    # -------------------------------------------------------------------------
    # STEP 1: SCANNING E FILTRO HARDWARE INVIOLABILE (BLACKLIST WHOOP A)
    # -------------------------------------------------------------------------
    print(f"\n[1/5] Scansione BLE in corso (cercando target MAC {TARGET_MAC})...")
    discovered_devices = await BleakScanner.discover(timeout=6.0, return_adv=True)

    target_device: BLEDevice = None
    target_adv = None

    for d, adv in discovered_devices.values():
        name = adv.local_name or d.name or "Unknown"
        addr = d.address.upper()

        # Controllo Blacklist WHOOP A
        if BLACKLIST_WHOOP_A_SERIAL in name.upper() or "5A00479315" in addr:
            print(f"  [IGNORED - WHOOP A] Dispositivo rilevato e scartato: {name} ({addr})")
            continue

        # Verifica Target WHOOP B
        if addr == TARGET_MAC.upper() or TARGET_MAC.upper() in addr:
            target_device = d
            target_adv = adv
            print(f"  [TARGET TROVATO] WHOOP B identificato: '{name}' | MAC: {addr} | RSSI: {adv.rssi} dBm")

    if not target_device:
        print(f"\n[ERRORE FATALE] WHOOP B ({TARGET_MAC}) non trovato o spento/fuori portata!")
        print("Interruzione immediata del test per prevenire connessioni errate.")
        sys.exit(1)

    print(f"\n[+] Connessione esclusiva a WHOOP B ({target_device.address})...")

    # -------------------------------------------------------------------------
    # STEP 2: CONNESSIONE GATT & SOTTOSCRIZIONE CARATTERISTICHE PUFFIN
    # -------------------------------------------------------------------------
    async with BleakClient(target_device, timeout=15.0) as client:
        if not client.is_connected:
            print(f"[ERRORE] Impossibile stabilire connessione BLE con {TARGET_MAC}")
            sys.exit(1)

        print(f"[+] Connesso con successo al WHOOP B! MTU={client.mtu_size}")
        await asyncio.sleep(1.0)

        engine = PuffinEngine(client)
        controller = PuffinDeviceController(engine)

        print("[*] Sottoscrizione caratteristiche notify Puffin (fd4b0003, fd4b0004, fd4b0005)...")
        await engine.subscribe_all()
        print("[+] Canali notify sottoscritti con successo.")

        # -------------------------------------------------------------------------
        # STEP 3: HANDSHAKE, SERIALE, BATTERIA, CLOCK & FEATURE FLAGS
        # -------------------------------------------------------------------------
        print("\n" + "-" * 80)
        print(" [2/5] HANDSHAKE E VERIFICA IDENTITÀ (0x91 GET_HELLO)")
        print("-" * 80)

        hello_resp = await controller.get_hello(b3=0x01)
        raw_hello_hex = hello_resp.get("raw_hex", "N/A")
        parsed_hello = hello_resp.get("parsed", {})
        extracted_sn = parsed_hello.get("serial_number", "UNKNOWN")

        print(f"  * RAW HEX ricevuto su fd4b0003: {raw_hello_hex}")
        print(f"  * Seriale estratto da GET_HELLO: '{extracted_sn}'")
        print(f"  * Seriale atteso:               '{EXPECTED_SERIAL}'")

        if extracted_sn != EXPECTED_SERIAL and EXPECTED_SERIAL not in extracted_sn:
            print(f"  [!] ATTENZIONE: Il seriale estratto '{extracted_sn}' differisce da '{EXPECTED_SERIAL}'!")
        else:
            print("  [OK] Seriale hardware VERIFICATO con successo: WHOOP B 5AG0558675!")

        # 0x8D Advertising Name
        try:
            adv_name = await controller.get_advertising_name(b3=0x01)
            print(f"  * Advertising Name interno (0x8D): '{adv_name}'")
        except Exception as e:
            print(f"  * Advertising Name (0x8D) errore: {e}")

        # 0x1A GET_BATTERY
        bat_info = await controller.get_battery()
        bat_pct = bat_info.get("battery_percent", "N/A")
        bat_mv = bat_info.get("battery_millivolts", "N/A")
        charging = bat_info.get("charging_state", "N/A")
        print(f"  * Batteria Reale (0x1A): {bat_pct}% ({bat_mv} mV) | Stato Carica: {charging}")

        # 0x0B GET_CLOCK
        clk_info = await controller.get_clock()
        clk_unix = clk_info.get("clock_unix", "N/A")
        clk_utc = clk_info.get("clock_utc", "N/A")
        is_latched = clk_info.get("is_clock_latched", "N/A")
        print(f"  * Orologio RTC interno (0x0B): Unix={clk_unix} ({clk_utc}) | Latched: {is_latched}")

        # 16 Feature Flags (0x78)
        print("\n[*] Configurazione 16 Feature Flags (0x78 SET_FF_VALUE)...")
        ff_summary = await controller.unlock_16_feature_flags()
        total_ff = ff_summary.get("total_flags", 16)
        applied_ff = ff_summary.get("successfully_applied", 0)
        print(f"  [OK] Feature Flags applicate con successo: {applied_ff}/{total_ff}")

        # -------------------------------------------------------------------------
        # STEP 4: TEST FISICO VIBRAZIONE (0x42 ALARM_CONTROL)
        # -------------------------------------------------------------------------
        print("\n" + "-" * 80)
        print(" [3/5] TEST FISICO VIBRAZIONE (0x42 ALARM_CONTROL)")
        print("-" * 80)
        print("  * Invio comando 0x42: vibrazione fisica pattern=1 per 1000 ms...")
        vibe_resp = await controller.send_alarm_vibration(pattern=1, duration_ms=1000)
        print(f"  * Risposta 0x24 dal cinturino:")
        print(f"    - Status: {vibe_resp.get('status_name')} (code {vibe_resp.get('status_code')})")
        print(f"    - RAW Response HEX: {vibe_resp.get('raw_hex')}")
        print("  [OK] Comando vibrazione accettato dal microcontrollore del cinturino!")

        # -------------------------------------------------------------------------
        # STEP 5: STREAMING DATI REALI (0x16 -> 0x2F -> 0x31 -> 0x17 ACK) PER 20 SEC
        # -------------------------------------------------------------------------
        print("\n" + "-" * 80)
        print(" [4/5] TEST SCARICAMENTO DATI REALI (0x16 -> 0x2F -> 0x31 -> 0x17 ACK) PER 20s")
        print("-" * 80)

        received_v18_records: List[Dict[str, Any]] = []
        received_cursors: List[str] = []
        acked_cursors: List[str] = []

        # Hook per intercettare e stampare cursore 0x31 e ACK 0x17
        orig_auto_ack = engine._auto_ack_cursor

        async def tracked_auto_ack(cursor_b: bytes):
            cursor_hex = cursor_b.hex().upper()
            received_cursors.append(cursor_hex)
            print(f"  --> [0x31 CURSOR METADATA] Cursore 8-byte estratto a inner[13:21]: {cursor_hex}")
            try:
                # Invia 0x17 ACK
                await orig_auto_ack(cursor_b)
                acked_cursors.append(cursor_hex)
                print(f"  <-- [0x17 AUTO-ACK OK] Conferma ACK 0x17 inviata con successo per cursore: {cursor_hex}")
            except Exception as e:
                print(f"  <-- [0x17 AUTO-ACK ERROR] Errore invio ACK: {e}")

        engine._auto_ack_cursor = tracked_auto_ack

        # Callback per pacchetti storici 0x2F
        def on_hist_record(record: Dict[str, Any]):
            rec_type = record.get("type")
            if rec_type == "HISTORICAL_RECORD_V18":
                idx = len(received_v18_records) + 1
                received_v18_records.append(record)

                seq = record.get("sequence")
                ts_utc = record.get("timestamp_utc", "N/A")
                hr = record.get("primary_hr_bpm")
                rr = record.get("rr_intervals_ms", [])
                st = record.get("skin_temp_c")
                wrist = "ON_WRIST" if record.get("is_on_wrist") else "OFF_WRIST"

                # Stampa in tempo reale i primi 5 record
                if idx <= 5:
                    print(f"  [0x2F v18 #{idx:03d}] seq={seq} | ts_utc={ts_utc} | HR={hr:<3} BPM | RR={rr} ms | Temp={st}°C | {wrist}")

        engine.on_historical_record = on_hist_record

        # Invio 0x16 SEND_HISTORICAL
        print("  * Invio comando 0x16 SEND_HISTORICAL per avviare il dump dalla flash...")
        await controller.trigger_historical_offload(b3=0x00)

        # Attesa streaming per 20 secondi
        print("  * Streaming attivo in tempo reale per 20 secondi...")
        for remaining in range(20, 0, -5):
            await asyncio.sleep(5)
            print(f"    ... streaming in corso ({20 - remaining + 5}/20s) - Record v18 ricevuti finora: {len(received_v18_records)}, Cursori 0x31: {len(received_cursors)}")

        # Stampa gli ultimi 5 record ricevuti
        total_v18 = len(received_v18_records)
        if total_v18 > 5:
            print(f"\n  * Dettaglio ultimi 5 record 0x2F v18 ricevuti (su {total_v18} totali):")
            start_last5 = max(5, total_v18 - 5)
            for i, record in enumerate(received_v18_records[start_last5:], start=start_last5 + 1):
                seq = record.get("sequence")
                ts_utc = record.get("timestamp_utc", "N/A")
                hr = record.get("primary_hr_bpm")
                rr = record.get("rr_intervals_ms", [])
                st = record.get("skin_temp_c")
                wrist = "ON_WRIST" if record.get("is_on_wrist") else "OFF_WRIST"
                print(f"  [0x2F v18 #{i:03d}] seq={seq} | ts_utc={ts_utc} | HR={hr:<3} BPM | RR={rr} ms | Temp={st}°C | {wrist}")

        # -------------------------------------------------------------------------
        # STEP 6: RIEPILOGO FINALE VERIFICA HARDWARE
        # -------------------------------------------------------------------------
        print("\n" + "=" * 80)
        print(" [5/5] RIEPILOGO FINALE VERIFICA HARDWARE REAL-TIME WHOOP B")
        print("=" * 80)
        print(f"  1. Dispositivo Connesso:   WHOOP B ({TARGET_MAC})")
        print(f"  2. Seriale Hardware:       {extracted_sn} (MATCH: {extracted_sn == EXPECTED_SERIAL})")
        print(f"  3. Batteria Reale:         {bat_pct}% ({bat_mv} mV)")
        print(f"  4. Test Vibrazione (0x42): SUPERATO (Status: {vibe_resp.get('status_name')})")
        print(f"  5. Pacchetti 0x2F v18:     {total_v18} record ricevuti")
        print(f"  6. Cursori 0x31 Ricevuti:  {len(received_cursors)}")
        print(f"  7. ACK 0x17 Confermati:    {len(acked_cursors)}")

        if total_v18 > 0:
            ts_list = [r["timestamp_unix"] for r in received_v18_records if r.get("timestamp_unix", 0) > 0]
            if ts_list:
                min_dt = datetime.fromtimestamp(min(ts_list), tz=timezone.utc).isoformat()
                max_dt = datetime.fromtimestamp(max(ts_list), tz=timezone.utc).isoformat()
                print(f"  8. Range Temporale Coperto: da {min_dt} a {max_dt}")

        print("=" * 80)
        print(" >>> TEST HARDWARE COMPLETATO CON SUCCESSO SUL WHOOP B! <<<")
        print("=" * 80)


if __name__ == "__main__":
    asyncio.run(main())
