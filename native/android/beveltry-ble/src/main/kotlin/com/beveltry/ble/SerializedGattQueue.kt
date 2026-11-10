package com.beveltry.ble

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.concurrent.atomic.AtomicLong

sealed class GattOpResult {
    data class Success(val status: Int = BluetoothGatt.GATT_SUCCESS, val data: ByteArray? = null) : GattOpResult()
    data class Failure(val status: Int, val message: String) : GattOpResult()
    data class Timeout(val message: String) : GattOpResult()
}

sealed class GattOperation(val id: Long, val timeoutMs: Long = 5000L) {
    val completion = CompletableDeferred<GattOpResult>()

    abstract fun execute(gatt: BluetoothGatt): Boolean

    class WriteCharacteristic(
        id: Long,
        val characteristic: BluetoothGattCharacteristic,
        val data: ByteArray,
        val writeType: Int = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
        timeoutMs: Long = 5000L,
    ) : GattOperation(id, timeoutMs) {
        override fun execute(gatt: BluetoothGatt): Boolean {
            return if (Build.VERSION.SDK_INT >= 33) {
                gatt.writeCharacteristic(characteristic, data, writeType) == BluetoothGatt.GATT_SUCCESS
            } else {
                @Suppress("DEPRECATION")
                characteristic.writeType = writeType
                @Suppress("DEPRECATION")
                characteristic.value = data
                @Suppress("DEPRECATION")
                gatt.writeCharacteristic(characteristic)
            }
        }
    }

    class WriteDescriptor(
        id: Long,
        val descriptor: BluetoothGattDescriptor,
        val data: ByteArray,
        timeoutMs: Long = 5000L,
    ) : GattOperation(id, timeoutMs) {
        override fun execute(gatt: BluetoothGatt): Boolean {
            return if (Build.VERSION.SDK_INT >= 33) {
                gatt.writeDescriptor(descriptor, data) == BluetoothGatt.GATT_SUCCESS
            } else {
                @Suppress("DEPRECATION")
                descriptor.value = data
                @Suppress("DEPRECATION")
                gatt.writeDescriptor(descriptor)
            }
        }
    }

    class ReadCharacteristic(
        id: Long,
        val characteristic: BluetoothGattCharacteristic,
        timeoutMs: Long = 5000L,
    ) : GattOperation(id, timeoutMs) {
        override fun execute(gatt: BluetoothGatt): Boolean {
            return gatt.readCharacteristic(characteristic)
        }
    }

    class RequestMtu(
        id: Long,
        val mtu: Int,
        timeoutMs: Long = 5000L,
    ) : GattOperation(id, timeoutMs) {
        override fun execute(gatt: BluetoothGatt): Boolean {
            return gatt.requestMtu(mtu)
        }
    }

    class DiscoverServices(
        id: Long,
        timeoutMs: Long = 10000L,
    ) : GattOperation(id, timeoutMs) {
        override fun execute(gatt: BluetoothGatt): Boolean {
            return gatt.discoverServices()
        }
    }
}

/**
 * Coda serializzata thread-safe per tutte le operazioni BluetoothGatt.
 * Garantisce che un'operazione GATT successiva inizi solo dopo che la precedente
 * ha ricevuto il relativo callback asincrono dal controller Bluetooth o è andata in timeout.
 */
class SerializedGattQueue(
    private val gattProvider: () -> BluetoothGatt?,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.IO),
) {
    private val opIdCounter = AtomicLong(1L)
    private val queue = Channel<GattOperation>(Channel.UNLIMITED)
    private var workerJob: Job? = null

    @Volatile
    private var activeOp: GattOperation? = null

    init {
        startWorker()
    }

    private fun startWorker() {
        workerJob?.cancel()
        workerJob = scope.launch {
            for (op in queue) {
                activeOp = op
                val gatt = gattProvider()
                if (gatt == null) {
                    op.completion.complete(GattOpResult.Failure(BluetoothGatt.GATT_FAILURE, "GATT non connesso"))
                    activeOp = null
                    continue
                }

                val started = try {
                    op.execute(gatt)
                } catch (e: Exception) {
                    Log.e(TAG, "Eccezione durante l'avvio operazione ${op.id} (${op.javaClass.simpleName})", e)
                    false
                }

                if (!started) {
                    op.completion.complete(GattOpResult.Failure(BluetoothGatt.GATT_FAILURE, "Android ha rifiutato l'avvio dell'operazione GATT"))
                    activeOp = null
                    continue
                }

                val result = withTimeoutOrNull(op.timeoutMs) {
                    op.completion.await()
                }

                if (result == null) {
                    Log.w(TAG, "Timeout scaduto per operazione ${op.id} (${op.javaClass.simpleName}) dopo ${op.timeoutMs}ms")
                    op.completion.complete(GattOpResult.Timeout("Timeout operazione GATT (${op.timeoutMs}ms)"))
                }
                activeOp = null
            }
        }
    }

    suspend fun writeCharacteristic(
        characteristic: BluetoothGattCharacteristic,
        data: ByteArray,
        writeType: Int = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT,
        timeoutMs: Long = 5000L,
    ): GattOpResult {
        val op = GattOperation.WriteCharacteristic(opIdCounter.getAndIncrement(), characteristic, data, writeType, timeoutMs)
        queue.send(op)
        return op.completion.await()
    }

    suspend fun writeDescriptor(
        descriptor: BluetoothGattDescriptor,
        data: ByteArray,
        timeoutMs: Long = 5000L,
    ): GattOpResult {
        val op = GattOperation.WriteDescriptor(opIdCounter.getAndIncrement(), descriptor, data, timeoutMs)
        queue.send(op)
        return op.completion.await()
    }

    suspend fun readCharacteristic(
        characteristic: BluetoothGattCharacteristic,
        timeoutMs: Long = 5000L,
    ): GattOpResult {
        val op = GattOperation.ReadCharacteristic(opIdCounter.getAndIncrement(), characteristic, timeoutMs)
        queue.send(op)
        return op.completion.await()
    }

    suspend fun requestMtu(
        mtu: Int,
        timeoutMs: Long = 5000L,
    ): GattOpResult {
        val op = GattOperation.RequestMtu(opIdCounter.getAndIncrement(), mtu, timeoutMs)
        queue.send(op)
        return op.completion.await()
    }

    suspend fun discoverServices(
        timeoutMs: Long = 10000L,
    ): GattOpResult {
        val op = GattOperation.DiscoverServices(opIdCounter.getAndIncrement(), timeoutMs)
        queue.send(op)
        return op.completion.await()
    }

    // Callback instradati da BluetoothGattCallback

    fun onCharacteristicWrite(characteristic: BluetoothGattCharacteristic, status: Int) {
        val op = activeOp
        if (op is GattOperation.WriteCharacteristic && op.characteristic.uuid == characteristic.uuid) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                op.completion.complete(GattOpResult.Success(status))
            } else {
                op.completion.complete(GattOpResult.Failure(status, "onCharacteristicWrite fallito con status $status"))
            }
        }
    }

    fun onDescriptorWrite(descriptor: BluetoothGattDescriptor, status: Int) {
        val op = activeOp
        if (op is GattOperation.WriteDescriptor && op.descriptor.uuid == descriptor.uuid) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                op.completion.complete(GattOpResult.Success(status))
            } else {
                op.completion.complete(GattOpResult.Failure(status, "onDescriptorWrite fallito con status $status"))
            }
        }
    }

    fun onCharacteristicRead(characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
        val op = activeOp
        if (op is GattOperation.ReadCharacteristic && op.characteristic.uuid == characteristic.uuid) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                op.completion.complete(GattOpResult.Success(status, value))
            } else {
                op.completion.complete(GattOpResult.Failure(status, "onCharacteristicRead fallito con status $status"))
            }
        }
    }

    fun onMtuChanged(mtu: Int, status: Int) {
        val op = activeOp
        if (op is GattOperation.RequestMtu) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                op.completion.complete(GattOpResult.Success(status))
            } else {
                op.completion.complete(GattOpResult.Failure(status, "onMtuChanged fallito con status $status"))
            }
        }
    }

    fun onServicesDiscovered(status: Int) {
        val op = activeOp
        if (op is GattOperation.DiscoverServices) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                op.completion.complete(GattOpResult.Success(status))
            } else {
                op.completion.complete(GattOpResult.Failure(status, "onServicesDiscovered fallito con status $status"))
            }
        }
    }

    fun clear(reason: String = "Connessione reimpostata") {
        activeOp?.let {
            it.completion.complete(GattOpResult.Failure(BluetoothGatt.GATT_FAILURE, reason))
        }
        activeOp = null
    }

    companion object {
        private const val TAG = "SerializedGattQueue"
    }
}
