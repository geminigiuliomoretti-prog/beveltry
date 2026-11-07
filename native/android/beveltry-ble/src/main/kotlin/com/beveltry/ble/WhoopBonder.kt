package com.beveltry.ble

import android.bluetooth.BluetoothDevice
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import java.lang.reflect.InvocationTargetException

class WhoopBondException(message: String, cause: Throwable? = null) : Exception(message, cause)

/** Richiede il pairing gestito dal sistema solo dopo una risposta GATT protetta. */
class WhoopBonder(private val context: Context) {
    suspend fun bond(device: BluetoothDevice, timeoutMillis: Long = 60_000): Boolean {
        if (device.bondState == BluetoothDevice.BOND_BONDED) return true
        val outcome = CompletableDeferred<Int>()
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) {
                if (intent.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
                @Suppress("DEPRECATION")
                val changedDevice = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE) as? BluetoothDevice
                val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
                android.util.Log.i("BeveltryBLE", "WhoopBonder: ACTION_BOND_STATE_CHANGED state=$state for ${changedDevice?.address}")
                if (changedDevice?.address != device.address) return
                if (state == BluetoothDevice.BOND_BONDED || state == BluetoothDevice.BOND_NONE) outcome.complete(state)
            }
        }
        val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) {
            context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("DEPRECATION") context.registerReceiver(receiver, filter)
        }
        try {
            android.util.Log.i("BeveltryBLE", "WhoopBonder: createBond() on ${device.address}, bondState=${device.bondState}")
            if (!device.createBond()) {
                if (device.bondState == BluetoothDevice.BOND_BONDED) return true
                if (device.bondState != BluetoothDevice.BOND_BONDING) {
                    throw pairingInstructions("Android ha rifiutato la richiesta di pairing")
                }
            }
            val state = withTimeout(timeoutMillis) { outcome.await() }
            android.util.Log.i("BeveltryBLE", "WhoopBonder: bond outcome state=$state")
            if (state == BluetoothDevice.BOND_BONDED) return true
            throw pairingInstructions("Pairing rifiutato o terminato con status 14")
        } catch (error: WhoopBondException) {
            throw error
        } catch (error: kotlinx.coroutines.TimeoutCancellationException) {
            throw pairingInstructions("Timeout durante il pairing di sistema")
        } catch (error: SecurityException) {
            throw WhoopBondException("Serve il permesso BLUETOOTH_CONNECT per il pairing", error)
        } finally {
            runCatching { context.unregisterReceiver(receiver) }
        }
    }

    /** Android non espone una API pubblica per rimuovere un bond già salvato. */
    fun unpair(device: BluetoothDevice): Boolean = try {
        val method = device.javaClass.getMethod("removeBond")
        method.invoke(device) as? Boolean ?: false
    } catch (error: InvocationTargetException) {
        throw WhoopBondException("Rimozione bond non riuscita; rimuovi WHOOP dalle impostazioni Bluetooth", error.targetException)
    } catch (error: ReflectiveOperationException) {
        throw WhoopBondException("Rimozione bond non supportata da questa versione Android; usa le impostazioni Bluetooth", error)
    }

    private fun pairingInstructions(reason: String) = WhoopBondException(
        "$reason. Rimuovi il dispositivo dall'app WHOOP ufficiale, chiudila e tocca il cinturino 5–8 volte finché il LED diventa blu; poi riprova.",
    )
}
