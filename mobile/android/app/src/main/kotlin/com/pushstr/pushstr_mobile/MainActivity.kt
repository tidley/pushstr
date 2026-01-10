package com.pushstr.pushstr_mobile

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlSerializer

class MainActivity : FlutterActivity() {
    private val channelName = "com.pushstr.share"
    private var channel: MethodChannel? = null
    private val storageChannelName = "com.pushstr.storage"
    private val prefsMaxBytes = 5L * 1024L * 1024L
    private val prefsDropPrefixes = listOf("messages", "pending_dms")

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

        val storageChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, storageChannelName)
        storageChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "sanitizeSharedPrefs" -> {
                    val maxBytes = (call.argument<Number>("maxBytes")?.toLong() ?: 0L)
                    val dropPrefixes = call.argument<List<String>>("dropPrefixes") ?: emptyList()
                    result.success(sanitizeSharedPrefs(maxBytes, dropPrefixes))
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
        try {
            sanitizeSharedPrefs(prefsMaxBytes, prefsDropPrefixes)
        } catch (_: Exception) {
            // Best-effort cleanup; avoid crashing before Flutter starts.
        }
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

    private fun sanitizeSharedPrefs(maxBytes: Long, dropPrefixes: List<String>): Boolean {
        val prefsFile = File(applicationInfo.dataDir, "shared_prefs/FlutterSharedPreferences.xml")
        if (!prefsFile.exists()) return false
        if (maxBytes > 0 && prefsFile.length() <= maxBytes) return false
        val tmpFile = File(prefsFile.parentFile, "FlutterSharedPreferences.tmp")
        try {
            FileInputStream(prefsFile).use { input ->
                FileOutputStream(tmpFile).use { output ->
                    val parser = Xml.newPullParser()
                    parser.setInput(input, "utf-8")
                    val serializer = Xml.newSerializer()
                    serializer.setOutput(output, "utf-8")
                    serializer.startDocument("utf-8", true)
                    serializer.startTag(null, "map")
                    var eventType = parser.eventType
                    while (eventType != XmlPullParser.END_DOCUMENT) {
                        if (eventType == XmlPullParser.START_TAG) {
                            val tag = parser.name
                            if (tag == "map") {
                                // No-op, we already wrote the root map tag.
                            } else {
                                val name = parser.getAttributeValue(null, "name") ?: ""
                                if (shouldDropKey(name, dropPrefixes)) {
                                    skipTag(parser)
                                } else {
                                    when (tag) {
                                        "string" -> {
                                            serializer.startTag(null, "string")
                                            serializer.attribute(null, "name", name)
                                            val text = parser.nextText()
                                            serializer.text(text)
                                            serializer.endTag(null, "string")
                                        }
                                        "int", "long", "float", "boolean" -> {
                                            serializer.startTag(null, tag)
                                            serializer.attribute(null, "name", name)
                                            val value = parser.getAttributeValue(null, "value")
                                            if (value != null) {
                                                serializer.attribute(null, "value", value)
                                            }
                                            serializer.endTag(null, tag)
                                            consumeToEndTag(parser, tag)
                                        }
                                        "set" -> {
                                            serializer.startTag(null, "set")
                                            serializer.attribute(null, "name", name)
                                            var innerEvent = parser.next()
                                            while (!(innerEvent == XmlPullParser.END_TAG && parser.name == "set")) {
                                                if (innerEvent == XmlPullParser.START_TAG && parser.name == "string") {
                                                    serializer.startTag(null, "string")
                                                    val text = parser.nextText()
                                                    serializer.text(text)
                                                    serializer.endTag(null, "string")
                                                }
                                                innerEvent = parser.next()
                                            }
                                            serializer.endTag(null, "set")
                                        }
                                        else -> skipTag(parser)
                                    }
                                }
                            }
                        }
                        eventType = parser.next()
                    }
                    serializer.endTag(null, "map")
                    serializer.endDocument()
                }
            }
            if (!prefsFile.delete()) return false
            if (!tmpFile.renameTo(prefsFile)) return false
            File(prefsFile.parentFile, "FlutterSharedPreferences.xml.bak").delete()
            return true
        } catch (e: Exception) {
            tmpFile.delete()
            return false
        }
    }

    private fun shouldDropKey(name: String, dropPrefixes: List<String>): Boolean {
        for (prefix in dropPrefixes) {
            if (name.startsWith(prefix)) return true
        }
        return false
    }

    private fun skipTag(parser: XmlPullParser) {
        var depth = 1
        while (depth > 0) {
            when (parser.next()) {
                XmlPullParser.START_TAG -> depth++
                XmlPullParser.END_TAG -> depth--
            }
        }
    }

    private fun consumeToEndTag(parser: XmlPullParser, tagName: String) {
        var eventType = parser.eventType
        while (!(eventType == XmlPullParser.END_TAG && parser.name == tagName)) {
            eventType = parser.next()
        }
    }
}
