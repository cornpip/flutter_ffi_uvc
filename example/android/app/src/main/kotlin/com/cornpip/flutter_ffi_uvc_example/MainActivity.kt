package com.cornpip.flutter_ffi_uvc_example

import android.app.PendingIntent
import android.content.ContentValues
import android.content.pm.PackageManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler {
    companion object {
        private const val CAMERA_PERMISSION_REQUEST_CODE = 1001
    }

    private lateinit var channel: MethodChannel
    private lateinit var usbManager: UsbManager
    private var currentDevice: UsbDevice? = null
    private var currentConnection: UsbDeviceConnection? = null
    private var cameraPermissionResult: MethodChannel.Result? = null
    private var permissionResult: MethodChannel.Result? = null
    private var pendingDevice: UsbDevice? = null

    private val usbPermissionAction = "com.cornpip.flutter_ffi_uvc_example.USB_PERMISSION"

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != usbPermissionAction) {
                return
            }

            val result = permissionResult ?: return
            val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }

            val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            permissionResult = null
            pendingDevice = null

            if (!granted || device == null) {
                result.error("permission_denied", "USB permission denied", null)
                return
            }

            openDevice(device, result)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        usbManager = getSystemService(Context.USB_SERVICE) as UsbManager
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "flutter_ffi_uvc_example/usb"
        )
        channel.setMethodCallHandler(this)

        val filter = IntentFilter(usbPermissionAction)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(permissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(permissionReceiver, filter)
        }
    }

    override fun onDestroy() {
        channel.setMethodCallHandler(null)
        closeCurrentConnection()
        unregisterReceiver(permissionReceiver)
        super.onDestroy()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "listUsbDevices" -> {
                result.success(
                    usbManager.deviceList.values
                        .filter { device -> isVideoDevice(device) }
                        .map { device ->
                        mapOf(
                            "deviceId" to device.deviceId,
                            "deviceName" to device.deviceName,
                            "vendorId" to device.vendorId,
                            "productId" to device.productId,
                            "productName" to (device.productName ?: ""),
                            "manufacturerName" to (device.manufacturerName ?: ""),
                            "serialNumber" to safeSerialNumber(device),
                            "hasPermission" to usbManager.hasPermission(device)
                        )
                    }
                )
            }

            "ensureCameraPermission" -> {
                if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.CAMERA) ==
                    PackageManager.PERMISSION_GRANTED
                ) {
                    result.success(true)
                } else {
                    cameraPermissionResult = result
                    ActivityCompat.requestPermissions(
                        this,
                        arrayOf(android.Manifest.permission.CAMERA),
                        CAMERA_PERMISSION_REQUEST_CODE
                    )
                }
            }

            "openUsbDevice" -> {
                val deviceId = call.argument<Int>("deviceId")
                if (deviceId == null) {
                    result.error("bad_args", "deviceId is required", null)
                    return
                }

                val device = usbManager.deviceList.values.firstOrNull { it.deviceId == deviceId }
                if (device == null) {
                    result.error("not_found", "USB device $deviceId not found", null)
                    return
                }

                if (usbManager.hasPermission(device)) {
                    openDevice(device, result)
                } else {
                    if (permissionResult != null) {
                        result.error("busy", "Another USB permission request is in progress", null)
                        return
                    }

                    permissionResult = result
                    pendingDevice = device
                    val pendingIntent = PendingIntent.getBroadcast(
                        this,
                        device.deviceId,
                        Intent(usbPermissionAction),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                    )
                    usbManager.requestPermission(device, pendingIntent)
                }
            }

            "closeUsbDevice" -> {
                closeCurrentConnection()
                result.success(null)
            }

            "saveImageToGallery" -> {
                val bytes = call.argument<ByteArray>("bytes")
                val displayName = call.argument<String>("displayName")
                val mimeType = call.argument<String>("mimeType") ?: "image/png"
                if (bytes == null || bytes.isEmpty()) {
                    result.error("bad_args", "bytes is required", null)
                    return
                }
                if (displayName.isNullOrBlank()) {
                    result.error("bad_args", "displayName is required", null)
                    return
                }

                saveImageToGallery(bytes, displayName, mimeType, result)
            }

            else -> result.notImplemented()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CAMERA_PERMISSION_REQUEST_CODE) {
            return
        }

        val result = cameraPermissionResult ?: return
        cameraPermissionResult = null
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        result.success(granted)
    }

    private fun openDevice(device: UsbDevice, result: MethodChannel.Result) {
        closeCurrentConnection()
        val connection = usbManager.openDevice(device)
        if (connection == null) {
            result.error("open_failed", "Unable to open USB device", null)
            return
        }
        currentDevice = device
        currentConnection = connection

        result.success(
            mapOf(
                "fileDescriptor" to connection.fileDescriptor,
                "deviceId" to device.deviceId,
                "vendorId" to device.vendorId,
                "productId" to device.productId,
                "productName" to (device.productName ?: ""),
                "manufacturerName" to (device.manufacturerName ?: "")
            )
        )
    }

    private fun safeSerialNumber(device: UsbDevice): String {
        return try {
            device.serialNumber ?: ""
        } catch (_: SecurityException) {
            ""
        }
    }

    private fun saveImageToGallery(
        bytes: ByteArray,
        displayName: String,
        mimeType: String,
        result: MethodChannel.Result
    ) {
        val resolver = applicationContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, mimeType)
            put(
                MediaStore.Images.Media.RELATIVE_PATH,
                Environment.DIRECTORY_PICTURES + "/flutter_ffi_uvc_example"
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Images.Media.IS_PENDING, 1)
            }
        }

        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
        if (uri == null) {
            result.error("save_failed", "Failed to create gallery entry", null)
            return
        }

        try {
            resolver.openOutputStream(uri)?.use { stream ->
                stream.write(bytes)
                stream.flush()
            } ?: throw IllegalStateException("Failed to open gallery output stream")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val publishValues = ContentValues().apply {
                    put(MediaStore.Images.Media.IS_PENDING, 0)
                }
                resolver.update(uri, publishValues, null, null)
            }

            result.success(uri.toString())
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            result.error("save_failed", error.message ?: "Failed to save image", null)
        }
    }

    private fun closeCurrentConnection() {
        currentConnection?.close()
        currentConnection = null
        currentDevice = null
    }

    private fun isVideoDevice(device: UsbDevice): Boolean {
        if (device.deviceClass == 14) {
            return true
        }

        for (index in 0 until device.interfaceCount) {
            if (device.getInterface(index).interfaceClass == 14) {
                return true
            }
        }

        return false
    }
}
