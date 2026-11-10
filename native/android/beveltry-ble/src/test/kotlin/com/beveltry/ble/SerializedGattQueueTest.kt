package com.beveltry.ble

import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class SerializedGattQueueTest {

    @Test
    fun queueHandlesDisconnectionCleanly() = runBlocking {
        val dummyChar = BluetoothGattCharacteristic(
            UUID.fromString("fd4b0002-cce1-4033-93ce-002d5875f58a"),
            BluetoothGattCharacteristic.PROPERTY_WRITE,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )

        val queue = SerializedGattQueue(
            gattProvider = { null }, // nessun GATT connesso
            scope = CoroutineScope(Dispatchers.Default),
        )

        // Verifichiamo che gestisca le operazioni quando non c'è GATT connesso
        val res = queue.writeCharacteristic(dummyChar, byteArrayOf(0x01, 0x02))
        assertTrue(res is GattOpResult.Failure)
        assertEquals("GATT non connesso", (res as GattOpResult.Failure).message)
    }

    @Test
    fun stateMachineTransitionsFollowStrictSpecification() {
        val sm = ConnectionStateMachine()
        assertEquals(ConnectionState.Disconnected, sm.currentState)

        // DISCONNECTED -> CONNECTING
        assertTrue(sm.transitionTo(ConnectionState.Connecting("AA:BB:CC:DD:EE:FF")))
        assertEquals(ConnectionState.Connecting("AA:BB:CC:DD:EE:FF"), sm.currentState)

        // Transizione non consentita: CONNECTING non può andare direttamente a READY senza discovery e handshake!
        assertFalse(sm.transitionTo(ConnectionState.Ready))
        assertEquals(ConnectionState.Connecting("AA:BB:CC:DD:EE:FF"), sm.currentState)

        // CONNECTING -> DISCOVERING
        assertTrue(sm.transitionTo(ConnectionState.Discovering))

        // DISCOVERING -> NEGOTIATING_MTU
        assertTrue(sm.transitionTo(ConnectionState.NegotiatingMtu))

        // NEGOTIATING_MTU -> SUBSCRIBING
        assertTrue(sm.transitionTo(ConnectionState.Subscribing(1, 5)))

        // SUBSCRIBING -> HANDSHAKING
        assertTrue(sm.transitionTo(ConnectionState.Handshaking("HELLO")))

        // HANDSHAKING -> READY
        assertTrue(sm.transitionTo(ConnectionState.Ready))

        // READY -> SYNCING
        assertTrue(sm.transitionTo(ConnectionState.Syncing(10, null)))

        // SYNCING -> READY
        assertTrue(sm.transitionTo(ConnectionState.Ready))

        // Fallimento e reset
        assertTrue(sm.transitionTo(ConnectionState.Failed("Segnale perso", canRetry = true)))
        assertTrue(sm.transitionTo(ConnectionState.WaitingForDevice("AA:BB:CC:DD:EE:FF", 1)))
        sm.reset()
        assertEquals(ConnectionState.Disconnected, sm.currentState)
    }
}
