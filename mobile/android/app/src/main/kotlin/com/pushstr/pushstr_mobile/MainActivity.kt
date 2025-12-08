package com.pushstr.pushstr_mobile

import android.content.Intent
import android.net.Uri
import android.os.Bundle
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

        return mapOf(
            "type" to type,
            "text" to text,
            "uri" to stream?.toString()
        )
    }
}
