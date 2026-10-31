package com.example.xdremux

import android.content.Context
import android.net.wifi.WifiManager
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
                    else -> result.notImplemented()
                }
            } catch (_: Exception) {
                release()
                result.error("discovery_unavailable", "Multicast unavailable; use direct connection", null)
            }
        }
    }
    fun release() {
        try { if (lock?.isHeld == true) lock?.release() } catch (_: Exception) { }
    }
}
