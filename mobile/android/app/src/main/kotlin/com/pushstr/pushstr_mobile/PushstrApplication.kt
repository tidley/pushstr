package com.pushstr.pushstr_mobile

import android.app.Application
import java.io.File

class PushstrApplication : Application() {
    override fun onCreate() {
        // Must happen before any SharedPreferences access to avoid OOM.
        sanitizeSharedPrefsIfNeeded()
        super.onCreate()
    }

    private fun sanitizeSharedPrefsIfNeeded() {
        val prefsFile = File(applicationInfo.dataDir, "shared_prefs/FlutterSharedPreferences.xml")
        if (!prefsFile.exists()) return
        val maxBytes = 5L * 1024L * 1024L
        if (prefsFile.length() <= maxBytes) return
        // If oversized, delete outright to avoid loading/parsing.
        prefsFile.delete()
        File(prefsFile.parentFile, "FlutterSharedPreferences.xml.bak").delete()
    }
}
