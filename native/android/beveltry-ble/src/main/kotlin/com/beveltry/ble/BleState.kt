package com.beveltry.ble

/**
 * Stati espliciti della macchina a stati BLE per WHOOP B (Task 08C).
 *
 * Stati obbligatori secondo specifica di sistema:
 * - DISABLED: Registrazione automatica Always-On disattivata.
 * - ASSOCIATED: Dispositivo noto e configurato, pronto per la connessione.
 * - WAITING_FOR_DEVICE: In attesa di rilevamento presenza o finestra di scansione.
 * - CONNECTING: Connessione GATT attiva in corso (connectGatt avviato).
 * - GATT_CONNECTED: Connessione a livello GATT stabilita (STATE_CONNECTED).
 * - DISCOVERING_SERVICES: Ricerca dei servizi GATT primari in corso.
 * - SUBSCRIBING_HR: Configurazione notifiche e scrittura CCCD (0x2902) su 0x2A37.
 * - STREAMING: Notifiche HR/RR attive e campioni validi in ricezione verso SQLite.
 * - RECONNECT_WAIT: Attesa programmata con backoff dopo link loss/disconnessione.
 * - BLUETOOTH_DISABLED: Adattatore Bluetooth spento o non disponibile su Android.
 * - PERMISSION_BLOCKED: Permessi runtime necessari mancanti o revocati.
 * - ERROR: Errore irreversibile o stato anomalo che richiede intervento utente.
 */
sealed class BleState {
    data object Disabled : BleState()
    data class Associated(val macAddress: String, val deviceName: String = "WHOOP 5.0") : BleState()
    data class WaitingForDevice(val macAddress: String, val attempt: Int = 1) : BleState()
    data class Connecting(val macAddress: String) : BleState()
    data class GattConnected(val macAddress: String) : BleState()
    data object DiscoveringServices : BleState()
    data class SubscribingHr(val step: Int = 1, val total: Int = 1) : BleState()
    data class Streaming(val sessionId: String, val lastHrBpm: Int, val totalSamples: Int) : BleState()
    data class ReconnectWait(val macAddress: String, val attempt: Int, val delayMs: Long) : BleState()
    data object BluetoothDisabled : BleState()
    data class PermissionBlocked(val missingPermissions: List<String>) : BleState()
    data class Error(val reason: String, val canRetry: Boolean, val errorCode: Int? = null) : BleState()

    val name: String
        get() = when (this) {
            is Disabled -> "DISABLED"
            is Associated -> "ASSOCIATED"
            is WaitingForDevice -> "WAITING_FOR_DEVICE"
            is Connecting -> "CONNECTING"
            is GattConnected -> "GATT_CONNECTED"
            is DiscoveringServices -> "DISCOVERING_SERVICES"
            is SubscribingHr -> "SUBSCRIBING_HR"
            is Streaming -> "STREAMING"
            is ReconnectWait -> "RECONNECT_WAIT"
            is BluetoothDisabled -> "BLUETOOTH_DISABLED"
            is PermissionBlocked -> "PERMISSION_BLOCKED"
            is Error -> "ERROR"
        }

    val isConnected: Boolean
        get() = this is GattConnected || this is DiscoveringServices || this is SubscribingHr || this is Streaming

    val isStreaming: Boolean
        get() = this is Streaming
}
