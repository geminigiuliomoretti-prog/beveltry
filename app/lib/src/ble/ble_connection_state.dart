import 'package:flutter/foundation.dart';

/// Dispositivo WHOOP individuato durante la scansione BLE.
@immutable
class WhoopDiscoveredDevice {
  const WhoopDiscoveredDevice({
    required this.name,
    required this.macAddress,
    this.rssi,
  });

  final String name;
  final String macAddress;
  final int? rssi;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WhoopDiscoveredDevice &&
          runtimeType == other.runtimeType &&
          macAddress == other.macAddress;

  @override
  int get hashCode => macAddress.hashCode;

  @override
  String toString() =>
      'WhoopDiscoveredDevice(name: $name, mac: $macAddress, rssi: $rssi)';
}

/// Stati possibili del ciclo di vita della connessione BLE con WHOOP.
@immutable
sealed class BleConnectionStatus {
  const BleConnectionStatus();

  bool get isConnected => this is BleStatusConnected;
  bool get isConnectingOrBonding =>
      this is BleStatusConnecting || this is BleStatusBonding;
  bool get isScanning => this is BleStatusScanning;
}

/// Disconnesso o in attesa di avviare la ricerca.
class BleStatusIdle extends BleConnectionStatus {
  const BleStatusIdle();

  @override
  String toString() => 'Idle';
}

/// Scansione BLE in corso per rilevare dispositivi WHOOP.
class BleStatusScanning extends BleConnectionStatus {
  const BleStatusScanning();

  @override
  String toString() => 'Scanning';
}

/// Dispositivi individuati pronti per la selezione e il pairing.
class BleStatusDiscovered extends BleConnectionStatus {
  const BleStatusDiscovered(this.devices);
  final List<WhoopDiscoveredDevice> devices;

  @override
  String toString() => 'Discovered(${devices.length} devices)';
}

/// Connessione GATT in fase di apertura verso il dispositivo selezionato.
class BleStatusConnecting extends BleConnectionStatus {
  const BleStatusConnecting({this.device});
  final WhoopDiscoveredDevice? device;

  @override
  String toString() => 'Connecting(${device?.macAddress})';
}

/// Richiesta di bonding/pairing di sistema con popup nativo.
class BleStatusBonding extends BleConnectionStatus {
  const BleStatusBonding({this.device});
  final WhoopDiscoveredDevice? device;

  @override
  String toString() => 'Bonding(${device?.macAddress})';
}

/// Accoppiamento completato e trasporto pronto allo scambio frame.
class BleStatusConnected extends BleConnectionStatus {
  const BleStatusConnected(this.device, {this.isHardwareVerified = true});
  final WhoopDiscoveredDevice device;
  final bool isHardwareVerified;

  @override
  String toString() => isHardwareVerified
      ? 'Connected(Verificato Hardware: ${device.name})'
      : 'Connected(${device.name})';
}

/// Errore durante la scansione, connessione o autorizzazione di bonding.
class BleStatusError extends BleConnectionStatus {
  const BleStatusError(this.message);
  final String message;

  @override
  String toString() => 'Error($message)';
}
