package com.pushstr.pushstr_mobile

import android.app.DownloadManager
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.OpenableColumns
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.ContentValues
import android.provider.MediaStore

class MainActivity : FlutterActivity() {
    private val channelName = "com.pushstr.share"
    private var channel: MethodChannel? = null
    private val storageChannelName = "com.pushstr.storage"
    private val prefsMaxBytes = 5L * 1024L * 1024L
    private val prefsBackupName = "FlutterSharedPreferences.backup.xml"
    private val prefsBackupMarker = "prefs_backup_pending.txt"

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
                "getPrefsBackupInfo" -> result.success(getPrefsBackupInfo())
                "exportPrefsBackup" -> {
                    val name = call.argument<String>("name") ?: "pushstr_prefs_backup.xml"
                    result.success(exportPrefsBackup(name))
                }
                "saveToDownloads" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val mime = call.argument<String>("mime") ?: "application/octet-stream"
                    val filename = call.argument<String>("filename") ?: "pushstr_download"
                    if (bytes == null) {
                        result.error("missing_bytes", "Missing bytes", null)
                    } else {
                        result.success(saveToDownloads(bytes, mime, filename))
                    }
                }
                "clearPrefsBackup" -> result.success(clearPrefsBackup())
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

    private fun getPrefsBackupInfo(): Map<String, Any?> {
        val backup = File(filesDir, prefsBackupName)
        val marker = File(filesDir, prefsBackupMarker)
        return mapOf(
            "exists" to backup.exists(),
            "size" to if (backup.exists()) backup.length() else 0L,
            "lastModified" to if (backup.exists()) backup.lastModified() else 0L,
            "pending" to marker.exists()
        )
    }

    private fun exportPrefsBackup(name: String): String? {
        val backup = File(filesDir, prefsBackupName)
        if (!backup.exists()) return null
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, "text/xml")
            put(MediaStore.Downloads.RELATIVE_PATH, "Download/Pushstr")
        }
        val resolver = contentResolver
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
        resolver.openOutputStream(uri)?.use { output ->
            FileInputStream(backup).use { input ->
                input.copyTo(output)
            }
        }
        return uri.toString()
    }

    private fun saveToDownloads(bytes: ByteArray, mime: String, filename: String): String? {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, filename)
                    put(MediaStore.Downloads.MIME_TYPE, mime)
                    put(MediaStore.Downloads.RELATIVE_PATH, "Download")
                }
                val resolver = contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return null
                resolver.openOutputStream(uri)?.use { output ->
                    output.write(bytes)
                }
                uri.toString()
            } else {
                val dir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                val file = File(dir, filename)
                FileOutputStream(file).use { it.write(bytes) }
                val dm = getSystemService(DOWNLOAD_SERVICE) as DownloadManager
                dm.addCompletedDownload(
                    filename,
                    filename,
                    true,
                    mime,
                    file.absolutePath,
                    file.length(),
                    true
                )
                file.absolutePath
            }
        } catch (e: Exception) {
            null
        }
    }

    private fun clearPrefsBackup(): Boolean {
        val backup = File(filesDir, prefsBackupName)
        val marker = File(filesDir, prefsBackupMarker)
        if (backup.exists()) backup.delete()
        if (marker.exists()) marker.delete()
        return true
    }
}
