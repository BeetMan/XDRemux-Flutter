package com.example.xdremux

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.plugin.common.MethodChannel

/** Foreground, non-reference-counted Wi-Fi multicast reception only. */
class TransferMulticast(private val context: Context) {
    private var lock: WifiManager.MulticastLock? = null
    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "isHeld" -> result.success(lock?.isHeld == true)
                    "acquire" -> {
                        if (lock == null) {
                            val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                            lock = wifi.createMulticastLock("xdremux-transfer").apply { setReferenceCounted(false) }
                        }
                        if (lock?.isHeld != true) lock?.acquire()
                        result.success(null)
                    }
                    "release" -> { release(); result.success(null) }
                    "modelName" -> result.success(modelName())
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                release()
                result.error("discovery_unavailable", "Multicast unavailable; use direct connection", null)
            }
        }
    }
    /** Marketing name ("OPPO Find X8 Ultra") for the LAN transfer alias. */
    private fun modelName(): String {
        for (key in listOf(
            "ro.vendor.oplus.market.name", "ro.oppo.market.name", "ro.vivo.market.name",
            "ro.product.marketname", "ro.product.vendor.marketname", "ro.config.marketing_name",
        )) {
            val value = getprop(key)
            if (value.isNotBlank()) return value
        }
        val named = try {
            Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
        } catch (_: Exception) { null }
        if (!named.isNullOrBlank()) return named
        val model = Build.MODEL ?: ""
        return if (model.startsWith(Build.MANUFACTURER ?: "", ignoreCase = true)) model
        else "${Build.MANUFACTURER} $model".trim()
    }

    private fun getprop(key: String): String = try {
        val process = ProcessBuilder("getprop", key).redirectErrorStream(true).start()
        process.inputStream.bufferedReader().use { it.readText() }.trim()
            .also { process.waitFor() }
    } catch (_: Exception) { "" }

    fun release() {
        try { if (lock?.isHeld == true) lock?.release() } catch (_: Exception) { }
    }
}
