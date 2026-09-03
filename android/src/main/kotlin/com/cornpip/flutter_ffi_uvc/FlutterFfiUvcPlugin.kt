package com.cornpip.flutter_ffi_uvc

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.usb.UsbConstants
import android.hardware.usb.UsbDevice
import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbManager
import android.os.Build
import android.util.Log
import android.view.Surface
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
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
        private const val TAG = "flutter_ffi_uvc"

        init {
            System.loadLibrary("flutter_ffi_uvc")
        }
    }

    // Texture
    private lateinit var textureChannel: MethodChannel
    private lateinit var textureRegistry: TextureRegistry
    private val textures = mutableMapOf<Long, TextureRegistry.SurfaceTextureEntry>()
    // Native session handle -> texture id currently attached to that session.
    private val attachedTextures = mutableMapOf<Long, Long>()

    // USB
    private lateinit var usbChannel: MethodChannel
    private lateinit var deviceEventChannel: EventChannel
    private var deviceEventSink: EventChannel.EventSink? = null
    private var deviceEventReceiverRegistered = false
    private var appContext: Context? = null
    private var activity: Activity? = null
    private var usbManager: UsbManager? = null
    // Native session handle -> the USB connection that session opened.
    private val connections = mutableMapOf<Long, OpenConnection>()
    // USB deviceId -> the open request waiting on the permission dialog.
    private val pendingUsbOpens = mutableMapOf<Int, PendingUsbOpen>()
    private val cameraPermissionResults = mutableListOf<MethodChannel.Result>()

    private class OpenConnection(val device: UsbDevice, val connection: UsbDeviceConnection)
    private class PendingUsbOpen(val sessionHandle: Long, val result: MethodChannel.Result)

    private val usbPermissionAction: String
        get() = "${appContext?.packageName}.flutter_ffi_uvc.USB_PERMISSION"

    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != usbPermissionAction) return

            val device: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }
            if (device == null) {
                // No device in the grant. Nothing can be matched, so fail
                // every waiting request.
                val waiting = pendingUsbOpens.values.toList()
                pendingUsbOpens.clear()
                waiting.forEach { it.result.error("permission_denied", "USB permission denied", null) }
                return
            }
            // The grant names its device. Complete only that request.
            val pending = pendingUsbOpens.remove(device.deviceId) ?: return

            val granted = intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
            if (!granted) {
                pending.result.error("permission_denied", "USB permission denied", null)
                return
            }
            openDevice(pending.sessionHandle, device, pending.result)
        }
    }

    private val deviceEventReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val eventType = when (intent?.action) {
                UsbManager.ACTION_USB_DEVICE_ATTACHED -> "attached"
                UsbManager.ACTION_USB_DEVICE_DETACHED -> "detached"
                else -> return
            }
            val device: UsbDevice? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE, UsbDevice::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
            }
            if (device == null || !isVideoDevice(device)) return
            deviceEventSink?.success(
                mapOf("event" to eventType, "device" to deviceToMap(device)),
            )
        }
    }

    private fun registerDeviceEventReceiver() {
        val context = appContext ?: return
        if (deviceEventReceiverRegistered) return
        val filter = IntentFilter().apply {
            addAction(UsbManager.ACTION_USB_DEVICE_ATTACHED)
            addAction(UsbManager.ACTION_USB_DEVICE_DETACHED)
        }
        // ATTACHED/DETACHED are protected system broadcasts, so an exported
        // receiver cannot be spoofed by other apps.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(deviceEventReceiver, filter, Context.RECEIVER_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            context.registerReceiver(deviceEventReceiver, filter)
        }
        deviceEventReceiverRegistered = true
    }

    private fun unregisterDeviceEventReceiver() {
        if (!deviceEventReceiverRegistered) return
        try { appContext?.unregisterReceiver(deviceEventReceiver) } catch (_: Exception) {}
        deviceEventReceiverRegistered = false
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

        deviceEventChannel = EventChannel(binding.binaryMessenger, "flutter_ffi_uvc/device_events")
        deviceEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                deviceEventSink = events
                registerDeviceEventReceiver()
            }

            override fun onCancel(arguments: Any?) {
                unregisterDeviceEventReceiver()
                deviceEventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attachedTextures.keys.toList().forEach { nativeDetachSurface(it) }
        attachedTextures.clear()
        textures.values.forEach { it.release() }
        textures.clear()
        textureChannel.setMethodCallHandler(null)
        usbChannel.setMethodCallHandler(null)
        unregisterDeviceEventReceiver()
        deviceEventChannel.setStreamHandler(null)
        deviceEventSink = null
        connections.keys.toList().forEach { closeConnection(it) }
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
        detachActivity()
        // The dialog's answer can no longer reach this listener. Fail the
        // waiters so the next call shows a fresh dialog.
        val waiting = cameraPermissionResults.toList()
        cameraPermissionResults.clear()
        waiting.forEach { it.success(false) }
        val pending = pendingUsbOpens.values.toList()
        pendingUsbOpens.clear()
        pending.forEach { it.result.error("no_activity", "Activity detached during USB permission request", null) }
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        // The activity comes back. Keep the waiters so the dialog's answer
        // still reaches them after reattach.
        detachActivity()
    }

    private fun detachActivity() {
        try { activity?.unregisterReceiver(permissionReceiver) } catch (_: Exception) {}
        activity = null
    }

    // ── RequestPermissionsResultListener ─────────────────────────────────────

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != CAMERA_PERMISSION_REQUEST_CODE) return false
        if (cameraPermissionResults.isEmpty()) return false
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        // One dialog answers every caller that was waiting on it.
        val waiting = cameraPermissionResults.toList()
        cameraPermissionResults.clear()
        waiting.forEach { it.success(granted) }
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
                detachTextureOwners(textureId)
                textures.remove(textureId)?.release()
                result.success(null)
            }

            "attachPreviewTexture" -> {
                val sessionHandle = sessionHandleArg(call, result) ?: return
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
                // One texture per session and one session per texture.
                detachTextureOwners(textureId)
                attachedTextures.remove(sessionHandle)?.let { nativeDetachSurface(sessionHandle) }
                val surface = Surface(entry.surfaceTexture())
                try {
                    val attachResult = nativeAttachSurface(sessionHandle, surface)
                    if (attachResult != 0) {
                        result.error(
                            "attach_failed",
                            "nativeAttachSurface failed with code $attachResult",
                            attachResult,
                        )
                        return
                    }
                    attachedTextures[sessionHandle] = textureId
                    result.success(null)
                } finally {
                    surface.release()
                }
            }

            "detachPreviewSession" -> {
                // Dart calls this before destroying the session.
                val sessionHandle = sessionHandleArg(call, result) ?: return
                if (attachedTextures.remove(sessionHandle) != null) {
                    nativeDetachSurface(sessionHandle)
                }
                result.success(null)
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
                        .map { deviceToMap(it) },
                )
            }

            "openUsbDevice" -> {
                val sessionHandle = sessionHandleArg(call, result) ?: return
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
                    openDevice(sessionHandle, device, result)
                } else {
                    if (pendingUsbOpens.containsKey(deviceId)) {
                        result.error("busy", "A USB permission request for this device is in progress", null)
                        return
                    }
                    val act = activity ?: run {
                        result.error("no_activity", "Activity not available for USB permission", null)
                        return
                    }
                    pendingUsbOpens[deviceId] = PendingUsbOpen(sessionHandle, result)
                    val pendingIntent = PendingIntent.getBroadcast(
                        act,
                        deviceId,
                        Intent(usbPermissionAction).apply { `package` = act.packageName },
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                    )
                    manager.requestPermission(device, pendingIntent)
                }
            }

            "closeUsbDevice" -> {
                val sessionHandle = sessionHandleArg(call, result) ?: return
                // Cancel a permission request still pending for this session.
                val cancelled = pendingUsbOpens.filterValues { it.sessionHandle == sessionHandle }
                cancelled.keys.forEach { pendingUsbOpens.remove(it) }
                cancelled.values.forEach { it.result.error("closed", "Session closed while waiting for USB permission", null) }
                closeConnection(sessionHandle)
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
                    // The first waiter shows the dialog. Later callers share
                    // its answer.
                    cameraPermissionResults.add(result)
                    if (cameraPermissionResults.size == 1) {
                        ActivityCompat.requestPermissions(
                            act,
                            arrayOf(android.Manifest.permission.CAMERA),
                            CAMERA_PERMISSION_REQUEST_CODE,
                        )
                    }
                }
            }

            else -> result.notImplemented()
        }
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    private fun sessionHandleArg(call: MethodCall, result: MethodChannel.Result): Long? {
        val handle = call.argument<Number>("sessionHandle")?.toLong()
        if (handle == null || handle == 0L) {
            result.error("invalid_args", "sessionHandle is required.", null)
            return null
        }
        return handle
    }

    private fun openDevice(sessionHandle: Long, device: UsbDevice, result: MethodChannel.Result) {
        // A session holds one device. Opening another replaces it.
        closeConnection(sessionHandle)
        // A dead session still holding this device was leaked by a hot
        // restart. Release its connection. A live session keeps its
        // connection and this open fails at the USB interface claim.
        connections.filterValues { it.device.deviceId == device.deviceId }.keys
            .filterNot { nativeSessionIsLive(it) }
            .forEach { closeConnection(it) }
        val connection = usbManager?.openDevice(device)
        if (connection == null) {
            result.error("open_failed", "Unable to open USB device", null)
            return
        }
        logUsbDeviceLayout(device, connection)
        connections[sessionHandle] = OpenConnection(device, connection)
        result.success(mapOf("fileDescriptor" to connection.fileDescriptor))
    }

    private fun closeConnection(sessionHandle: Long) {
        connections.remove(sessionHandle)?.connection?.close()
    }

    private fun detachTextureOwners(textureId: Long) {
        val owners = attachedTextures.filterValues { it == textureId }.keys.toList()
        owners.forEach {
            nativeDetachSurface(it)
            attachedTextures.remove(it)
        }
    }

    private fun deviceToMap(device: UsbDevice): Map<String, Any> = mapOf(
        "deviceId" to device.deviceId,
        "deviceName" to device.deviceName,
        "vendorId" to device.vendorId,
        "productId" to device.productId,
        "productName" to (device.productName ?: ""),
        "manufacturerName" to (device.manufacturerName ?: ""),
        "serialNumber" to safeSerialNumber(device),
        // hasPermission can be queried for a device that is already gone
        // (detach events), so treat failures as "no permission".
        "hasPermission" to runCatching { usbManager?.hasPermission(device) == true }
            .getOrDefault(false),
    )

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

    private fun logUsbDeviceLayout(device: UsbDevice, connection: UsbDeviceConnection) {
        Log.d(
            TAG,
            "@@@@UVC_ANDROID/D openDevice id=${device.deviceId} name=${device.deviceName} " +
                "vendor=${device.vendorId} product=${device.productId} " +
                "fd=${connection.fileDescriptor} configs=${device.configurationCount} " +
                "interfaces=${device.interfaceCount}",
        )
        for (configIndex in 0 until device.configurationCount) {
            val config = device.getConfiguration(configIndex)
            Log.d(
                TAG,
                "@@@@UVC_ANDROID/D config index=$configIndex id=${config.id} " +
                    "name=${config.name ?: ""} interfaces=${config.interfaceCount}",
            )
            for (interfaceIndex in 0 until config.interfaceCount) {
                val usbInterface = config.getInterface(interfaceIndex)
                Log.d(
                    TAG,
                    "@@@@UVC_ANDROID/D interface config=$configIndex index=$interfaceIndex " +
                        "id=${usbInterface.id} alt=${usbInterface.alternateSetting} " +
                        "class=${usbInterface.interfaceClass} subclass=${usbInterface.interfaceSubclass} " +
                        "protocol=${usbInterface.interfaceProtocol} endpoints=${usbInterface.endpointCount}",
                )
                for (endpointIndex in 0 until usbInterface.endpointCount) {
                    val endpoint = usbInterface.getEndpoint(endpointIndex)
                    Log.d(
                        TAG,
                        "@@@@UVC_ANDROID/D endpoint interface=${usbInterface.id} " +
                            "alt=${usbInterface.alternateSetting} index=$endpointIndex " +
                            "address=0x${endpoint.address.toString(16)} " +
                            "type=${usbEndpointTypeName(endpoint.type)} " +
                            "direction=${if (endpoint.direction == UsbConstants.USB_DIR_IN) "IN" else "OUT"} " +
                            "maxPacket=${endpoint.maxPacketSize} interval=${endpoint.interval}",
                    )
                }
            }
        }
    }

    private fun usbEndpointTypeName(type: Int): String = when (type) {
        UsbConstants.USB_ENDPOINT_XFER_CONTROL -> "CONTROL"
        UsbConstants.USB_ENDPOINT_XFER_ISOC -> "ISOC"
        UsbConstants.USB_ENDPOINT_XFER_BULK -> "BULK"
        UsbConstants.USB_ENDPOINT_XFER_INT -> "INT"
        else -> type.toString()
    }

    // ── JNI ──────────────────────────────────────────────────────────────────

    private external fun nativeAttachSurface(sessionHandle: Long, surface: Surface): Int
    private external fun nativeDetachSurface(sessionHandle: Long)
    private external fun nativeSessionIsLive(sessionHandle: Long): Boolean
}
