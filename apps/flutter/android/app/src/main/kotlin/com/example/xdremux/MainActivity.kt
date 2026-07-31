package com.example.xdremux

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val batteryChannel = "xdremux/battery"
    private val hevcProbeChannel = "xdremux/hevc-probe"
    private val hwEncodeChannel = "xdremux/hw-encode"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, batteryChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            val intent = Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName"),
                            )
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "openOemBatterySettings" -> {
                        result.success(openOemBatterySettings())
                    }
                    else -> result.notImplemented()
                }
            }
        // Diagnostic probe for the planned MediaCodec hardware-encoding path:
        // lists HEVC encoders and reports whether a 4:2:0 / 4:4:4 encoder can
        // actually be configured. Results feed the decision on whether the
        // gain map needs chroma downsampling for the hardware path.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, hevcProbeChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "probe" -> result.success(probeHevcEncoderSupport())
                    else -> result.notImplemented()
                }
            }

        // Hardware HEVC tile encoding: receives packed YUV420 tile buffers and
        // returns Annex-B HEVC streams (or null on failure → x265 fallback).
        // Runs on a background thread — MediaCodec blocks while encoding.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, hwEncodeChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "encodeTile" -> {
                        val args = call.arguments as Map<*, *>
                        val yuv = args["yuv"] as ByteArray
                        val width = (args["width"] as Number).toInt()
                        val height = (args["height"] as Number).toInt()
                        Thread {
                            val stream = MediaCodecHevcEncoder.encodeTile(yuv, width, height)
                            runOnUiThread {
                                result.success(stream)
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Returns a map describing HEVC encoder capabilities:
    /// encoders, advertised color formats, and whether a 4:2:0 / 4:4:4 encoder
    /// can be configured in practice (the configure attempt is the ground
    /// truth — advertised formats alone over-report support).
    private fun probeHevcEncoderSupport(): Map<String, Any?> {
        val mime = MediaFormat.MIMETYPE_VIDEO_HEVC
        val all = MediaCodecList(MediaCodecList.ALL_CODECS)
        val codecInfos = all.codecInfos
        val encoderNames = codecInfos
            .filter { it.isEncoder && it.supportedTypes.any { t -> t.equals(mime, true) } }
            .map { it.name }
            .distinct()

        val colorFormats = LinkedHashSet<Int>()
        for (name in encoderNames) {
            val info = codecInfos.firstOrNull { it.name == name } ?: continue
            val caps = info.getCapabilitiesForType(mime)
            caps.colorFormats.forEach { colorFormats.add(it) }
        }

        fun tryConfigure(colorFormat: Int): String {
            return try {
                val enc = MediaCodec.createEncoderByType(mime)
                val f = MediaFormat.createVideoFormat(mime, 64, 64)
                f.setInteger(MediaFormat.KEY_COLOR_FORMAT, colorFormat)
                f.setInteger(MediaFormat.KEY_BIT_RATE, 200_000)
                f.setInteger(MediaFormat.KEY_FRAME_RATE, 1)
                f.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
                enc.configure(f, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                enc.release()
                "ok"
            } catch (e: Exception) {
                e.message ?: e.javaClass.simpleName
            }
        }

        // 0x7F420444 = COLOR_FormatYUV444Flexible; not a public constant,
        // and rarely advertised, but some vendors honor it in configure().
        val yuv420 = MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible
        val yuv444 = 0x7F420444

        val chipset = if (Build.VERSION.SDK_INT >= 31) {
            "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}".trim()
        } else {
            Build.HARDWARE
        }

        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "sdkInt" to Build.VERSION.SDK_INT,
            "chipset" to chipset,
            "encoders" to encoderNames,
            "colorFormats" to colorFormats.toList(),
            "config420Flexible" to tryConfigure(yuv420),
            "config444Flexible" to tryConfigure(yuv444),
        )
    }

    /// Try to open the OEM-specific battery/power management page.
    /// Falls back to the generic app details settings if no OEM page is found.
    private fun openOemBatterySettings(): Boolean {
        val intents = listOf(
            // OPPO/ColorOS: 耗电行为控制
            Intent().setComponent(
                ComponentName(
                    "com.oplus.battery",
                    "com.oplus.powermanager.fuelgaue.PowerControlActivity",
                ),
            ),
            // Xiaomi/MIUI: 电池与性能 → 应用耗电管理
            Intent().setComponent(
                ComponentName(
                    "com.miui.powerkeeper",
                    "com.miui.powerkeeper.ui.HiddenAppsSetupActivity",
                ),
            ),
            // Huawei/EMUI: 启动管理
            Intent().setComponent(
                ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
                ),
            ),
            // Vivo/OriginOS: 后台耗电管理
            Intent().setComponent(
                ComponentName(
                    "com.vivo.permissionmanager",
                    "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
                ),
            ),
            // Samsung: 后台使用限制
            Intent().setComponent(
                ComponentName(
                    "com.samsung.android.lool",
                    "com.samsung.android.sm.ui.battery.BatteryActivity",
                ),
            ),
        )

        for (intent in intents) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            } catch (_: ActivityNotFoundException) {
                // Try next OEM
            } catch (_: SecurityException) {
                // Try next OEM
            }
        }

        // Fallback: generic app details settings
        return try {
            val intent = Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName"),
            )
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}
