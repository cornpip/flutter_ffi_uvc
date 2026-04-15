package com.cornpip.flutter_ffi_uvc

import android.view.Surface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

class FlutterFfiUvcPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var textureRegistry: TextureRegistry
    private val textures = mutableMapOf<Long, TextureRegistry.SurfaceTextureEntry>()
    private var attachedTextureId: Long? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "flutter_ffi_uvc/texture")
        channel.setMethodCallHandler(this)
        textureRegistry = binding.textureRegistry
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
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

            "detachPreviewTexture" -> {
                nativeDetachSurface()
                attachedTextureId = null
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        nativeDetachSurface()
        attachedTextureId = null
        textures.values.forEach { it.release() }
        textures.clear()
        channel.setMethodCallHandler(null)
    }

    private external fun nativeAttachSurface(surface: Surface): Int

    private external fun nativeDetachSurface()

    companion object {
        init {
            System.loadLibrary("flutter_ffi_uvc")
        }
    }
}
