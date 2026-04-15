package com.cornpip.flutter_ffi_uvc

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.view.Surface
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry

class FlutterFfiUvcPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    companion object {
        private const val CAMERA_PERMISSION_REQUEST_CODE = 9001

        init {
            System.loadLibrary("flutter_ffi_uvc")
        }
    }

    // Texture
    private lateinit var textureChannel: MethodChannel
    private lateinit var textureRegistry: TextureRegistry
    private val textures = mutableMapOf<Long, TextureRegistry.SurfaceTextureEntry>()
    private var attachedTextureId: Long? = null

    // USB
    private lateinit var usbChannel: MethodChannel
    private var appContext: Context? = null
    private var activity: Activity? = null
    private var usbManager: UsbManager? = null
    private var currentConnection: UsbDeviceConnection? = null
    private var currentDevice: UsbDevice? = null
    private var usbPermissionResult: MethodChannel.Result? = null
    private var cameraPermissionResult: MethodChannel.Result? = null

    private val usbPermissionAction: String
        get() = "${appContext?.packageName}.flutter_ffi_uvc.USB_PERMISSION"

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != usbPermissionAction) return
            val result = usbPermissionResult ?: return

            val device: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }

            val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            usbPermissionResult = null

            if (!granted || device == null) {
                result.error("permission_denied", "USB permission denied", null)
                return
            }
            openDevice(device, result)
        }
    }

    // ── FlutterPlugin ────────────────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        usbManager = binding.applicationContext.getSystemService(Context.USB_SERVICE) as UsbManager
        textureRegistry = binding.textureRegistry

        textureChannel = MethodChannel(binding.binaryMessenger, "flutter_ffi_uvc/texture")
        textureChannel.setMethodCallHandler(this)

        usbChannel = MethodChannel(binding.binaryMessenger, "flutter_ffi_uvc/usb")
        usbChannel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        nativeDetachSurface()
        attachedTextureId = null
        textures.values.forEach { it.release() }
        textures.clear()
        textureChannel.setMethodCallHandler(null)
        usbChannel.setMethodCallHandler(null)
        closeCurrentConnection()
        appContext = null
        usbManager = null
    }

    // ── ActivityAware ────────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
        val filter = IntentFilter(usbPermissionAction)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            binding.activity.registerReceiver(
                permissionReceiver, filter, Context.RECEIVER_NOT_EXPORTED
            )
        } else {
            @Suppress("DEPRECATION")
            binding.activity.registerReceiver(permissionReceiver, filter)
        }
    }

    override fun onDetachedFromActivity() {
        try { activity?.unregisterReceiver(permissionReceiver) } catch (_: Exception) {}
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    // ── RequestPermissionsResultListener ─────────────────────────────────────

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != CAMERA_PERMISSION_REQUEST_CODE) return false
        val result = cameraPermissionResult ?: return false
        cameraPermissionResult = null
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        result.success(granted)
        return true
    }

    // ── MethodCallHandler ────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            // Texture ─────────────────────────────────────────────────────────

            "createPreviewTexture" -> {
                val entry = textureRegistry.createSurfaceTexture()
                textures[entry.id()] = entry
                result.success(entry.id())
            }

            "disposePreviewTexture" -> {
                val textureId = call.argument<Number>("textureId")?.toLong()
                if (textureId == null) {
                    result.error("invalid_args", "textureId is required.", null)
                    return
                }
                if (attachedTextureId == textureId) {
                    nativeDetachSurface()
                    attachedTextureId = null
                }
                textures.remove(textureId)?.release()
                result.success(null)
            }

            "attachPreviewTexture" -> {
                val textureId = call.argument<Number>("textureId")?.toLong()
                val width = call.argument<Number>("width")?.toInt()
                val height = call.argument<Number>("height")?.toInt()
                if (textureId == null) {
                    result.error("invalid_args", "textureId is required.", null)
                    return
                }
                val entry = textures[textureId]
                if (entry == null) {
                    result.error("missing_texture", "Unknown textureId=$textureId", null)
                    return
                }
                if (width != null && height != null && width > 0 && height > 0) {
                    entry.surfaceTexture().setDefaultBufferSize(width, height)
                }
                val surface = Surface(entry.surfaceTexture())
                try {
                    val attachResult = nativeAttachSurface(surface)
                    if (attachResult != 0) {
                        result.error(
                            "attach_failed",
                            "nativeAttachSurface failed with code $attachResult",
                            attachResult,
                        )
                        return
                    }
                    attachedTextureId = textureId
                    result.success(null)
                } finally {
                    surface.release()
                }
            }

            // USB ─────────────────────────────────────────────────────────────

            "listUsbDevices" -> {
                val manager = usbManager ?: run {
                    result.error("unavailable", "UsbManager not available", null)
                    return
                }
                result.success(
                    manager.deviceList.values
                        .filter { isVideoDevice(it) }
                        .map { device ->
                            mapOf(
                                "deviceId" to device.deviceId,
                                "deviceName" to device.deviceName,
                                "vendorId" to device.vendorId,
                                "productId" to device.productId,
                                "productName" to (device.productName ?: ""),
                                "manufacturerName" to (device.manufacturerName ?: ""),
                                "serialNumber" to safeSerialNumber(device),
                                "hasPermission" to manager.hasPermission(device),
                            )
                        },
                )
            }

            "openUsbDevice" -> {
                val manager = usbManager ?: run {
                    result.error("unavailable", "UsbManager not available", null)
                    return
                }
                val deviceId = call.argument<Int>("deviceId") ?: run {
                    result.error("bad_args", "deviceId is required", null)
                    return
                }
                val device = manager.deviceList.values.firstOrNull { it.deviceId == deviceId }
                if (device == null) {
                    result.error("not_found", "USB device $deviceId not found", null)
                    return
                }
                if (manager.hasPermission(device)) {
                    openDevice(device, result)
                } else {
                    if (usbPermissionResult != null) {
                        result.error("busy", "Another USB permission request is in progress", null)
                        return
                    }
                    val act = activity ?: run {
                        result.error("no_activity", "Activity not available for USB permission", null)
                        return
                    }
                    usbPermissionResult = result
                    val pendingIntent = PendingIntent.getBroadcast(
                        act,
                        deviceId,
                        Intent(usbPermissionAction),
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                    )
                    manager.requestPermission(device, pendingIntent)
                }
            }

            "closeUsbDevice" -> {
                closeCurrentConnection()
                result.success(null)
            }

            "ensureCameraPermission" -> {
                val act = activity ?: run {
                    result.error("no_activity", "Activity not available", null)
                    return
                }
                if (ContextCompat.checkSelfPermission(act, android.Manifest.permission.CAMERA)
                    == PackageManager.PERMISSION_GRANTED
                ) {
                    result.success(true)
                } else {
                    cameraPermissionResult = result
                    ActivityCompat.requestPermissions(
                        act,
                        arrayOf(android.Manifest.permission.CAMERA),
                        CAMERA_PERMISSION_REQUEST_CODE,
                    )
                }
            }

            else -> result.notImplemented()
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private fun openDevice(device: UsbDevice, result: MethodChannel.Result) {
        closeCurrentConnection()
        val connection = usbManager?.openDevice(device)
        if (connection == null) {
            result.error("open_failed", "Unable to open USB device", null)
            return
        }
        currentDevice = device
        currentConnection = connection
        result.success(mapOf("fileDescriptor" to connection.fileDescriptor))
    }

    private fun closeCurrentConnection() {
        currentConnection?.close()
        currentConnection = null
        currentDevice = null
    }

    private fun safeSerialNumber(device: UsbDevice): String = try {
        device.serialNumber ?: ""
    } catch (_: SecurityException) {
        ""
    }

    private fun isVideoDevice(device: UsbDevice): Boolean {
        if (device.deviceClass == 14) return true
        for (index in 0 until device.interfaceCount) {
            if (device.getInterface(index).interfaceClass == 14) return true
        }
        return false
    }

    // ── JNI ──────────────────────────────────────────────────────────────────

    private external fun nativeAttachSurface(surface: Surface): Int
    private external fun nativeDetachSurface()
}
