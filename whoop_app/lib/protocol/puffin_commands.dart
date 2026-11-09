import 'dart:convert';
import 'dart:typed_data';
import 'puffin_framing.dart';

class PuffinOpcodes {
  static const int getHello = 0x91;
  static const int getAdvertisingName = 0x8D;
  static const int setClock = 0x0A;
  static const int getClock = 0x0B;
  static const int getBattery = 0x1A;
  static const int setFeatureFlag = 0x78;
  static const int getDataRange = 0x22;
  static const int sendHistorical = 0x16;
  static const int historicalDataResult = 0x17;
  static const int alarmControl = 0x42;
  static const int keyExchange = 0x73;

  static const int eraseFlash = 0x19;
  static const int rebootStrap = 0x1D;

  static const Set<int> allowedOpcodes = {
    getHello,
    getAdvertisingName,
    setClock,
    getClock,
    getBattery,
    setFeatureFlag,
    getDataRange,
    sendHistorical,
    historicalDataResult,
    alarmControl,
    keyExchange,
  };
}

const Map<String, int> puffin16FeatureFlagsMap = {
  'enable_r22_packets': 2,
  'enable_r22_v2_packets': 2,
  'enable_r22_v3_packets': 2,
  'enable_r22_v4_packets': 1,
  'enable_r22_v5_packets': 2,
  'enable_r22_v6_packets': 2,
  'enable_r22_v8_packets': 2,
  'make_hrfm_visible': 2,
  'disable_pip_r26_packets': 2,
  'wear_detect_bias': 2,
  'hr_ch_switching': 2,
  'ir_hw_switching': 2,
  'enable_passive_strap_fit_gen5': 1,
  'enable_sig11_during_sleep': 2,
  'dorset_inhibit_wpt': 2,
  'enable_sig12': 2,
};

const List<int> puffin16FeatureFlags = [
  0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
  0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
];

class PuffinCommandBuilder {
  int _sequence = 0;

  int nextSequence() {
    _sequence = (_sequence + 1) & 0xFF;
    if (_sequence == 0) _sequence = 1;
    return _sequence;
  }

  Uint8List buildCommand({
    required int cmd,
    int b3 = 0x01,
    Uint8List? params,
    int? explicitSeq,
    int field = 0x0001,
  }) {
    if (cmd == PuffinOpcodes.eraseFlash || cmd == PuffinOpcodes.rebootStrap) {
      throw SecurityException(
        "OPCODE 0x" + cmd.toRadixString(16).padLeft(2, '0').toUpperCase() + " IS DANGEROUS AND STRICTLY BLOCKED.",
      );
    }

    if (!PuffinOpcodes.allowedOpcodes.contains(cmd)) {
      throw SecurityException(
        "Opcode 0x" + cmd.toRadixString(16).padLeft(2, '0').toUpperCase() + " not in safety allowlist.",
      );
    }

    int seq = explicitSeq ?? nextSequence();
    int paramLen = params != null ? params.length : 0;
    Uint8List inner = Uint8List(4 + paramLen);
    inner[0] = 0x23;
    inner[1] = seq & 0xFF;
    inner[2] = cmd & 0xFF;
    inner[3] = b3 & 0xFF;

    if (params != null && params.isNotEmpty) {
      inner.setRange(4, 4 + paramLen, params);
    }

    return buildPuffinFrame(inner, field: field);
  }

  Uint8List buildGetHello({int? seq}) =>
      buildCommand(cmd: PuffinOpcodes.getHello, b3: 0x01, explicitSeq: seq);

  Uint8List buildGetName({int? seq}) =>
      buildCommand(cmd: PuffinOpcodes.getAdvertisingName, b3: 0x01, explicitSeq: seq);

  Uint8List buildGetClock({int? seq}) =>
      buildCommand(cmd: PuffinOpcodes.getClock, b3: 0x00, explicitSeq: seq);

  Uint8List buildSetClock(int unixTimestamp, {int? seq}) {
    ByteData bd = ByteData(4);
    bd.setUint32(0, unixTimestamp, Endian.little);
    return buildCommand(
      cmd: PuffinOpcodes.setClock,
      b3: 0x01,
      params: bd.buffer.asUint8List(),
      explicitSeq: seq,
    );
  }

  Uint8List buildGetBattery({int? seq}) =>
      buildCommand(cmd: PuffinOpcodes.getBattery, b3: 0x01, explicitSeq: seq);

  Uint8List buildSetFeatureFlagNamed(String name, int value, {int? seq}) {
    List<int> asciiBytes = ascii.encode(name);
    Uint8List params = Uint8List(33);
    int copyLen = asciiBytes.length > 32 ? 32 : asciiBytes.length;
    params.setRange(0, copyLen, asciiBytes.sublist(0, copyLen));
    params[32] = value & 0xFF;
    return buildCommand(
      cmd: PuffinOpcodes.setFeatureFlag,
      b3: 0x01,
      params: params,
      explicitSeq: seq,
    );
  }

  Uint8List buildSetFeatureFlag(int flagId, int value, {int? seq}) {
    Uint8List params = Uint8List.fromList([flagId & 0xFF, value & 0xFF]);
    return buildCommand(
      cmd: PuffinOpcodes.setFeatureFlag,
      b3: 0x01,
      params: params,
      explicitSeq: seq,
    );
  }

  Uint8List buildGetDataRange({int? seq}) =>
      buildCommand(cmd: PuffinOpcodes.getDataRange, b3: 0x00, explicitSeq: seq);

  Uint8List buildSendHistorical({int b3 = 0x00, Uint8List? params, int? seq}) =>
      buildCommand(cmd: PuffinOpcodes.sendHistorical, b3: b3, params: params, explicitSeq: seq);

  Uint8List buildHistoricalDataResult(Uint8List cursor8b, {int? seq}) {
    if (cursor8b.length != 8) {
      throw ArgumentError("Cursor must be exactly 8 bytes (received " + cursor8b.length.toString() + ")");
    }
    return buildCommand(
      cmd: PuffinOpcodes.historicalDataResult,
      b3: 0x01,
      params: cursor8b,
      explicitSeq: seq,
    );
  }

  Uint8List buildAlarmControl({int pattern = 1, int durationMs = 1000, int? seq}) {
    ByteData bd = ByteData(3);
    bd.setUint8(0, pattern & 0xFF);
    bd.setUint16(1, durationMs & 0xFFFF, Endian.little);
    return buildCommand(
      cmd: PuffinOpcodes.alarmControl,
      b3: 0x01,
      params: bd.buffer.asUint8List(),
      explicitSeq: seq,
    );
  }
}

class SecurityException implements Exception {
  final String message;
  SecurityException(this.message);
  @override
  String toString() => 'SecurityException: ' + message;
}
