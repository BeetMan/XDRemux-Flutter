package com.example.xdremux

import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val batteryChannel = "xdremux/battery"
    private val hevcProbeChannel = "xdremux/hevc-probe"
    private val hwEncodeChannel = "xdremux/hw-encode"
    private val thumbnailChannel = "xdremux/thumbnail"
    private val fileImportChannel = "xdremux/file-import"

    // Single worker for thumbnail decoding. The Android software HEVC decoder
    // (C2SoftHevcDec) crashes under concurrent HEIC decodes, and concurrent
    // full-resolution HEIC allocations blow the heap — serialize them.
    private val thumbnailExecutor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "xdremux-thumbnail").apply { priority = Thread.NORM_PRIORITY }
    }
    private val thumbnailCache = java.util.concurrent.ConcurrentHashMap<String, ByteArray?>()

    override fun onDestroy() {
        thumbnailExecutor.shutdownNow()
        super.onDestroy()
    }

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
                    "canEncode" -> {
                        Thread {
                            val ok = MediaCodecHevcEncoder.canEncode420()
                            runOnUiThread {
                                result.success(ok)
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }

        // Thumbnail rendering: decode the primary HEIC image with the Android
        // system decoder and return a downscaled JPEG. The Rust FFI fallback
        // scans for embedded JPEGs, which picks up the grayscale gain map
        // (black-and-white preview) or a corrupt fragment, so the system
        // decoder is preferred on Android. Decodes run on a single worker to
        // avoid concurrent HEVC decoder crashes and heap exhaustion.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, thumbnailChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "render" -> {
                        val args = call.arguments as Map<*, *>
                        val path = args["path"] as? String
                        val maxPixelSize = (args["maxPixelSize"] as? Number)?.toInt() ?: 320
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        thumbnailCache[path]?.let {
                            if (it != null) result.success(it) else result.success(null)
                            return@setMethodCallHandler
                        }
                        thumbnailExecutor.execute {
                            val jpeg = renderThumbnailJpeg(path, maxPixelSize)
                            // ConcurrentHashMap rejects null values (putVal
                            // throws NPE), so only cache successful decodes. A
                            // failed decode is worth retrying next time anyway.
                            if (jpeg != null) thumbnailCache[path] = jpeg
                            runOnUiThread { result.success(jpeg) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Import a picked file from its content:// URI, copying the raw bytes
        // to a cache file. file_picker's cache copy drops EXIF GPS on some
        // OEMs (OPPO), so re-reading the original bytes via ContentResolver
        // preserves the metadata. Runs on a background thread; never loads the
        // whole file into Dart memory.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, fileImportChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "importFromUri" -> {
                        val args = call.arguments as Map<*, *>
                        val uriString = args["uri"] as? String
                        val destPath = args["destPath"] as? String
                        if (uriString == null || destPath == null) {
                            result.error("bad_args", "uri and destPath are required", null)
                            return@setMethodCallHandler
                        }
                        thumbnailExecutor.execute {
                            val ok = importRawBytes(uriString, destPath)
                            runOnUiThread { result.success(ok) }
                        }
                    }
                    "probePath" -> {
                        val args = call.arguments as Map<*, *>
                        val path = args["path"] as? String
                        if (path == null) {
                            result.error("bad_args", "path is required", null)
                            return@setMethodCallHandler
                        }
                        thumbnailExecutor.execute {
                            val info = probePathInfo(path)
                            runOnUiThread { result.success(info) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Diagnose whether `path` is a readable real file and how big it is.
    private fun probePathInfo(path: String): Map<String, Any?> {
        return try {
            val f = File(path)
            if (f.isFile) {
                mapOf(
                    "exists" to true,
                    "isFile" to true,
                    "canRead" to f.canRead(),
                    "length" to f.length(),
                )
            } else {
                mapOf("exists" to false, "isFile" to false)
            }
        } catch (e: Exception) {
            mapOf("exists" to false, "error" to e.message)
        }
    }

    /// Import a picked file from its content:// URI. First tries to resolve the
    /// real filesystem path via MediaStore, so conversion reads the original
    /// DCIM bytes (which keep the full EXIF GPS). OPPO's MediaProvider strips
    /// the GPS block from HEIC bytes served over a content stream, so copying
    /// bytes is only a fallback when no real path exists. Returns the path used.
    private fun importRawBytes(uriString: String, destPath: String): String? {
        // Try to resolve a real file path first (MediaStore _data). Reading the
        // original DCIM/Download file directly preserves EXIF GPS that the
        // content stream drops on OPPO. The picker hands us a document URI
        // (content://com.android.providers.media.documents/document/...), which
        // MediaStore can't query directly — convert it to a media URI
        // (content://media/external/file/<id>) first.
        val mediaId = extractMediaId(uriString)
        var displayName: String? = null
        try {
            val uri = Uri.parse(uriString)
            val nameProj = arrayOf(android.provider.OpenableColumns.DISPLAY_NAME)
            contentResolver.query(uri, nameProj, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val idx = c.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) displayName = c.getString(idx)
                }
            }
        } catch (_: Exception) {
        }
        if (mediaId != null) {
            try {
                val mediaUri = android.provider.MediaStore
                    .Files
                    .getContentUri("external")
                    .buildUpon()
                    .appendPath(mediaId)
                    .build()
                val projection = arrayOf(
                    android.provider.MediaStore.MediaColumns.DATA,
                    android.provider.MediaStore.MediaColumns.DISPLAY_NAME,
                )
                contentResolver.query(mediaUri, projection, null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        val dataIdx = c.getColumnIndex(android.provider.MediaStore.MediaColumns.DATA)
                        if (dataIdx >= 0) {
                            val realPath = c.getString(dataIdx)
                            if (realPath != null && realPath.isNotEmpty()) {
                                val f = File(realPath)
                                if (f.isFile && f.canRead() && f.length() > 0) {
                                    return realPath
                                }
                            }
                        }
                        val dnIdx = c.getColumnIndex(android.provider.MediaStore.MediaColumns.DISPLAY_NAME)
                        if (dnIdx >= 0) displayName = c.getString(dnIdx)
                    }
                }
            } catch (_: Exception) {
            }
        }

        // Second try: search the DCIM/Download trees for a file matching the
        // display name. MediaProvider gives us the name; if the original lives
        // in a standard camera/download location, reading that real path
        // preserves GPS.
        if (displayName != null && displayName!!.endsWith(".heic", true)) {
            val candidates = listOf(
                "/storage/emulated/0/DCIM/Camera/$displayName",
                "/storage/emulated/0/Pictures/$displayName",
                "/storage/emulated/0/Download/$displayName",
            )
            for (p in candidates) {
                try {
                    val f = File(p)
                    if (f.isFile && f.canRead() && f.length() > 0) {
                        return p
                    }
                } catch (_: Exception) {
                }
            }
        }

        // Fallback: copy raw bytes via openFileDescriptor (a direct fd to the
        // underlying file). OPPO's MediaProvider strips the EXIF GPS ASCII
        // fields when serving bytes through openInputStream, but the fd path
        // may preserve them.
        return try {
            val uri = Uri.parse(uriString)
            contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
                File(destPath).parentFile?.mkdirs()
                FileOutputStream(destPath).use { outs ->
                    java.io.FileInputStream(pfd.fileDescriptor).use { ins ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            val n = ins.read(buf)
                            if (n < 0) break
                            outs.write(buf, 0, n)
                        }
                    }
                }
            }
            destPath
        } catch (e: Exception) {
            null
        }
    }

    /// Extract the numeric media id from a document URI like
    /// content://com.android.providers.media.documents/document/document%3A1000058766
    /// (returns "1000058766"), or null if not a document URI.
    private fun extractMediaId(uriString: String): String? {
        val uri = Uri.parse(uriString)
        if (uri.authority != "com.android.providers.media.documents") return null
        val last = uri.lastPathSegment ?: return null
        val pct = last.lastIndexOf("%3A")
        if (pct >= 0) return last.substring(pct + 3)
        val colon = last.lastIndexOf(':')
        if (colon >= 0) return last.substring(colon + 1)
        return null
    }

    /// Decode the image at `path` (HEIC/JPEG/PNG) downscaled to fit
    /// `maxPixelSize` on the long edge, then encode as JPEG bytes. Returns null
    /// if the file cannot be decoded. Runs on a background thread.
    private fun renderThumbnailJpeg(path: String, maxPixelSize: Int): ByteArray? {
        val file = File(path)
        if (!file.isFile) return null
        return try {
            val bitmap: Bitmap = if (Build.VERSION.SDK_INT >= 28) {
                val source = ImageDecoder.createSource(file)
                ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                    decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                    val targetSize = downscale(info.size.width, info.size.height, maxPixelSize)
                    if (targetSize != null) {
                        decoder.setTargetSize(targetSize.first, targetSize.second)
                    }
                }
            } else {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                BitmapFactory.decodeFile(path, bounds)
                val sampleSize = computeInSampleSize(bounds.outWidth, bounds.outHeight, maxPixelSize)
                val opts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
                BitmapFactory.decodeFile(path, opts) ?: return null
            }
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 85, out)
            bitmap.recycle()
            out.toByteArray()
        } catch (e: Exception) {
            null
        }
    }

    private fun downscale(w: Int, h: Int, max: Int): Pair<Int, Int>? {
        if (w <= 0 || h <= 0) return null
        val longEdge = maxOf(w, h)
        if (longEdge <= max) return null
        val scale = max.toFloat() / longEdge
        return Pair((w * scale).toInt().coerceAtLeast(1), (h * scale).toInt().coerceAtLeast(1))
    }

    private fun computeInSampleSize(w: Int, h: Int, max: Int): Int {
        var sample = 1
        if (w <= 0 || h <= 0) return sample
        while (maxOf(w, h) / (sample * 2) >= max) {
            sample *= 2
        }
        return sample
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
