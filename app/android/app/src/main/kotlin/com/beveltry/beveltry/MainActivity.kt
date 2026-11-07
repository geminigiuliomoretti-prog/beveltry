package com.beveltry.beveltry

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.beveltry.ble.AndroidPuffinTransport
import com.beveltry.ble.PuffinCharacteristic
import com.beveltry.ble.WhoopBondException
import com.beveltry.ble.WhoopScanner
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var channel: MethodChannel? = null

    private var scanner: WhoopScanner? = null
    private var scanJob: Job? = null

    private var transport: AndroidPuffinTransport? = null
    private var frameCollectorJob: Job? = null

    private var pendingPermissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        channel = ch

        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkAndRequestPermissions" -> {
                    if (hasBlePermissions()) {
                        result.success(true)
                    } else {
                        pendingPermissionResult = result
                        requestBlePermissions()
                    }
                }

                "startScan" -> {
                    if (!hasBlePermissions()) {
                        pendingPermissionResult = result
                        requestBlePermissions()
                        return@setMethodCallHandler
                    }
                    startBleScan(call.argument<Int>("timeoutMillis")?.toLong() ?: 15_000L, result)
                }

                "stopScan" -> {
                    stopBleScan()
                    result.success(true)
                }

                "connectAndBond" -> {
                    val address = call.argument<String>("macAddress")
                    if (address == null) {
                        result.error("INVALID_ARG", "macAddress richiesto", null)
                        return@setMethodCallHandler
                    }
                    connectAndBondDevice(address, result)
                }

                "writeFrame" -> {
                    val frame = call.argument<ByteArray>("frame")
                    val charName = call.argument<String>("characteristic") ?: "cmdToStrap"
                    if (frame == null) {
                        result.error("INVALID_ARG", "frame binario richiesto", null)
                        return@setMethodCallHandler
                    }
                    writeFrameToStrap(frame, charName, result)
                }

                "disconnect" -> {
                    disconnectDevice()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    private fun hasBlePermissions(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(this, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        } else {
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun requestBlePermissions() {
        val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.BLUETOOTH,
                Manifest.permission.BLUETOOTH_ADMIN,
            )
        }
        ActivityCompat.requestPermissions(this, permissions, PERMISSION_REQUEST_CODE)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    private fun startBleScan(timeoutMillis: Long, result: MethodChannel.Result) {
        scanJob?.cancel()
        val whoopScanner = WhoopScanner(applicationContext)
        scanner = whoopScanner

        scanJob = scope.launch(Dispatchers.IO) {
            try {
                whoopScanner.scanAll(timeoutMillis).collect { discovered ->
                    withContext(Dispatchers.Main) {
                        channel?.invokeMethod(
                            "onDeviceDiscovered",
                            mapOf(
                                "name" to discovered.name,
                                "macAddress" to discovered.device.address,
                                "rssi" to discovered.rssi,
                            ),
                        )
                    }
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    channel?.invokeMethod("onScanError", e.message)
                }
            }
        }
        result.success(true)
    }

    private fun stopBleScan() {
        scanJob?.cancel()
        scanJob = null
    }

    private fun connectAndBondDevice(macAddress: String, result: MethodChannel.Result) {
        stopBleScan()
        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val adapter: BluetoothAdapter? = bluetoothManager.adapter
        val device: BluetoothDevice = adapter?.getRemoteDevice(macAddress) ?: run {
            result.error("DEVICE_NOT_FOUND", "Dispositivo non trovato per MAC $macAddress", null)
            return
        }

        transport?.disconnect()
        frameCollectorJob?.cancel()

        val activeTransport = AndroidPuffinTransport(applicationContext)
        transport = activeTransport

        scope.launch(Dispatchers.IO) {
            try {
                activeTransport.connectAndBond(
                    device,
                    onBondingStarted = {
                        runOnUiThread {
                            channel?.invokeMethod("onBondingStarted", mapOf("macAddress" to macAddress))
                        }
                    },
                    timeoutMillis = 60_000,
                )

                frameCollectorJob = scope.launch(Dispatchers.IO) {
                    activeTransport.incomingFrames().collect { (frame, characteristic) ->
                        withContext(Dispatchers.Main) {
                            channel?.invokeMethod(
                                "onFrameReceived",
                                mapOf(
                                    "payload" to frame.rawPayload,
                                    "field" to frame.field,
                                    "characteristic" to characteristic.name,
                                ),
                            )
                        }
                    }
                }

                withContext(Dispatchers.Main) {
                    result.success(true)
                }
            } catch (e: WhoopBondException) {
                withContext(Dispatchers.Main) {
                    result.error("BOND_FAILED", "Bonding fallito o annullato: ${e.message}", null)
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.error("CONNECT_FAILED", "Connessione fallita: ${e.message}", null)
                }
            }
        }
    }

    private fun writeFrameToStrap(
        frame: ByteArray,
        characteristicName: String,
        result: MethodChannel.Result,
    ) {
        val currentTransport = transport
        if (currentTransport == null || !currentTransport.state.toString().contains("Ready")) {
            result.error("NOT_CONNECTED", "Trasporto BLE non connesso", null)
            return
        }

        val characteristic = when (characteristicName) {
            "cmdFromStrap" -> PuffinCharacteristic.CMD_FROM_STRAP
            "eventsFromStrap" -> PuffinCharacteristic.EVENTS_FROM_STRAP
            "dataFromStrap" -> PuffinCharacteristic.DATA_FROM_STRAP
            "memfault" -> PuffinCharacteristic.MEMFAULT
            else -> PuffinCharacteristic.CMD_TO_STRAP
        }

        scope.launch(Dispatchers.IO) {
            try {
                currentTransport.write(frame, characteristic)
                withContext(Dispatchers.Main) {
                    result.success(true)
                }
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    result.error("WRITE_FAILED", "Errore durante la scrittura GATT: ${e.message}", null)
                }
            }
        }
    }

    private fun disconnectDevice() {
        stopBleScan()
        frameCollectorJob?.cancel()
        frameCollectorJob = null
        transport?.disconnect()
        transport = null
        channel?.invokeMethod("onDisconnected", null)
    }

    override fun onDestroy() {
        disconnectDevice()
        scope.cancel()
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_NAME = "com.beveltry/ble"
        private const val PERMISSION_REQUEST_CODE = 4107
    }
}
