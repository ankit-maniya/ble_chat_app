package com.maniya.ble_chat_app

import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.ParcelUuid
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.*

class MainActivity : FlutterActivity() {
    private val CHANNEL = "ble_peripheral"
    private var bluetoothGattServer: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var characteristic: BluetoothGattCharacteristic? = null
    
    // Use concurrent collections to avoid issues with concurrent modifications
    private var connectedDevices: MutableSet<BluetoothDevice> = Collections.synchronizedSet(mutableSetOf())
    private val notificationEnabledDevices: MutableSet<BluetoothDevice> = Collections.synchronizedSet(mutableSetOf())
    
    // Track devices by MAC address to prevent duplicates based on device instances
    private val deviceAddresses: MutableSet<String> = Collections.synchronizedSet(mutableSetOf())
    private val notificationAddresses: MutableSet<String> = Collections.synchronizedSet(mutableSetOf())

    // Custom UUIDs for your chat service
    private val SERVICE_UUID: UUID = UUID.fromString("12345678-1234-1234-1234-123456789abc")
    private val CHARACTERISTIC_UUID: UUID = UUID.fromString("87654321-4321-4321-4321-cba987654321")

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
                call,
                result ->
            when (call.method) {
                "startPeripheral" -> {
                    startPeripheral()
                    result.success(null)
                }
                "stopPeripheral" -> {
                    stopPeripheral()
                    result.success(null)
                }
                "sendMessage" -> {
                    val message = call.argument<String>("message") ?: ""
                    val useWrite = call.argument<Boolean>("useWrite") ?: false
                    if (useWrite) {
                        // For debugging: Set characteristic value that clients can read
                        setCharacteristicValue(message)
                    } else {
                        sendMessageToClients(message)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setCharacteristicValue(message: String) {
        val value = message.toByteArray(Charsets.UTF_8)

        // Group devices by address to avoid sending to same device multiple times
        val uniqueDevices = notificationEnabledDevices.groupBy { it.address }.mapValues { it.value.first() }
        
        uniqueDevices.values.forEach { device ->
            characteristic?.let { char ->
                try {
                    // Check if device is still connected before sending
                    if (deviceAddresses.contains(device.address)) {
                        val success = bluetoothGattServer?.notifyCharacteristicChanged(device, char, false, value)
                        Log.i("BLE", "Message sent to ${device.address}: $success")
                        
                        if (success != BluetoothGatt.GATT_SUCCESS) {
                            Log.w("BLE", "Notification failed for ${device.address} - removing from lists")
                            cleanupDevice(device)
                        }
                    } else {
                        Log.w("BLE", "Device ${device.address} no longer connected - removing from notification list")
                        cleanupDevice(device)
                    }
                } catch (e: Exception) {
                    Log.e("BLE", "Error sending notification to ${device.address}: ${e.message}")
                    cleanupDevice(device)
                }
            }
        }
    }

    private fun startPeripheral() {
        val bluetoothManager = getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
        val bluetoothAdapter = bluetoothManager.adapter

        if (!bluetoothAdapter.isEnabled) {
            Log.e("BLE", "Bluetooth is not enabled")
            return
        }

        if (!bluetoothAdapter.isMultipleAdvertisementSupported) {
            Log.e("BLE", "BLE advertising is not supported on this device")
            return
        }

        // Set custom device name
        bluetoothAdapter.name = "BO_Chat"

        advertiser = bluetoothAdapter.bluetoothLeAdvertiser
        if (advertiser == null) {
            Log.e("BLE", "BluetoothLeAdvertiser is null")
            return
        }

        // Create GATT Service and Characteristic
        val gattService =
                BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        characteristic =
                BluetoothGattCharacteristic(
                        CHARACTERISTIC_UUID,
                        BluetoothGattCharacteristic.PROPERTY_READ or
                                BluetoothGattCharacteristic.PROPERTY_WRITE or
                                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
                        BluetoothGattCharacteristic.PERMISSION_READ or
                                BluetoothGattCharacteristic.PERMISSION_WRITE
                )

        // Add Client Characteristic Configuration Descriptor for notifications
        val descriptor =
                BluetoothGattDescriptor(
                        UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"),
                        BluetoothGattDescriptor.PERMISSION_READ or
                                BluetoothGattDescriptor.PERMISSION_WRITE
                )
        characteristic?.addDescriptor(descriptor)

        gattService.addCharacteristic(characteristic)

        // Start GATT server
        bluetoothGattServer = bluetoothManager.openGattServer(this, gattServerCallback)

        // Wait a bit before adding service to ensure server is ready
        Thread.sleep(100)

        val added = bluetoothGattServer?.addService(gattService)
        Log.i("BLE", "Service added: $added")

        // Start advertising after a short delay
        Thread.sleep(500)
        startAdvertising()
    }

    private fun startAdvertising() {
        val settings =
                AdvertiseSettings.Builder()
                        .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                        .setConnectable(true)
                        .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
                        .setTimeout(0) // Advertise indefinitely
                        .build()

        val data =
                AdvertiseData.Builder()
                        .setIncludeDeviceName(true)
                        .setIncludeTxPowerLevel(false)
                        .addServiceUuid(ParcelUuid(SERVICE_UUID))
                        .build()

        advertiser?.startAdvertising(settings, data, advertiseCallback)
        Log.i("BLE", "Starting advertising with service UUID: $SERVICE_UUID")
    }

    private fun stopPeripheral() {
        advertiser?.stopAdvertising(advertiseCallback)
        bluetoothGattServer?.close()
        advertiser = null
        bluetoothGattServer = null
        
        // Clear all device tracking
        connectedDevices.clear()
        notificationEnabledDevices.clear()
        deviceAddresses.clear()
        notificationAddresses.clear()
        
        Log.i("BLE", "Peripheral stopped")
    }

    // Helper function to clean up a device from all tracking sets
    private fun cleanupDevice(device: BluetoothDevice) {
        val address = device.address
        
        // Remove from device collections
        connectedDevices.removeAll { it.address == address }
        notificationEnabledDevices.removeAll { it.address == address }
        
        // Remove from address tracking
        deviceAddresses.remove(address)
        notificationAddresses.remove(address)
        
        Log.i("BLE", "Cleaned up device: $address")
    }

    private fun sendMessageToClients(message: String) {
        if (connectedDevices.isEmpty()) {
            Log.w("BLE", "No connected devices to send message to")
            return
        }

        val value = message.toByteArray(Charsets.UTF_8)

        // Group devices by address to avoid sending to same device multiple times
        val uniqueDevices = notificationEnabledDevices.groupBy { it.address }.mapValues { it.value.first() }
        
        Log.i("BLE", "Sending message to ${uniqueDevices.size} unique devices (from ${notificationEnabledDevices.size} total entries)")

        uniqueDevices.values.forEach { device ->
            characteristic?.let { char ->
                try {
                    // Double-check device is still connected
                    if (deviceAddresses.contains(device.address)) {
                        val success = bluetoothGattServer?.notifyCharacteristicChanged(
                                device,
                                char,
                                false,
                                value
                        )
                        Log.i("BLE", "Notification sent to ${device.address}: $success")
                        
                        if (success != BluetoothGatt.GATT_SUCCESS) {
                            Log.w("BLE", "Notification failed for ${device.address} - removing from lists")
                            cleanupDevice(device)
                        }
                    } else {
                        Log.w("BLE", "Device ${device.address} no longer connected - removing from notification list")
                        cleanupDevice(device)
                    }
                } catch (e: Exception) {
                    Log.e("BLE", "Error sending notification to ${device.address}: ${e.message}")
                    cleanupDevice(device)
                }
            }
        }

        // If no devices have notifications enabled, log a warning
        if (notificationEnabledDevices.isEmpty() && connectedDevices.isNotEmpty()) {
            Log.w("BLE", "No devices have enabled notifications. Message not sent: $message")
        }
    }

    private val gattServerCallback =
            object : BluetoothGattServerCallback() {

                override fun onConnectionStateChange(
                        device: BluetoothDevice,
                        status: Int,
                        newState: Int
                ) {
                    super.onConnectionStateChange(device, status, newState)

                    when (newState) {
                        BluetoothProfile.STATE_CONNECTED -> {
                            Log.i("BLE", "Device connected: ${device.address}, status: $status")
                            
                            val address = device.address
                            
                            // Clean up any existing references to this device first
                            cleanupDevice(device)
                            
                            // Add to connected devices only if not already present
                            if (!deviceAddresses.contains(address)) {
                                connectedDevices.add(device)
                                deviceAddresses.add(address)
                                
                                Log.i("BLE", "Added new device: $address. Total connected devices: ${deviceAddresses.size}")
                                
                                sendFlutterEvent(
                                        "onDeviceConnected",
                                        mapOf("address" to address)
                                )
                            } else {
                                Log.w("BLE", "Device $address already in connected list")
                            }
                        }
                        BluetoothProfile.STATE_DISCONNECTED -> {
                            Log.i("BLE", "Device disconnected: ${device.address}, status: $status")
                            
                            // Clean up all references to this device
                            cleanupDevice(device)
                            
                            Log.i("BLE", "Total connected devices: ${deviceAddresses.size}")
                            
                            sendFlutterEvent(
                                    "onDeviceDisconnected",
                                    mapOf("address" to device.address)
                            )
                        }
                    }
                }

                override fun onServiceAdded(status: Int, service: BluetoothGattService) {
                    super.onServiceAdded(status, service)
                    Log.i("BLE", "Service added with status: $status, UUID: ${service.uuid}")
                }

                override fun onCharacteristicReadRequest(
                        device: BluetoothDevice,
                        requestId: Int,
                        offset: Int,
                        characteristic: BluetoothGattCharacteristic
                ) {
                    super.onCharacteristicReadRequest(device, requestId, offset, characteristic)
                    Log.i("BLE", "Characteristic read request from: ${device.address}")

                    val response = "Hello from peripheral".toByteArray(Charsets.UTF_8)
                    bluetoothGattServer?.sendResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_SUCCESS,
                            offset,
                            response
                    )
                }

                override fun onCharacteristicWriteRequest(
                        device: BluetoothDevice,
                        requestId: Int,
                        characteristic: BluetoothGattCharacteristic,
                        preparedWrite: Boolean,
                        responseNeeded: Boolean,
                        offset: Int,
                        value: ByteArray
                ) {
                    super.onCharacteristicWriteRequest(
                            device,
                            requestId,
                            characteristic,
                            preparedWrite,
                            responseNeeded,
                            offset,
                            value
                    )

                    val message = String(value, Charsets.UTF_8)
                    Log.i("BLE", "Received message from ${device.address}: $message")

                    // Verify device is still in our connected list
                    if (deviceAddresses.contains(device.address)) {
                        sendFlutterEvent(
                                "onMessageReceived",
                                mapOf("message" to message, "address" to device.address)
                        )
                    } else {
                        Log.w("BLE", "Received message from device not in connected list: ${device.address}")
                    }

                    if (responseNeeded) {
                        bluetoothGattServer?.sendResponse(
                                device,
                                requestId,
                                BluetoothGatt.GATT_SUCCESS,
                                offset,
                                value
                        )
                    }
                }

                override fun onDescriptorWriteRequest(
                        device: BluetoothDevice,
                        requestId: Int,
                        descriptor: BluetoothGattDescriptor,
                        preparedWrite: Boolean,
                        responseNeeded: Boolean,
                        offset: Int,
                        value: ByteArray
                ) {
                    super.onDescriptorWriteRequest(
                            device,
                            requestId,
                            descriptor,
                            preparedWrite,
                            responseNeeded,
                            offset,
                            value
                    )

                    Log.i("BLE", "Descriptor write request from: ${device.address}")

                    // Check if this is the CCCD descriptor
                    if (descriptor.uuid == UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")) {
                        when {
                            value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) -> {
                                val address = device.address
                                Log.i("BLE", "Notifications enabled for $address")
                                
                                // Ensure device is in connected list before adding to notification list
                                if (deviceAddresses.contains(address)) {
                                    // Only add if not already present
                                    if (!notificationAddresses.contains(address)) {
                                        notificationEnabledDevices.add(device)
                                        notificationAddresses.add(address)
                                        
                                        Log.i("BLE", "Added device to notification list: $address. Total devices with notifications: ${notificationAddresses.size}")
                                        
                                        sendFlutterEvent(
                                                "onNotificationsEnabled",
                                                mapOf("address" to address)
                                        )
                                    } else {
                                        Log.w("BLE", "Device $address already has notifications enabled")
                                    }
                                } else {
                                    Log.w("BLE", "Device $address not in connected list, ignoring notification enable")
                                }
                            }
                            value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE) -> {
                                val address = device.address
                                Log.i("BLE", "Notifications disabled for $address")
                                
                                if (notificationAddresses.contains(address)) {
                                    notificationEnabledDevices.removeAll { it.address == address }
                                    notificationAddresses.remove(address)
                                    
                                    Log.i("BLE", "Removed device from notification list: $address. Total devices with notifications: ${notificationAddresses.size}")
                                    
                                    sendFlutterEvent(
                                            "onNotificationsDisabled",
                                            mapOf("address" to address)
                                    )
                                }
                            }
                            else -> {
                                Log.w("BLE", "Unknown descriptor value: ${value.contentToString()}")
                            }
                        }
                    }

                    if (responseNeeded) {
                        bluetoothGattServer?.sendResponse(
                                device,
                                requestId,
                                BluetoothGatt.GATT_SUCCESS,
                                offset,
                                value
                        )
                    }
                }

                override fun onDescriptorReadRequest(
                        device: BluetoothDevice,
                        requestId: Int,
                        offset: Int,
                        descriptor: BluetoothGattDescriptor
                ) {
                    super.onDescriptorReadRequest(device, requestId, offset, descriptor)

                    Log.i("BLE", "Descriptor read request from: ${device.address}")

                    bluetoothGattServer?.sendResponse(
                            device,
                            requestId,
                            BluetoothGatt.GATT_SUCCESS,
                            offset,
                            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                    )
                }
            }

    private val advertiseCallback =
            object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                    Log.i("BLE", "Advertising started successfully")
                    sendFlutterEvent("onAdvertisingStarted")
                }

                override fun onStartFailure(errorCode: Int) {
                    val errorMsg =
                            when (errorCode) {
                                ADVERTISE_FAILED_ALREADY_STARTED -> "Already started"
                                ADVERTISE_FAILED_DATA_TOO_LARGE -> "Data too large"
                                ADVERTISE_FAILED_FEATURE_UNSUPPORTED -> "Feature unsupported"
                                ADVERTISE_FAILED_INTERNAL_ERROR -> "Internal error"
                                ADVERTISE_FAILED_TOO_MANY_ADVERTISERS -> "Too many advertisers"
                                else -> "Unknown error: $errorCode"
                            }
                    Log.e("BLE", "Advertising failed: $errorMsg")
                    sendFlutterEvent("onAdvertisingFailed", mapOf("error" to errorMsg))
                }
            }

    private fun sendFlutterEvent(method: String, arguments: Any? = null) {
        runOnUiThread {
            try {
                MethodChannel(
                                flutterEngine?.dartExecutor?.binaryMessenger
                                        ?: return@runOnUiThread,
                                CHANNEL
                        )
                        .invokeMethod(method, arguments)
            } catch (e: Exception) {
                Log.e("BLE", "Error sending Flutter event: ${e.message}")
            }
        }
    }
}