package com.beveltry.ble

import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

sealed class ConnectionState {
    data object Disconnected : ConnectionState()
    data class WaitingForDevice(val address: String, val attempt: Int = 1) : ConnectionState()
    data class Connecting(val address: String) : ConnectionState()
    data object Discovering : ConnectionState()
    data object NegotiatingMtu : ConnectionState()
    data class Subscribing(val step: Int, val total: Int) : ConnectionState()
    data class Handshaking(val stepName: String) : ConnectionState()
    data object Ready : ConnectionState()
    data class Syncing(val recordsSaved: Int, val progressPercent: Int?) : ConnectionState()
    data class Failed(val reason: String, val canRetry: Boolean, val errorCode: Int? = null) : ConnectionState()
}

/**
 * Macchina a stati esplicita per il ciclo di vita della connessione BLE con WHOOP 5.0.
 * Regola le transizioni autorizzate ed evita stati intermedi inconsistenti.
 */
class ConnectionStateMachine(
    private val onStateChanged: (oldState: ConnectionState, newState: ConnectionState) -> Unit = { _, _ -> },
) {
    private val _state = MutableStateFlow<ConnectionState>(ConnectionState.Disconnected)
    val state: StateFlow<ConnectionState> = _state.asStateFlow()

    val currentState: ConnectionState
        get() = _state.value

    @Synchronized
    fun transitionTo(newState: ConnectionState): Boolean {
        val old = _state.value
        if (old == newState) return true

        val valid = isValidTransition(old, newState)
        if (!valid) {
            Log.w(TAG, "Transizione di stato NON consentita: ${old.javaClass.simpleName} -> ${newState.javaClass.simpleName}")
            return false
        }

        Log.i(TAG, "Transizione di stato: ${old.javaClass.simpleName} -> ${newState.javaClass.simpleName}")
        _state.value = newState
        onStateChanged(old, newState)
        return true
    }

    private fun isValidTransition(from: ConnectionState, to: ConnectionState): Boolean {
        // Disconnect o fallimento sono sempre consentiti da qualunque stato attivo
        if (to is ConnectionState.Disconnected || to is ConnectionState.Failed) return true

        return when (from) {
            is ConnectionState.Disconnected ->
                to is ConnectionState.WaitingForDevice || to is ConnectionState.Connecting

            is ConnectionState.WaitingForDevice ->
                to is ConnectionState.Connecting || to is ConnectionState.WaitingForDevice

            is ConnectionState.Connecting ->
                to is ConnectionState.Discovering

            is ConnectionState.Discovering ->
                to is ConnectionState.NegotiatingMtu || to is ConnectionState.Subscribing

            is ConnectionState.NegotiatingMtu ->
                to is ConnectionState.Subscribing

            is ConnectionState.Subscribing ->
                to is ConnectionState.Subscribing || to is ConnectionState.Handshaking

            is ConnectionState.Handshaking ->
                to is ConnectionState.Handshaking || to is ConnectionState.Ready

            is ConnectionState.Ready ->
                to is ConnectionState.Syncing || to is ConnectionState.Handshaking

            is ConnectionState.Syncing ->
                to is ConnectionState.Syncing || to is ConnectionState.Ready

            is ConnectionState.Failed ->
                to is ConnectionState.WaitingForDevice || to is ConnectionState.Connecting || to is ConnectionState.Disconnected
        }
    }

    fun reset() {
        transitionTo(ConnectionState.Disconnected)
    }

    companion object {
        private const val TAG = "ConnectionStateMachine"
    }
}
