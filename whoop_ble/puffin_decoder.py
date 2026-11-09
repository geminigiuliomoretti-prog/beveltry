"""
WHOOP Gen 5 ("Puffin" fd4b) Packet Decoder.
Decodes:
- Live HR 0x28 (BPM, On-Wrist validity flag, direct RR in ms, Unix timestamp)
- Response 0x24 (echo_seq, resp_cmd, strap_seq, status, payload parsing)
- Historical Record 0x2F (v18 124B record, v26 88B PPG wave)
- Cursor / Metadata 0x31 (extracts 8-byte cursor for 0x17 auto-ACK)
- Hardware Events 0x30 (asynchronous notifications on fd4b0004)
"""

import datetime
import struct
from typing import Any, Dict, List, Optional, Tuple


def decode_puffin_packet(inner_payload: bytes) -> Dict[str, Any]:
    """
    Main dispatcher for decoding inner Puffin payloads (after envelope un-framing).
    """
    if not inner_payload:
        return {"status": "EMPTY_PAYLOAD"}

    opcode = inner_payload[0]

    if opcode == 0x24:
        return decode_response_0x24(inner_payload)
    elif opcode == 0x28:
        return decode_live_hr_0x28(inner_payload)
    elif opcode == 0x2F:
        return decode_historical_record_0x2F(inner_payload)
    elif opcode == 0x30:
        return decode_event_0x30(inner_payload)
    elif opcode == 0x31:
        return decode_cursor_metadata_0x31(inner_payload)
    else:
        return {
            "status": "UNKNOWN_OPCODE",
            "opcode": f"0x{opcode:02X}",
            "raw_hex": inner_payload.hex().upper(),
            "byte_length": len(inner_payload),
        }


def decode_response_0x24(inner: bytes) -> Dict[str, Any]:
    """
    Format: [0x24, echo_seq (u8), resp_cmd (u8), strap_seq (u8), status (u8), ...payload]
    """
    if len(inner) < 5:
        return {
            "status": "TRUNCATED_RESPONSE",
            "raw_hex": inner.hex().upper(),
            "error": "Response shorter than 5 bytes",
        }

    echo_seq = inner[1]
    resp_cmd = inner[2]
    strap_seq = inner[3]
    resp_status = inner[4]
    payload = inner[5:]

    is_success = resp_status in (0x00, 0x01)

    result: Dict[str, Any] = {
        "type": "COMMAND_RESPONSE",
        "opcode": "0x24",
        "echo_seq": echo_seq,
        "resp_cmd": resp_cmd,
        "resp_cmd_hex": f"0x{resp_cmd:02X}",
        "strap_seq": strap_seq,
        "status_code": resp_status,
        "is_success": is_success,
        "is_in_progress": resp_status == 0x02,
        "payload_hex": payload.hex().upper(),
        "parsed": {},
    }

    # Command-specific payload parsing
    if resp_cmd == 0x8D:  # GET_ADVERTISING_NAME
        name = payload.split(b"\x00")[0].decode("ascii", errors="replace").strip()
        result["parsed"]["advertising_name"] = name

    elif resp_cmd == 0x0B:  # GET_CLOCK
        if len(payload) >= 4:
            ts = struct.unpack_from("<I", payload, 0)[0]
            is_latched = ts >= 1700000000  # >= Nov 2023 -> real current time
            dt_str = "UNLATCHED"
            if ts > 0:
                try:
                    dt = datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc)
                    dt_str = dt.isoformat()
                except Exception:
                    dt_str = "INVALID_TIMESTAMP"
            result["parsed"]["clock_unix"] = ts
            result["parsed"]["clock_utc"] = dt_str
            result["parsed"]["is_clock_latched"] = is_latched
        if len(payload) >= 8:
            result["parsed"]["clock_extra_u32"] = struct.unpack_from("<I", payload, 4)[0]

    elif resp_cmd == 0x1A:  # GET_BATTERY
        if len(payload) >= 1:
            result["parsed"]["battery_percent"] = payload[0]
        if len(payload) >= 3:
            mv = struct.unpack_from("<H", payload, 1)[0]
            result["parsed"]["battery_millivolts"] = mv
        if len(payload) >= 4:
            result["parsed"]["charging_state"] = payload[3]

    elif resp_cmd == 0x22:  # GET_DATA_RANGE
        # Range of data stored in 512MB NAND flash
        if len(payload) >= 61:
            total_records = struct.unpack_from("<I", payload, 29)[0]
            start_ts = struct.unpack_from("<I", payload, 33)[0]
            sync_ts = struct.unpack_from("<I", payload, 41)[0]
            end_ts = struct.unpack_from("<I", payload, 57)[0]
            result["parsed"]["total_records_available"] = total_records
            result["parsed"]["start_timestamp_unix"] = start_ts
            result["parsed"]["start_utc"] = datetime.datetime.fromtimestamp(start_ts, tz=datetime.timezone.utc).isoformat() if start_ts > 0 else None
            result["parsed"]["last_sync_timestamp_unix"] = sync_ts
            result["parsed"]["last_sync_utc"] = datetime.datetime.fromtimestamp(sync_ts, tz=datetime.timezone.utc).isoformat() if sync_ts > 0 else None
            result["parsed"]["end_timestamp_unix"] = end_ts
            result["parsed"]["end_utc"] = datetime.datetime.fromtimestamp(end_ts, tz=datetime.timezone.utc).isoformat() if end_ts > 0 else None
            result["parsed"]["flash_storage"] = "512MB NAND Flash"
        elif len(payload) >= 8:
            start_seq = struct.unpack_from("<I", payload, 0)[0]
            end_seq = struct.unpack_from("<I", payload, 4)[0]
            result["parsed"]["start_seq"] = start_seq
            result["parsed"]["end_seq"] = end_seq
            result["parsed"]["total_records_available"] = max(0, end_seq - start_seq)

    elif resp_cmd == 0x91:  # GET_HELLO
        result["parsed"]["hello_raw"] = payload.hex().upper()
        if len(payload) >= 25:
            # Extract serial number at offset 14 (null-terminated ascii)
            sn_part = payload[14:25].split(b"\x00")[0].decode("ascii", errors="replace")
            result["parsed"]["serial_number"] = sn_part
            # Extract session token starting at offset 25
            token_part = payload[25:83].split(b"\x00")[0].decode("ascii", errors="replace")
            result["parsed"]["session_auth_token"] = token_part
        if len(payload) >= 10:
            ts = struct.unpack_from("<I", payload, 6)[0]
            if 1700000000 < ts < 2000000000:
                result["parsed"]["session_timestamp_unix"] = ts
                result["parsed"]["session_timestamp_utc"] = datetime.datetime.fromtimestamp(ts, tz=datetime.timezone.utc).isoformat()

    elif resp_cmd == 0x78:  # SET_FF_VALUE
        result["parsed"]["feature_flag_status"] = "APPLIED" if is_success else f"ERROR_{resp_status}"

    return result


def decode_live_hr_0x28(inner: bytes) -> Dict[str, Any]:
    """
    Decodes Live HR 0x28 packet:
    - inner[0]: 0x28
    - inner[2..5]: Timestamp Unix (u32 LE)
    - inner[8]: Heart Rate BPM (u8)
    - inner[9]: On-Wrist Validity Flag (u8: 0=OFF_WRIST, 1=ON_WRIST_VALID, 2=ON_WRIST_EXTRA)
    - inner[10..11]: RR Interval in ms (u16 LE)
    """
    if len(inner) < 12:
        return {
            "type": "LIVE_HR",
            "opcode": "0x28",
            "status": "TRUNCATED_PACKET",
            "raw_hex": inner.hex().upper(),
            "byte_length": len(inner),
        }

    ts_unix = struct.unpack_from("<I", inner, 2)[0]
    hr_bpm = inner[8]
    wrist_flag = inner[9]
    rr_ms = struct.unpack_from("<H", inner, 10)[0]

    # Map wrist flag
    flag_map = {
        0: "OFF_WRIST",
        1: "ON_WRIST_VALID",
        2: "ON_WRIST_EXTRA",
    }
    wrist_state_str = flag_map.get(wrist_flag, f"UNKNOWN_FLAG_{wrist_flag}")
    is_on_wrist = wrist_flag in (1, 2) and hr_bpm > 0

    ts_utc = None
    if ts_unix > 0:
        try:
            ts_utc = datetime.datetime.fromtimestamp(ts_unix, tz=datetime.timezone.utc).isoformat()
        except Exception:
            ts_utc = None

    return {
        "type": "LIVE_HR",
        "opcode": "0x28",
        "timestamp_unix": ts_unix,
        "timestamp_utc": ts_utc,
        "heart_rate_bpm": hr_bpm,
        "on_wrist_flag": wrist_flag,
        "on_wrist_state": wrist_state_str,
        "is_on_wrist": is_on_wrist,
        "rr_ms": rr_ms if rr_ms > 0 else None,
        "raw_hex": inner.hex().upper(),
    }


def decode_historical_record_0x2F(inner: bytes) -> Dict[str, Any]:
    """
    Decodes Historical Record 0x2F.
    
    FW 50.41.1.0 Frame vs Inner Payload Architecture:
    - Frame on wire (124 bytes total):
        Header (8 bytes): 0xAA 0x01 [len:2B] [role:2B] [crc16:2B]
        Inner Payload (112 bytes): inner_offset = frame_offset - 8
        Trailer (4 bytes): CRC32
    - If a full frame is passed (len >= 124 and frame[0] == 0xAA), inner is auto-extracted.
    
    Layout v18 (Inner Payload = 112 bytes, Frame = 124 bytes):
        inner[0]: Opcode 0x2F [Frame 8]
        inner[1]: Format sub-version 0x12 (v18) [Frame 9]
        inner[2..4]: Sequence (u16 LE) [Frame 10..12]
        inner[7..11]: Timestamp Unix (u32 LE) [Frame 15..19]
        inner[14]: Primary HR BPM (0 = OFF_WRIST) [Frame 22]
        inner[15]: rr_count (0..4) [Frame 23]
        inner[16..24]: RR intervals in ms (u16 LE each, 16+i*2) [Frame 24..32]
        inner[29]: Secondary HR BPM [Frame 37]
        inner[37..49]: Gravity Vector X,Y,Z in g (3x float32 LE) [Frame 45..57]
        inner[57..59]: Steps (u16 LE) [Frame 65..67]
        inner[61..63]: Skin Temp in 0.1 degC (s16 LE) [Frame 69..71] (fallback: 63..65)
        inner[64]: Hardware Activity / Sleep Flag [Frame 72]
        inner[82]: SpO2 candidate [Frame 90]
        inner[96]: Sleep state flag (u8) [Frame 104]
        inner[98..100]: Optical baseline channel 1 (u16 LE) [Frame 106..108]
        inner[106..108]: Optical baseline channel 2 (u16 LE) [Frame 114..116]
        Optical baseline: max(ch1, ch2) (>30000 = on-wrist, 0 = off-wrist)
        
    Layout v26 (PPG Waveform, ~88 bytes inner):
        inner[2..4]: Sequence (u16 LE)
        inner[27..75]: 24 samples i16 LE @ 24Hz
    """
    # Auto-extract inner payload if full 124-byte envelope is passed
    if len(inner) >= 124 and inner[0] == 0xAA and inner[1] == 0x01:
        inner = inner[8 : len(inner) - 4]

    length = len(inner)
    seq = struct.unpack_from("<H", inner, 2)[0] if length >= 4 else None

    format_version = inner[1] if length > 1 else None
    format_hex = f"0x{format_version:02X}" if format_version is not None else None

    # Layout v18 (112 bytes inner payload, min 108 bytes)
    if length >= 108:
        ts_unix = struct.unpack_from("<I", inner, 7)[0]
        primary_hr = inner[14]
        rr_count = min(4, inner[15])
        rr_intervals = []
        for i in range(rr_count):
            if 16 + (i + 1) * 2 <= length:
                val = struct.unpack_from("<H", inner, 16 + i * 2)[0]
                rr_intervals.append(val)

        sec_hr = inner[29] if length > 29 else None
        
        # Accelerometer Gravity Vector: exact inner offset 37..49 (Frame offset 45..57)
        grav_x, grav_y, grav_z = (None, None, None)
        accel_mag_g = None
        if length >= 49:
            grav_x, grav_y, grav_z = struct.unpack_from("<3f", inner, 37)
            accel_mag_g = round((grav_x ** 2 + grav_y ** 2 + grav_z ** 2) ** 0.5, 3)

        # Steps: inner offset 57..59
        steps = struct.unpack_from("<H", inner, 57)[0] if length >= 59 else 0

        # Skin Temperature: inner offset 61..63 (s16 in 0.1 Â°C, e.g. 313 = 31.3Â°C)
        skin_temp_c = None
        if length >= 63:
            raw_temp = struct.unpack_from("<h", inner, 61)[0]
            if 200 <= raw_temp <= 450:
                skin_temp_c = round(raw_temp / 10.0, 1)
            elif length >= 65:
                raw_temp_alt = struct.unpack_from("<h", inner, 63)[0]
                if 200 <= raw_temp_alt <= 450:
                    skin_temp_c = round(raw_temp_alt / 10.0, 1)

        # Sleep state flag: inner offset 96 (and activity flag @ 64)
        sleep_state = inner[96] if length > 96 else (inner[64] if length > 64 else 0)

        spo2_candidate = inner[82] if length > 82 else None

        # Optical baselines: ch1 @ inner 98 (Frame 106), ch2 @ inner 106 (Frame 114)
        opt_ch1 = struct.unpack_from("<H", inner, 98)[0] if length >= 100 else 0
        opt_ch2 = struct.unpack_from("<H", inner, 106)[0] if length >= 108 else 0
        optical_baseline = max(opt_ch1, opt_ch2)

        # High confidence on-wrist determination from hardware baseline (>30000) or non-zero HR
        is_on_wrist = (optical_baseline > 30000) or (primary_hr > 0)

        ts_utc = None
        if ts_unix > 0:
            try:
                ts_utc = datetime.datetime.fromtimestamp(ts_unix, tz=datetime.timezone.utc).isoformat()
            except Exception:
                ts_utc = None

        return {
            "type": "HISTORICAL_RECORD_V18",
            "opcode": "0x2F",
            "format_version": format_version,
            "format_hex": format_hex,
            "sequence": seq,
            "timestamp_unix": ts_unix,
            "timestamp_utc": ts_utc,
            "primary_hr_bpm": primary_hr,
            "secondary_hr_bpm": sec_hr,
            "rr_count": rr_count,
            "rr_intervals_ms": rr_intervals,
            "accel_x": round(grav_x, 3) if grav_x is not None else None,
            "accel_y": round(grav_y, 3) if grav_y is not None else None,
            "accel_z": round(grav_z, 3) if grav_z is not None else None,
            "accel_mag_g": accel_mag_g,
            "gravity_g": {"x": round(grav_x, 3), "y": round(grav_y, 3), "z": round(grav_z, 3)} if grav_x is not None else None,
            "steps": steps,
            "skin_temp_c": skin_temp_c,
            "sleep_state": sleep_state,
            "spo2_candidate": spo2_candidate,
            "optical_baseline_ch1": opt_ch1,
            "optical_baseline_ch2": opt_ch2,
            "optical_baseline": optical_baseline,
            "optical_baseline_106": opt_ch2,
            "is_on_wrist": is_on_wrist,
            "raw_byte_length": length,
            "raw_hex": inner.hex().upper(),
        }

    # Layout v26 (PPG wave, ~88 bytes)
    elif length >= 75:
        ppg_samples = []
        if length >= 75:
            ppg_samples = list(struct.unpack_from("<24h", inner, 27))
        return {
            "type": "HISTORICAL_RECORD_V26_PPG",
            "opcode": "0x2F",
            "format_version": format_version,
            "format_hex": format_hex,
            "sequence": seq,
            "ppg_samples_24hz": ppg_samples,
            "sample_count": len(ppg_samples),
            "raw_byte_length": length,
            "raw_hex": inner.hex().upper(),
        }

    else:
        return {
            "type": "HISTORICAL_RECORD_RAW",
            "opcode": "0x2F",
            "format_version": format_version,
            "format_hex": format_hex,
            "sequence": seq,
            "raw_byte_length": length,
            "raw_hex": inner.hex().upper(),
        }


def decode_cursor_metadata_0x31(inner: bytes) -> Dict[str, Any]:
    """
    Decodes Cursor / Metadata 0x31 packet on fd4b0005 (FW 50.41.1.0).
    Extracts the correct 8-byte NAND flash cursor for 0x17 auto-ACK.
    """
    if len(inner) >= 124 and inner[0] == 0xAA and inner[1] == 0x01:
        inner = inner[8 : len(inner) - 4]

    cursor_hex: Optional[str] = None
    # Il cursore reale a 8 byte nel pacchetto 0x31 si trova all'offset inner[13:21]
    if len(inner) >= 21:
        cursor_bytes = inner[13:21]
        cursor_hex = cursor_bytes.hex().upper()
    elif len(inner) >= 13:
        cursor_bytes = inner[5:13]
        cursor_hex = cursor_bytes.hex().upper()

    return {
        "type": "METADATA_CURSOR",
        "opcode": "0x31",
        "cursor_hex": cursor_hex,
        "byte_length": len(inner),
        "raw_hex": inner.hex().upper(),
    }


def decode_event_0x30(inner: bytes) -> Dict[str, Any]:
    """
    Decodes Hardware Event 0x30 packet on fd4b0004:
    Async strap events (charging, tap, strap state, etc.).
    """
    event_id = inner[1] if len(inner) > 1 else None
    return {
        "type": "HARDWARE_EVENT",
        "opcode": "0x30",
        "event_id": event_id,
        "event_id_hex": f"0x{event_id:02X}" if event_id is not None else None,
        "payload_hex": inner[2:].hex().upper() if len(inner) > 2 else "",
        "raw_hex": inner.hex().upper(),
    }
