import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:universal_ble/universal_ble.dart';
import '../protocol/puffin_framing.dart';
import '../protocol/puffin_commands.dart';
import '../protocol/puffin_decoder.dart';
import '../database/whoop_database.dart';

enum StrapConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
}

class WhoopBleManager extends ChangeNotifier {
  static final WhoopBleManager _instance = WhoopBleManager._();
  static WhoopBleManager get instance => _instance;

  WhoopBleManager._() {
    _initBle();
  }

  // UUIDs
  static const String puffinServiceUuid = 'fd4b0001-cce1-4033-93ce-002d5875f58a';
  static const String charCmdTx = 'fd4b0002-cce1-4033-93ce-002d5875f58a';
  static const String charCmdRx = 'fd4b0003-cce1-4033-93ce-002d5875f58a';
  static const String charEvents = 'fd4b0004-cce1-4033-93ce-002d5875f58a';
  static const String charDataStream = 'fd4b0005-cce1-4033-93ce-002d5875f58a';
  static const String charExtra = 'fd4b0007-cce1-4033-93ce-002d5875f58a';
  static const String charStandardHr = '00002a37-0000-1000-8000-00805f9b34fb';

  // Protocol & Reassembly
  final PuffinCommandBuilder _cmdBuilder = PuffinCommandBuilder();
  final PuffinStreamReassembler _cmdReassembler = PuffinStreamReassembler();
  final PuffinStreamReassembler _streamReassembler = PuffinStreamReassembler();

  // Command queue & synchronization
  Completer<CommandResponse0x24>? _pendingCmdCompleter;
  final List<Function> _commandQueue = [];
  bool _isSending = false;

  // Cursor Auto-ACK state
  String? _lastAckedCursor;

  // Discovered devices list for manual user selection
  final List<BleDevice> _discoveredDevices = [];

  // Device Info & Live State
  BleDevice? _targetDevice;
  StrapConnectionState _connectionState = StrapConnectionState.disconnected;
  String _deviceName = 'WHOOP Strap';
  String _serialNumber = '--';
  String _firmwareVersion = '--';
  int _batteryLevel = 0;
  int _liveHr = 0;
  bool _isOnWrist = false;
  int _opticalBaseline = 0;
  double _skinTempC = 0.0;
  List<int> _liveRrMs = [];
  bool _isSyncing = false;
  double _syncProgress = 0.0;
  int _syncTotalPackets = 0;
  int _syncUniqueSaved = 0;
  double _syncSpeed = 0.0;

  // Historical Batch Buffer
  final List<HistoricalRecordV18> _v18Buffer = [];
  Timer? _batchFlushTimer;

  // Public Getters
  StrapConnectionState get connectionState => _connectionState;
  List<BleDevice> get discoveredDevices => List.unmodifiable(_discoveredDevices);
  BleDevice? get targetDevice => _targetDevice;
  String get deviceName => _deviceName;
  String get serialNumber => _serialNumber;
  String get firmwareVersion => _firmwareVersion;
  int get batteryLevel => _batteryLevel;
  int get liveHr => _liveHr;
  bool get isOnWrist => _isOnWrist;
  int get opticalBaseline => _opticalBaseline;
  double get skinTempC => _skinTempC;
  List<int> get liveRrMs => _liveRrMs;
  bool get isSyncing => _isSyncing;
  double get syncProgress => _syncProgress;
  int get syncTotalPackets => _syncTotalPackets;
  int get syncUniqueSaved => _syncUniqueSaved;
  double get syncSpeed => _syncSpeed;

  void _initBle() {
    UniversalBle.onConnectionChange = (BleConnectionChange change) {
      if (change.isConnected) {
        _setConnectionState(StrapConnectionState.connected);
      } else {
        _liveHr = 0;
        _liveRrMs = [];
        _isOnWrist = false;
        _setConnectionState(StrapConnectionState.disconnected);
        if (_targetDevice != null) {
          _reconnectWithBackoff();
        }
      }
    };

    UniversalBle.onValueChange = (BleCharacteristicValue charVal) {
      _handleIncomingData(charVal.characteristicId.toLowerCase(), charVal.value);
    };

    // Periodic flush timer for historical batches
    _batchFlushTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _flushV18Buffer();
    });
  }

  void _setConnectionState(StrapConnectionState state) {
    _connectionState = state;
    notifyListeners();
  }

  /// Starts scanning for devices without auto-connecting, letting the user choose.
  Future<void> startScan() async {
    if (_connectionState == StrapConnectionState.connected ||
        _connectionState == StrapConnectionState.connecting) {
      return;
    }

    _discoveredDevices.clear();
    _setConnectionState(StrapConnectionState.scanning);

    UniversalBle.onScanResult = handleDiscoveredDevice;

    try {
      await UniversalBle.startScan();
    } catch (e) {
      debugPrint('[BLE] Start scan error: $e');
      _setConnectionState(StrapConnectionState.disconnected);
    }
  }

  /// Handles incoming BLE discovery without auto-connecting.
  void handleDiscoveredDevice(BleDevice device) {
    String name = (device.name ?? '').trim();

    // STRICT BLACKLIST: Never discover or connect to WHOOP A (5A00479315)
    if (name.toUpperCase().contains('5A00479315') ||
        device.deviceId.toUpperCase().contains('5A00479315')) {
      return;
    }

    bool matchName = name.toUpperCase().contains('WHOOP');
    bool matchService = false;
    if (device.services != null) {
      matchService = device.services!.any((s) => s.toLowerCase().contains('fd4b'));
    }

    // Record any device that is a WHOOP or broadcasts an identifiable name
    if (matchName || matchService || name.isNotEmpty) {
      int idx = _discoveredDevices.indexWhere(
        (d) => d.deviceId.toUpperCase() == device.deviceId.toUpperCase(),
      );
      if (idx >= 0) {
        _discoveredDevices[idx] = device;
      } else {
        // Prioritize WHOOP straps at the top of the list
        if (matchName || matchService) {
          _discoveredDevices.insert(0, device);
        } else {
          _discoveredDevices.add(device);
        }
      }
      notifyListeners();
    }
  }

  /// Stops ongoing scan.
  Future<void> stopScan() async {
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    if (_connectionState == StrapConnectionState.scanning) {
      _setConnectionState(StrapConnectionState.disconnected);
    }
  }

  /// Connects explicitly to the user-selected device.
  Future<void> connectToDevice(BleDevice device) async {
    String name = (device.name ?? '').trim();
    if (name.toUpperCase().contains('5A00479315') ||
        device.deviceId.toUpperCase().contains('5A00479315')) {
      debugPrint('[BLE] Connection rejected: Target device is blacklisted WHOOP A');
      return;
    }

    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    await _connectToDevice(device);
  }

  /// Scans for devices. If [specificAddress] is provided, connects automatically upon discovery.
  /// If null, begins scanning and lets the user choose the device from [discoveredDevices].
  Future<void> connect({String? specificAddress}) async {
    if (_connectionState == StrapConnectionState.connected ||
        _connectionState == StrapConnectionState.connecting) {
      return;
    }

    if (specificAddress != null) {
      _setConnectionState(StrapConnectionState.scanning);
      UniversalBle.onScanResult = (device) {
        String name = (device.name ?? '').trim();
        // Strict Blacklist WHOOP A
        if (name.toUpperCase().contains('5A00479315') ||
            device.deviceId.toUpperCase().contains('5A00479315')) {
          return;
        }

        // Match normalized MAC address or specific model name (e.g. 5WP), never fuzzy match general 'WHOOP'
        String cleanSpecific = specificAddress.replaceAll(':', '').replaceAll('-', '').toUpperCase();
        String cleanDevId = device.deviceId.replaceAll(':', '').replaceAll('-', '').toUpperCase();

        bool match = cleanDevId.contains(cleanSpecific) ||
            device.deviceId.toUpperCase().contains(specificAddress.toUpperCase()) ||
            name.toUpperCase().contains('5WP');

        if (match) {
          UniversalBle.stopScan();
          _targetDevice = device;
          _connectToDevice(device);
        }
      };
      try {
        await UniversalBle.startScan();
      } catch (e) {
        debugPrint('[BLE] Start scan error: $e');
        _setConnectionState(StrapConnectionState.disconnected);
      }
    } else {
      await startScan();
    }
  }

  /// Disconnects manually, resets live state, and clears target device and scan list.
  Future<void> disconnect() async {
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
    if (_targetDevice != null) {
      try {
        await UniversalBle.disconnect(_targetDevice!.deviceId);
      } catch (e) {
        debugPrint('[BLE] Disconnect error: $e');
      }
    }
    _targetDevice = null;
    _discoveredDevices.clear();
    _liveHr = 0;
    _liveRrMs = [];
    _opticalBaseline = 0;
    _skinTempC = 0.0;
    _isOnWrist = false;
    _setConnectionState(StrapConnectionState.disconnected);
  }

  Future<void> _connectToDevice(BleDevice device) async {
    _setConnectionState(StrapConnectionState.connecting);
    try {
      await UniversalBle.connect(device.deviceId);
      _targetDevice = device;
      _deviceName = device.name ?? 'WHOOP Strap';

      // Discover services & subscribe
      await UniversalBle.discoverServices(device.deviceId);
      await Future.delayed(const Duration(milliseconds: 500));
      await _subscribeNotifications(device.deviceId);

      // Perform handshake & unlock session
      await _performUnlockHandshake();
    } catch (e) {
      debugPrint('[BLE] Connect error: $e');
      _setConnectionState(StrapConnectionState.disconnected);
      _reconnectWithBackoff();
    }
  }

  Future<void> _subscribeNotifications(String deviceId) async {
    List<String> charsToSubscribe = [
      charCmdRx,
      charEvents,
      charDataStream,
      charExtra,
      charStandardHr,
    ];

    for (String charId in charsToSubscribe) {
      try {
        await UniversalBle.subscribeNotifications(
          deviceId,
          puffinServiceUuid,
          charId,
        );
      } catch (e) {
        // Characteristic may not be present or already subscribed
      }
    }
  }

  /// Session Unlock Sequence: 0x91 GET_HELLO + 16 Feature Flags (0x78).
  Future<void> _performUnlockHandshake() async {
    try {
      // 1. GET_HELLO (0x91)
      var helloResp = await sendCommand(PuffinOpcodes.getHello);
      if (helloResp != null && helloResp.payload.length >= 24) {
        String raw = String.fromCharCodes(helloResp.payload.where((b) => b >= 32 && b <= 126));
        if (raw.length >= 10) {
          _serialNumber = raw.substring(0, 10);
        }
      }

      // 2. GET_NAME (0x8D)
      var nameResp = await sendCommand(PuffinOpcodes.getAdvertisingName);
      if (nameResp != null && nameResp.payload.isNotEmpty) {
        _deviceName = String.fromCharCodes(nameResp.payload.where((b) => b >= 32 && b <= 126));
      }

      // 3. GET_BATTERY (0x1A)
      var battResp = await sendCommand(PuffinOpcodes.getBattery);
      if (battResp != null && battResp.payload.isNotEmpty) {
        _batteryLevel = battResp.payload[0];
      }

      // 4. Register in database
      await WhoopDatabase.instance.registerDevice(
        serialNumber: _serialNumber,
        macAddress: _targetDevice?.deviceId ?? '',
        model: _deviceName,
        fwRevision: _firmwareVersion,
      );

      // 5. Unlock 16 Feature Flags (0x78)
      for (int flagId in puffin16FeatureFlags) {
        await sendCommand(
          PuffinOpcodes.setFeatureFlag,
          params: Uint8List.fromList([flagId, 0x01]),
        );
      }

      notifyListeners();
    } catch (e) {
      debugPrint('[BLE] Handshake error: $e');
    }
  }

  /// Serialized command dispatch with response Completer.
  Future<CommandResponse0x24?> sendCommand(
    int cmd, {
    int b3 = 0x01,
    Uint8List? params,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_targetDevice == null || _connectionState != StrapConnectionState.connected) {
      return null;
    }

    Completer<CommandResponse0x24?> execCompleter = Completer();

    _commandQueue.add(() async {
      try {
        _pendingCmdCompleter = Completer<CommandResponse0x24>();

        Uint8List frame = _cmdBuilder.buildCommand(
          cmd: cmd,
          b3: b3,
          params: params,
        );

        // Write with response (withoutResponse: false) on fd4b0002
        await UniversalBle.write(
          _targetDevice!.deviceId,
          puffinServiceUuid,
          charCmdTx,
          frame,
          withoutResponse: false,
        );

        // Await response with timeout
        var resp = await _pendingCmdCompleter!.future.timeout(
          timeout,
          onTimeout: () => throw TimeoutException('Command 0x${cmd.toRadixString(16)} timeout'),
        );
        execCompleter.complete(resp);
      } catch (e) {
        debugPrint('[BLE] sendCommand error: $e');
        execCompleter.complete(null);
      } finally {
        _pendingCmdCompleter = null;
        _isSending = false;
        _processNextCommand();
      }
    });

    if (!_isSending) {
      _processNextCommand();
    }

    return execCompleter.future;
  }

  void _processNextCommand() {
    if (_commandQueue.isEmpty || _isSending) return;
    _isSending = true;
    var nextTask = _commandQueue.removeAt(0);
    nextTask();
  }

  /// Sends 0x42 Alarm Vibration command (Duration up to 5000ms, pattern 0 or 1).
  Future<bool> sendAlarmVibration({int pattern = 1, int durationMs = 1500}) async {
    if (_targetDevice == null || _connectionState != StrapConnectionState.connected) {
      return false;
    }
    ByteData bd = ByteData(3);
    bd.setUint8(0, pattern & 0xFF);
    bd.setUint16(1, durationMs & 0xFFFF, Endian.little);
    var resp = await sendCommand(PuffinOpcodes.alarmControl, params: bd.buffer.asUint8List());
    return resp != null && resp.isSuccess;
  }

  /// High-throughput Turbo-Sync historical data offload.
  Future<void> startHistoricalSync({int durationSeconds = 30}) async {
    if (_targetDevice == null || _connectionState != StrapConnectionState.connected) {
      return;
    }

    _isSyncing = true;
    _syncProgress = 0.0;
    _syncTotalPackets = 0;
    _syncUniqueSaved = 0;
    _syncSpeed = 0.0;
    notifyListeners();

    int startTs = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    int targetEndTs = startTs + durationSeconds;

    ByteData bd = ByteData(4);
    bd.setUint32(0, targetEndTs, Endian.little);
    await sendCommand(
      PuffinOpcodes.sendHistorical,
      b3: 0x00,
      params: bd.buffer.asUint8List(),
      timeout: const Duration(seconds: 5),
    );

    // Monitor progress
    int elapsed = 0;
    Timer.periodic(const Duration(seconds: 1), (timer) {
      elapsed++;
      _syncProgress = (elapsed / durationSeconds).clamp(0.0, 1.0);
      if (elapsed > 0) {
        _syncSpeed = double.parse((_syncTotalPackets / elapsed).toStringAsFixed(1));
      }
      notifyListeners();

      if (elapsed >= durationSeconds || !_isSyncing) {
        timer.cancel();
        _isSyncing = false;
        _flushV18Buffer();
        notifyListeners();
      }
    });
  }

  void stopHistoricalSync() {
    _isSyncing = false;
    _flushV18Buffer();
    notifyListeners();
  }

  /// Inbound characteristic multiplexer.
  void _handleIncomingData(String charId, Uint8List rawChunk) {
    if (charId.contains('fd4b0003')) {
      // Command Responses (0x24)
      var frames = _cmdReassembler.feed(rawChunk);
      for (var f in frames) {
        Uint8List inner = extractInnerPayload(f);
        var resp = PuffinDecoder.decodeResponse0x24(inner);
        if (resp != null && _pendingCmdCompleter != null && !_pendingCmdCompleter!.isCompleted) {
          _pendingCmdCompleter!.complete(resp);
        }
      }
    } else if (charId.contains('fd4b0005')) {
      // Data Stream (0x28 live, 0x2F v18, 0x31 cursor)
      var frames = _streamReassembler.feed(rawChunk);
      for (var f in frames) {
        _syncTotalPackets++;
        Uint8List inner = extractInnerPayload(f);
        int opcode = inner.isNotEmpty ? inner[0] : 0;

        if (opcode == 0x28) {
          // Live Heart Rate packet
          var live = PuffinDecoder.decodeLiveHr0x28(inner);
          if (live != null) {
            _liveHr = live.primaryHr;
            _isOnWrist = true;
            notifyListeners();
          }
        } else if (opcode == 0x2F) {
          // Historical v18 record
          var v18 = PuffinDecoder.decodeHistoricalV18(inner);
          if (v18 != null) {
            _isOnWrist = v18.isOnWrist;
            _opticalBaseline = v18.opticalBaseline;
            _skinTempC = v18.skinTempC;
            if (v18.primaryHr > 0) _liveHr = v18.primaryHr;
            if (v18.rrIntervalsMs.isNotEmpty) _liveRrMs = v18.rrIntervalsMs;
            _v18Buffer.add(v18);
            if (_v18Buffer.length >= 25) {
              _flushV18Buffer();
            }
            notifyListeners();
          }
        } else if (opcode == 0x31) {
          // Cursor metadata -> Deduplicated Auto-ACK
          var cursorMeta = PuffinDecoder.decodeCursor0x31(inner);
          if (cursorMeta != null) {
            String cHex = cursorMeta.cursorHex;
            if (cHex != _lastAckedCursor) {
              _lastAckedCursor = cHex;
              _sendCursorAck(cursorMeta.cursorBytes);

              // Update DB checkpoint
              if (_v18Buffer.isNotEmpty) {
                WhoopDatabase.instance.updateSyncCheckpoint(
                  serialNumber: _serialNumber,
                  syncTimestampUnix: _v18Buffer.last.timestampUnix,
                  cursorHex: cHex,
                );
              }
            }
          }
        }
      }
    } else if (charId.contains('2a37')) {
      // Standard BLE Heart Rate
      var stdHr = PuffinDecoder.decodeStandardHr0x2A37(rawChunk);
      int hr = stdHr['hr'] as int;
      if (hr > 0) {
        _liveHr = hr;
        var rrs = stdHr['rr_ms'];
        if (rrs is List<int> && rrs.isNotEmpty) {
          _liveRrMs = List<int>.from(rrs);
        }
        notifyListeners();
      }
    }
  }

  void _sendCursorAck(Uint8List cursor8b) {
    // Send single 0x17 ACK with 8-byte cursor (low latency 800ms)
    sendCommand(
      PuffinOpcodes.historicalDataResult,
      b3: 0x01,
      params: cursor8b,
      timeout: const Duration(milliseconds: 800),
    );
  }

  Future<void> _flushV18Buffer() async {
    if (_v18Buffer.isEmpty) return;

    List<HistoricalRecordV18> batch = List.from(_v18Buffer);
    _v18Buffer.clear();

    try {
      var stats = await WhoopDatabase.instance.ingestRecordsBatch(_serialNumber, batch);
      _syncUniqueSaved += stats['records_inserted'] ?? 0;
    } catch (e) {
      debugPrint('[DB] Batch flush error: $e');
    }
  }

  void _reconnectWithBackoff() async {
    if (_targetDevice == null) return;
    await Future.delayed(const Duration(seconds: 3));
    if (_connectionState == StrapConnectionState.disconnected && _targetDevice != null) {
      _connectToDevice(_targetDevice!);
    }
  }

  void cancelTimers() {
    _batchFlushTimer?.cancel();
    _batchFlushTimer = null;
  }

  @override
  void dispose() {
    cancelTimers();
    super.dispose();
  }
}
