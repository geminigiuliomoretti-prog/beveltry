package com.beveltry.ble

import android.Manifest
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import java.util.UUID

sealed interface AndroidBleState {
    data object Disconnected : AndroidBleState
    data object Connecting : AndroidBleState
    data object DiscoveringServices : AndroidBleState
    data object Ready : AndroidBleState
    data class Failed(val reason: String) : AndroidBleState
}

class AndroidPuffinTransport(
    context: Context,
    private val bonder: WhoopBonder = WhoopBonder(context.applicationContext),
) : PuffinTransport {
    private val appContext = context.applicationContext
    private val operationMutex = Mutex()
    private val gate = Any()
    private var gatt: BluetoothGatt? = null
    private var characteristics: Map<PuffinCharacteristic, BluetoothGattCharacteristic> = emptyMap()
    private val reassemblers = PuffinCharacteristic.entries.associateWith { PuffinFrameReassembler() }
    private val frames = MutableSharedFlow<Pair<PuffinFrame, PuffinCharacteristic>>(extraBufferCapacity = 128)
    private val heartRates = MutableSharedFlow<ByteArray>(extraBufferCapacity = 64)
    private var pending: CompletableDeferred<Int>? = null
    @Volatile var state: AndroidBleState = AndroidBleState.Disconnected
        private set

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                val reason = if (status == GATT_CONN_TERMINATE_PEER_USER) {
                    "Connessione rifiutata (status 14). Rimuovi il dispositivo dall'app WHOOP ufficiale, chiudila e tocca il cinturino 5–8 volte finché il LED diventa blu; poi riprova."
                } else "Connessione GATT fallita (status $status)"
                fail(reason)
                return
            }
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                state = AndroidBleState.DiscoveringServices
                if (!gatt.discoverServices()) fail("discoverServices() ha restituito false")
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                state = AndroidBleState.Disconnected
                synchronized(gate) { pending?.complete(BluetoothGatt.GATT_FAILURE); pending = null }
                gatt.close()
                synchronized(gate) { if (this@AndroidPuffinTransport.gatt === gatt) this@AndroidPuffinTransport.gatt = null }
                ConnectedDeviceForegroundService.stop(appContext)
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) { fail("Service discovery GATT status $status"); return }
            try {
                characteristics = REQUIRED_CHARACTERISTICS.mapValues { (_, uuid) ->
                    gatt.getService(WHOOP_SERVICE_UUID)?.getCharacteristic(uuid)
                        ?: throw IllegalStateException("Caratteristica WHOOP mancante: $uuid")
                }
                if (gatt.getService(HEART_RATE_SERVICE_UUID)?.getCharacteristic(HEART_RATE_MEASUREMENT_UUID) == null) {
                    throw IllegalStateException("Caratteristica standard 2A37 non trovata")
                }
                state = AndroidBleState.Ready
                ConnectedDeviceForegroundService.start(appContext)
            } catch (error: Exception) { fail(error.message ?: "Servizi WHOOP incompleti") }
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            android.util.Log.i("BeveltryBLE", "onCharacteristicWrite uuid=${characteristic.uuid} status=$status")
            complete(status)
        }
        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            android.util.Log.i("BeveltryBLE", "onDescriptorWrite uuid=${descriptor.characteristic.uuid} status=$status")
            complete(status)
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            acceptNotification(characteristic, characteristic.value ?: return)
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            acceptNotification(characteristic, value)
        }

        private fun acceptNotification(characteristic: BluetoothGattCharacteristic, value: ByteArray) {
            android.util.Log.i("BeveltryBLE", "onCharacteristicChanged uuid=${characteristic.uuid} len=${value.size} hex=${value.joinToString("") { "%02x".format(it) }}")
            if (characteristic.uuid == HEART_RATE_MEASUREMENT_UUID) {
                heartRates.tryEmit(value.copyOf())
                return
            }
            val kind = characteristics.entries.firstOrNull { it.value.uuid == characteristic.uuid }?.key ?: return
            reassemblers.getValue(kind).feed(value).forEach { frames.tryEmit(it to kind) }
        }
    }

    fun connect(device: BluetoothDevice, timeoutMillis: Long = 30_000): Flow<AndroidBleState> = flow {
        connectAndAwaitReady(device, timeoutMillis)
        emit(AndroidBleState.Ready)
    }

    /**
     * Connette il GATT, richiede esplicitamente il bonding (popup nativo Android)
     * e notifica al cinturino l'avvenuta associazione con pacchetto HELLO (0x91),
     * facendo cessare il lampeggio blu del LED di pairing.
     */
    suspend fun connectAndBond(
        device: BluetoothDevice,
        onBondingStarted: () -> Unit = {},
        timeoutMillis: Long = 60_000,
    ) {
        connectAndAwaitReady(device, timeoutMillis = 30_000)
        onBondingStarted()
        val bonded = bonder.bond(device, timeoutMillis)
        if (!bonded) {
            disconnect()
            throw WhoopBondException("Bonding non completato o rifiutato")
        }

        subscribe(PuffinCharacteristic.CMD_FROM_STRAP)
        subscribe(PuffinCharacteristic.EVENTS_FROM_STRAP)
        subscribe(PuffinCharacteristic.DATA_FROM_STRAP)

        // HELLO (0x91) conferma l'accoppiamento autenticato al firmware e spegne il LED blu
        val helloSeq = 1
        val helloPayload = byteArrayOf(0x23, helloSeq.toByte(), 0x91.toByte(), 0x01)
        val frame = PuffinFrameCodec.encode(field = 0x0100, helloPayload)
        write(frame, PuffinCharacteristic.CMD_TO_STRAP)
    }

    private suspend fun connectAndAwaitReady(device: BluetoothDevice, timeoutMillis: Long) {
        requireConnectPermission()
        check(state == AndroidBleState.Disconnected) { "La connessione è già attiva" }
        state = AndroidBleState.Connecting
        val opened = try {
            if (Build.VERSION.SDK_INT >= 23) device.connectGatt(appContext, false, callback, BluetoothDevice.TRANSPORT_LE)
            else device.connectGatt(appContext, false, callback)
        } catch (error: SecurityException) {
            state = AndroidBleState.Failed("Permesso BLUETOOTH_CONNECT mancante")
            throw error
        } ?: run { state = AndroidBleState.Failed("Impossibile creare BluetoothGatt"); error("Impossibile creare BluetoothGatt") }
        synchronized(gate) { gatt = opened }
        // L'evento di connessione viene atteso dal callback condiviso attraverso lo stato GATT.
        try {
            withTimeout(timeoutMillis) {
                while (state != AndroidBleState.Ready) {
                    if (state is AndroidBleState.Failed) error((state as AndroidBleState.Failed).reason)
                    kotlinx.coroutines.delay(25)
                }
            }
        } catch (error: TimeoutCancellationException) {
            disconnect()
            throw IllegalStateException("Timeout connessione/discovery GATT dopo ${timeoutMillis}ms", error)
        } catch (error: kotlinx.coroutines.CancellationException) {
            disconnect()
            throw error
        } catch (error: Exception) {
            disconnect()
            throw error
        }
    }

    override suspend fun write(frame: ByteArray, characteristic: PuffinCharacteristic) {
        val decoded = PuffinFrameCodec.decode(frame)
        val payload = decoded.rawPayload
        android.util.Log.i("BeveltryBLE", "GATT write to $characteristic: len=${frame.size} payloadHex=${payload.joinToString("") { "%02x".format(it) }}")
        if (payload.size >= 3 && payload[0] == 0x23.toByte()) {
            val opcode = payload[2].toInt() and 0xFF
            require(opcode != ERASE_OPCODE && opcode != REBOOT_OPCODE) { "Opcode distruttivo 0x${opcode.toString(16)} bloccato" }
        }
        try {
            writeOnce(frame, characteristic)
        } catch (error: GattWriteException) {
            android.util.Log.w("BeveltryBLE", "GATT write error status=${error.status}, requesting bonding")
            if (error.status != GATT_INSUFFICIENT_AUTHENTICATION && error.status != GATT_INSUFFICIENT_ENCRYPTION) throw error
            val device = synchronized(gate) { gatt?.device } ?: throw error
            bonder.bond(device)
            writeOnce(frame, characteristic)
        }
    }

    private suspend fun writeOnce(frame: ByteArray, characteristic: PuffinCharacteristic) = operationMutex.withLock {
        val target = characteristics[characteristic] ?: error("Caratteristica $characteristic non disponibile")
        val connection = synchronized(gate) { gatt } ?: error("GATT non connesso")
        val response = target.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0
        val writeType = if (response) BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        val status = performGattOperation {
            if (Build.VERSION.SDK_INT >= 33) connection.writeCharacteristic(target, frame, writeType) == BluetoothGatt.GATT_SUCCESS
            else {
                @Suppress("DEPRECATION")
                target.writeType = writeType
                @Suppress("DEPRECATION")
                target.value = frame
                @Suppress("DEPRECATION")
                connection.writeCharacteristic(target)
            }
        }
        if (status != BluetoothGatt.GATT_SUCCESS) throw GattWriteException(status)
    }

    override suspend fun subscribe(characteristic: PuffinCharacteristic) = operationMutex.withLock {
        val target = characteristics[characteristic] ?: error("Caratteristica $characteristic non disponibile")
        enableNotifications(target)
    }

    suspend fun subscribeHeartRate() = operationMutex.withLock {
        val target = synchronized(gate) { gatt }?.getService(HEART_RATE_SERVICE_UUID)?.getCharacteristic(HEART_RATE_MEASUREMENT_UUID)
            ?: error("Caratteristica 2A37 non disponibile")
        enableNotifications(target)
    }

    private suspend fun enableNotifications(target: BluetoothGattCharacteristic) {
        val connection = synchronized(gate) { gatt } ?: error("GATT non connesso")
        check(connection.setCharacteristicNotification(target, true)) { "setCharacteristicNotification fallito per ${target.uuid}" }
        val descriptor = target.getDescriptor(CCCD_UUID) ?: error("CCCD assente su ${target.uuid}")
        val status = performGattOperation {
            if (Build.VERSION.SDK_INT >= 33) connection.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothGatt.GATT_SUCCESS
            else {
                @Suppress("DEPRECATION")
                descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                @Suppress("DEPRECATION")
                connection.writeDescriptor(descriptor)
            }
        }
        if (status != BluetoothGatt.GATT_SUCCESS) throw GattWriteException(status)
    }

    private suspend fun performGattOperation(start: () -> Boolean): Int {
        val completion = CompletableDeferred<Int>()
        synchronized(gate) {
            check(pending == null) { "Operazione GATT già in corso" }
            pending = completion
        }
        if (!start()) {
            synchronized(gate) { pending = null }
            throw IllegalStateException("Android ha rifiutato l'operazione GATT")
        }
        return try { withTimeout(OPERATION_TIMEOUT_MS) { completion.await() } }
        finally { synchronized(gate) { if (pending === completion) pending = null } }
    }

    private fun complete(status: Int) = synchronized(gate) { pending?.complete(status); pending = null }
    private fun fail(reason: String) { state = AndroidBleState.Failed(reason); synchronized(gate) { pending?.complete(BluetoothGatt.GATT_FAILURE); pending = null } }
    private fun requireConnectPermission() {
        if (appContext.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
            throw SecurityException("È necessario concedere BLUETOOTH_CONNECT")
        }
    }

    override fun incomingFrames(): Flow<Pair<PuffinFrame, PuffinCharacteristic>> = frames.asSharedFlow()
    fun incomingHeartRate(): Flow<ByteArray> = heartRates.asSharedFlow()

    fun disconnect() {
        val connection = synchronized(gate) { gatt.also { gatt = null } }
        state = AndroidBleState.Disconnected
        connection?.disconnect()
        connection?.close()
        ConnectedDeviceForegroundService.stop(appContext)
        reassemblers.values.forEach(PuffinFrameReassembler::reset)
    }

    private class GattWriteException(val status: Int) : Exception("Scrittura GATT status $status")


    companion object {
        private const val OPERATION_TIMEOUT_MS = 8_000L
        private const val ERASE_OPCODE = 0x19
        private const val REBOOT_OPCODE = 0x1D
        private const val GATT_INSUFFICIENT_AUTHENTICATION = 5
        private const val GATT_INSUFFICIENT_ENCRYPTION = 15
        private const val GATT_CONN_TERMINATE_PEER_USER = 14
        val WHOOP_SERVICE_UUID: UUID = WhoopScanner.WHOOP_SERVICE_UUID
        val WHOOP_CHARACTERISTIC_UUIDS = mapOf(
            PuffinCharacteristic.CMD_TO_STRAP to UUID.fromString("fd4b0002-cce1-4033-93ce-002d5875f58a"),
            PuffinCharacteristic.CMD_FROM_STRAP to UUID.fromString("fd4b0003-cce1-4033-93ce-002d5875f58a"),
            PuffinCharacteristic.EVENTS_FROM_STRAP to UUID.fromString("fd4b0004-cce1-4033-93ce-002d5875f58a"),
            PuffinCharacteristic.DATA_FROM_STRAP to UUID.fromString("fd4b0005-cce1-4033-93ce-002d5875f58a"),
            PuffinCharacteristic.MEMFAULT to UUID.fromString("fd4b0007-cce1-4033-93ce-002d5875f58a"),
        )
        private val REQUIRED_CHARACTERISTICS = WHOOP_CHARACTERISTIC_UUIDS
        private val HEART_RATE_SERVICE_UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
        private val HEART_RATE_MEASUREMENT_UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
        private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
