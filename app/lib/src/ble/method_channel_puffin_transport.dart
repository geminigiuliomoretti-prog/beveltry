import 'dart:async';
import 'package:flutter/services.dart';

import 'ble_connection_state.dart';
import 'puffin_frame_codec.dart';
import 'puffin_transport.dart';

/// Implementazione concreta di [PuffinTransport] che comunica tramite
/// [MethodChannel] con il modulo nativo Android (`beveltry-ble` e `WhoopConnectionService`).
class MethodChannelPuffinTransport implements PuffinTransport {
  MethodChannelPuffinTransport({
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('com.beveltry/ble') {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  final MethodChannel _channel;
  bool _isConnected = false;
  WhoopDiscoveredDevice? _connectedDevice;

  final StreamController<List<WhoopDiscoveredDevice>> _devicesController =
      StreamController<List<WhoopDiscoveredDevice>>.broadcast();
  final List<WhoopDiscoveredDevice> _discoveredList = [];

  final StreamController<PuffinIncomingFrame> _incomingFramesController =
      StreamController<PuffinIncomingFrame>.broadcast();
  final StreamController<Uint8List> _standardHrController =
      StreamController<Uint8List>.broadcast();
  final StreamController<bool> _connectionChangeController =
      StreamController<bool>.broadcast();

  // Event stream avanzati per integrazione nativa foreground service
  final StreamController<Map<String, dynamic>> _connectionStateChangedController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _syncProgressController =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _live28Controller =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<int> _liveHrBpmController =
      StreamController<int>.broadcast();
  final StreamController<int> _liveRrMsController =
      StreamController<int>.broadcast();
  final StreamController<Map<String, dynamic>> _nightRecorderUpdateController =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<PuffinIncomingFrame> get incomingFrames =>
      _incomingFramesController.stream;

  @override
  Stream<Uint8List> get standardHrStream => _standardHrController.stream;

  @override
  Stream<bool> get onConnectionChanged => _connectionChangeController.stream;

  Stream<Map<String, dynamic>> get onConnectionStateChanged =>
      _connectionStateChangedController.stream;

  Stream<Map<String, dynamic>> get onSyncProgress =>
      _syncProgressController.stream;

  Stream<Map<String, dynamic>> get onLive28 => _live28Controller.stream;

  Stream<int> get onLiveHrBpm => _liveHrBpmController.stream;

  Stream<int> get onLiveRrMs => _liveRrMsController.stream;

  Stream<Map<String, dynamic>> get onNightRecorderUpdate =>
      _nightRecorderUpdateController.stream;

  void Function()? _onBondingStartedCallback;

  @override
  bool get isConnected => _isConnected;

  WhoopDiscoveredDevice? get connectedDevice => _connectedDevice;

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onDeviceDiscovered':
        final map = Map<String, dynamic>.from(call.arguments as Map);
        final device = WhoopDiscoveredDevice(
          name: map['name'] as String? ?? 'WHOOP 5.0',
          macAddress: map['macAddress'] as String,
          rssi: map['rssi'] as int?,
        );
        if (!_discoveredList.contains(device)) {
          _discoveredList.add(device);
          _devicesController.add(List.unmodifiable(_discoveredList));
        }
        break;

      case 'onBondingStarted':
        _onBondingStartedCallback?.call();
        break;

      case 'onStandardHr':
        final arg = call.arguments;
        if (arg is Uint8List) {
          _standardHrController.add(arg);
        } else if (arg is Map) {
          final map = Map<String, dynamic>.from(arg);
          final hr = map['hr'] as int?;
          if (hr != null) _liveHrBpmController.add(hr);
          final rrList = (map['rrIntervalsMs'] as List?)?.cast<int>();
          if (rrList != null && rrList.isNotEmpty) {
            _liveRrMsController.add(rrList.last);
          }
        }
        break;

      case 'onLive28':
        final map = Map<String, dynamic>.from(call.arguments as Map);
        _live28Controller.add(map);
        final hr = map['hr'] as int?;
        if (hr != null && hr > 0) _liveHrBpmController.add(hr);
        final rr = map['rrIntervalMs'] as int?;
        if (rr != null && rr > 0) _liveRrMsController.add(rr);
        break;

      case 'onConnectionChanged':
        final connected = call.arguments as bool;
        _isConnected = connected;
        _connectionChangeController.add(connected);
        break;

      case 'onConnectionStateChanged':
        final map = Map<String, dynamic>.from(call.arguments as Map);
        _connectionStateChangedController.add(map);
        final connected = map['isConnected'] as bool? ?? false;
        if (connected != _isConnected) {
          _isConnected = connected;
          _connectionChangeController.add(connected);
        }
        break;

      case 'onSyncProgress':
        final map = Map<String, dynamic>.from(call.arguments as Map);
        _syncProgressController.add(map);
        break;

      case 'onNightRecorderUpdate':
        final map = Map<String, dynamic>.from(call.arguments as Map);
        _nightRecorderUpdateController.add(map);
        final hr = map['lastHrBpm'] as int?;
        if (hr != null && hr > 0) _liveHrBpmController.add(hr);
        break;

      case 'onFrameReceived':
        final map = Map<String, dynamic>.from(call.arguments as Map);
        final rawBytes = map['payload'] as Uint8List?;
        final charStr = map['characteristic'] as String?;
        final field = map['field'] as int? ?? 1;
        if (rawBytes != null) {
          final char = switch (charStr) {
            'CMD_FROM_STRAP' || 'cmdFromStrap' => PuffinCharacteristic.cmdFromStrap,
            'EVENTS_FROM_STRAP' || 'eventsFromStrap' => PuffinCharacteristic.eventsFromStrap,
            'DATA_FROM_STRAP' || 'dataFromStrap' => PuffinCharacteristic.dataFromStrap,
            'MEMFAULT' || 'memfault' => PuffinCharacteristic.memfault,
            _ => PuffinCharacteristic.cmdFromStrap,
          };
          final frame = PuffinFrame(
            field: field,
            payload: rawBytes,
            rawPayload: rawBytes,
            headerCRC: 0,
            payloadCRC: 0,
          );
          _incomingFramesController.add(
            PuffinIncomingFrame(frame: frame, characteristic: char),
          );
        }
        break;

      case 'onDisconnected':
        _isConnected = false;
        _connectedDevice = null;
        _connectionChangeController.add(false);
        break;
    }
  }

  @override
  Stream<List<WhoopDiscoveredDevice>> scan({
    Duration timeout = const Duration(seconds: 10),
  }) async* {
    _discoveredList.clear();
    yield const [];
    try {
      await _channel.invokeMethod('startScan', {
        'timeoutMillis': timeout.inMilliseconds,
      });
      yield* _devicesController.stream;
    } finally {
      try {
        await _channel.invokeMethod('stopScan');
      } catch (_) {
        // Ignora se già terminata
      }
    }
  }

  @override
  Future<bool> connectAndBond(
    WhoopDiscoveredDevice device, {
    void Function()? onBondingStarted,
    void Function(String message)? onRetryProgress,
  }) async {
    _onBondingStartedCallback = onBondingStarted;
    try {
      final success = await _channel.invokeMethod<bool>('connectAndBond', {
        'macAddress': device.macAddress,
        'name': device.name,
      });
      _isConnected = success == true;
      if (_isConnected) {
        _connectedDevice = device;
      }
      return _isConnected;
    } catch (e) {
      _isConnected = false;
      _connectedDevice = null;
      rethrow;
    } finally {
      _onBondingStartedCallback = null;
    }
  }

  /// Avvia la sincronizzazione dello storico tramite il Foreground Service nativo Kotlin.
  Future<bool> startNativeSync({Duration timeout = const Duration(seconds: 60)}) async {
    final started = await _channel.invokeMethod<bool>('startSync', {
      'timeoutMillis': timeout.inMilliseconds,
    });
    return started == true;
  }

  /// Interrompe la sincronizzazione dello storico nel servizio nativo.
  Future<void> stopNativeSync() async {
    await _channel.invokeMethod('stopSync');
  }

  /// Invia il comando di feedback aptico/vibrazione (0x13 / 0x42).
  Future<bool> sendNativeVibration({int pattern = 0x02, int loops = 0x03}) async {
    final ok = await _channel.invokeMethod<bool>('sendVibration', {
      'pattern': pattern,
      'loops': loops,
    });
    return ok == true;
  }

  /// Abilita o disabilita lo stream HR realtime (comando 0x13).
  Future<bool> setRealtimeHr({required bool enable}) async {
    final ok = await _channel.invokeMethod<bool>('setRealtimeHr', {
      'enable': enable,
    });
    return ok == true;
  }

  @override
  Future<void> write(
    Uint8List frame, {
    PuffinCharacteristic characteristic = PuffinCharacteristic.cmdToStrap,
  }) async {
    await _channel.invokeMethod('writeFrame', {
      'frame': frame,
      'characteristic': characteristic.name,
    });
  }

  @override
  Future<void> disconnect() async {
    await _channel.invokeMethod('disconnect');
    _isConnected = false;
    _connectedDevice = null;
  }

  // =========================================================================
  // METODI NIGHT RECORDER (Task 07)
  // =========================================================================

  /// Avvia la registrazione notturna nel foreground service nativo.
  Future<bool> startNightRecording(String sessionId) async {
    final ok = await _channel.invokeMethod<bool>('startNightRecording', {
      'sessionId': sessionId,
    });
    return ok == true;
  }

  /// Conclude la registrazione notturna nel servizio nativo e restituisce il sommario.
  Future<Map<String, dynamic>> stopNightRecording() async {
    final result = await _channel.invokeMethod<Map>('stopNightRecording');
    return result != null ? Map<String, dynamic>.from(result) : {};
  }

  /// Interroga lo stato attivo del Night Recorder.
  Future<Map<String, dynamic>> getNightRecordingStatus() async {
    final result = await _channel.invokeMethod<Map>('getNightRecordingStatus');
    return result != null ? Map<String, dynamic>.from(result) : {};
  }

  /// Recupera il riepilogo statistico della sessione notturna.
  Future<Map<String, dynamic>> getNightRecordingSummary(String sessionId) async {
    final result = await _channel.invokeMethod<Map>('getNightRecordingSummary', {
      'sessionId': sessionId,
    });
    return result != null ? Map<String, dynamic>.from(result) : {};
  }
}
