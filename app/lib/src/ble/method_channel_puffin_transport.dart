import 'dart:async';
import 'package:flutter/services.dart';

import 'ble_connection_state.dart';
import 'puffin_frame_codec.dart';
import 'puffin_transport.dart';

/// Implementazione concreta di [PuffinTransport] che comunica tramite
/// [MethodChannel] con il modulo nativo Android (`beveltry-ble`).
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

  @override
  Stream<PuffinIncomingFrame> get incomingFrames =>
      _incomingFramesController.stream;

  @override
  Stream<Uint8List> get standardHrStream => _standardHrController.stream;

  @override
  Stream<bool> get onConnectionChanged => _connectionChangeController.stream;

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
      case 'onBondingStarted':
        _onBondingStartedCallback?.call();
      case 'onStandardHr':
        final bytes = call.arguments as Uint8List;
        _standardHrController.add(bytes);
        break;

      case 'onConnectionChanged':
        final connected = call.arguments as bool;
        _isConnected = connected;
        _connectionChangeController.add(connected);
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
      case 'onDisconnected':
        _isConnected = false;
        _connectedDevice = null;
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
        // Ignora eccezioni se la scansione è già terminata
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
}
