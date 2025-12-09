package com.pushstr.pushstr_mobile

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.pushstr.share"
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialShare" -> {
                    result.success(extractShareData(intent))
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        sendShareToDart(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        sendShareToDart(intent)
    }

    private fun sendShareToDart(intent: Intent?) {
        val data = extractShareData(intent) ?: return
        channel?.invokeMethod("onShare", data)
    }

    private fun extractShareData(intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        if (intent.action != Intent.ACTION_SEND) return null
        val type = intent.type ?: return null
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val stream: Uri? = intent.getParcelableExtra(Intent.EXTRA_STREAM)
        val resolvedType = stream?.let { contentResolver.getType(it) } ?: type

        var name: String? = null
        var bytes: ByteArray? = null

        if (stream != null) {
            name = queryName(stream)
            bytes = readBytes(stream)
        }

        return mapOf(
            "type" to resolvedType,
            "text" to text,
            "uri" to stream?.toString(),
            "name" to name,
            "bytes" to bytes
        )
    }

    private fun queryName(uri: Uri): String? {
        val cursor = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null) ?: return null
        cursor.use {
            if (it.moveToFirst()) {
                val idx = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx != -1) return it.getString(idx)
            }
        }
        return null
    }

    private fun readBytes(uri: Uri, maxSize: Int = 20 * 1024 * 1024): ByteArray? {
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArrayOutputStream()
                val chunk = ByteArray(8 * 1024)
                var total = 0
                while (true) {
                    val read = input.read(chunk)
                    if (read == -1) break
                    total += read
                    if (total > maxSize) {
                        // Don't try to ingest huge files via the share sheet; let the user pick smaller media.
                        return null
                    }
                    buffer.write(chunk, 0, read)
                }
                buffer.toByteArray()
            }
        } catch (e: Exception) {
            null
        }
    }
}
