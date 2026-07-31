package com.cornpip.flutter_ffi_uvc_example

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "flutter_ffi_uvc_example/gallery",
        )
        channel.setMethodCallHandler(this)
    }

    override fun onDestroy() {
        channel.setMethodCallHandler(null)
        super.onDestroy()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
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

            "saveVideoToGallery" -> {
                val path = call.argument<String>("path")
                val displayName = call.argument<String>("displayName")
                val mimeType = call.argument<String>("mimeType") ?: "video/mp4"
                if (path.isNullOrBlank()) {
                    result.error("bad_args", "path is required", null)
                    return
                }
                if (displayName.isNullOrBlank()) {
                    result.error("bad_args", "displayName is required", null)
                    return
                }
                saveVideoToGallery(path, displayName, mimeType, result)
            }

            else -> result.notImplemented()
        }
    }

    private fun saveImageToGallery(
        bytes: ByteArray,
        displayName: String,
        mimeType: String,
        result: MethodChannel.Result,
    ) {
        val resolver = applicationContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Images.Media.MIME_TYPE, mimeType)
            put(
                MediaStore.Images.Media.RELATIVE_PATH,
                Environment.DIRECTORY_PICTURES + "/flutter_ffi_uvc_example",
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

    private fun saveVideoToGallery(
        path: String,
        displayName: String,
        mimeType: String,
        result: MethodChannel.Result,
    ) {
        val source = java.io.File(path)
        if (!source.isFile) {
            result.error("save_failed", "Recording file not found: $path", null)
            return
        }

        val resolver = applicationContext.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Video.Media.MIME_TYPE, mimeType)
            put(
                MediaStore.Video.Media.RELATIVE_PATH,
                Environment.DIRECTORY_MOVIES + "/flutter_ffi_uvc_example",
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Video.Media.IS_PENDING, 1)
            }
        }

        val uri = resolver.insert(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, values)
        if (uri == null) {
            result.error("save_failed", "Failed to create gallery entry", null)
            return
        }

        try {
            resolver.openOutputStream(uri)?.use { stream ->
                source.inputStream().use { input -> input.copyTo(stream) }
                stream.flush()
            } ?: throw IllegalStateException("Failed to open gallery output stream")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val publishValues = ContentValues().apply {
                    put(MediaStore.Video.Media.IS_PENDING, 0)
                }
                resolver.update(uri, publishValues, null, null)
            }

            source.delete()
            result.success(uri.toString())
        } catch (error: Exception) {
            resolver.delete(uri, null, null)
            result.error("save_failed", error.message ?: "Failed to save video", null)
        }
    }
}
