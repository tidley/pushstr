package com.pushstr.pushstr_mobile

import android.app.Application
import java.io.File

class PushstrApplication : Application() {
    override fun onCreate() {
        // Must happen before any SharedPreferences access to avoid OOM.
        backupSharedPrefsIfNeeded()
        super.onCreate()
    }

    private fun backupSharedPrefsIfNeeded() {
        val prefsFile = File(applicationInfo.dataDir, "shared_prefs/FlutterSharedPreferences.xml")
        if (!prefsFile.exists()) return
        val maxBytes = 5L * 1024L * 1024L
        if (prefsFile.length() <= maxBytes) return
        val backupFile = File(filesDir, "FlutterSharedPreferences.backup.xml")
        backupFile.parentFile?.mkdirs()
        prefsFile.renameTo(backupFile)
        val marker = File(filesDir, "prefs_backup_pending.txt")
        marker.writeText("${backupFile.absolutePath}\n${backupFile.length()}\n${backupFile.lastModified()}")
        File(prefsFile.parentFile, "FlutterSharedPreferences.xml.bak").delete()
    }
}
