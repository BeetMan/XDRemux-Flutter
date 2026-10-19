package com.example.xdremux

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** One-shot SAF export of a leased private inbox file. Payload never enters Dart. */
class TransferDocuments(private val activity: Activity) {
    private val requestCode = 0x5844
    private var picker: MethodChannel.Result? = null
    private var selected: Uri? = null
    private val writing = AtomicBoolean(false)
    private val executor = Executors.newSingleThreadExecutor()

    fun configure(channel: MethodChannel) {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "createDocument" -> {
                    val name = call.argument<String>("name")
                    if (name.isNullOrBlank() || name.length > 240 || name.contains('/') || name.contains('\\')) {
                        result.error("invalid_input", "Invalid file name", null)
                    } else if (picker != null || writing.get()) {
                        result.error("busy", "Export is busy", null)
                    } else {
                        picker = result
                        try {
                            activity.startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                val extension = name.substringAfterLast('.', "").lowercase(java.util.Locale.ROOT)
                                type = when (extension) {
                                    "mov" -> "video/quicktime"
                                    "heic" -> "image/heic"
                                    "heif" -> "image/heif"
                                    else -> MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
                                        ?: "application/octet-stream"
                                }
                                putExtra(Intent.EXTRA_TITLE, name)
                            }, requestCode)
                        } catch (_: Exception) {
                            picker = null; result.error("io", "Unable to open document picker", null)
                        }
                    }
                }
                "writeDocument" -> {
                    val uri = call.argument<String>("uri")
                    val path = call.argument<String>("path")
                    val size = call.argument<Number>("size")?.toLong()
                    val expected = call.argument<String>("sha256")
                    val target = selected
                    if (target == null || uri != target.toString() || path == null || size == null || size < 0 ||
                        expected == null || !Regex("[0-9a-fA-F]{64}").matches(expected)) {
                        result.error("invalid_input", "Invalid export request", null)
                    } else if (!writing.compareAndSet(false, true)) {
                        result.error("busy", "Export is busy", null)
                    } else {
                        selected = null
                        executor.execute {
                            val ok = try {
                                val file = File(path).canonicalFile
                                val inbox = File(activity.filesDir, "transfer/received").canonicalFile
                                require(file.path.startsWith(inbox.path + File.separator) && file.name == "data" &&
                                    Regex("file-[0-9a-f-]{36}").matches(file.parentFile!!.name) && file.length() == size)
                                val digest = MessageDigest.getInstance("SHA-256")
                                var written = 0L
                                file.inputStream().use { input ->
                                    activity.contentResolver.openOutputStream(target, "wt")!!.use { output ->
                                        val buffer = ByteArray(64 * 1024)
                                        while (true) {
                                            val n = input.read(buffer); if (n < 0) break
                                            written += n; require(written <= size)
                                            digest.update(buffer, 0, n); output.write(buffer, 0, n)
                                        }
                                        output.flush()
                                    }
                                }
                                require(written == size && hex(digest.digest()).equals(expected, true))
                                // Verify what the document provider returns, separately from the input read.
                                val verify = MessageDigest.getInstance("SHA-256"); var read = 0L
                                activity.contentResolver.openInputStream(target)!!.use { input ->
                                    val buffer = ByteArray(64 * 1024)
                                    while (true) {
                                        val n = input.read(buffer); if (n < 0) break
                                        read += n; require(read <= size); verify.update(buffer, 0, n)
                                    }
                                }
                                read == size && hex(verify.digest()).equals(expected, true)
                            } catch (_: Exception) { false }
                            writing.set(false)
                            activity.runOnUiThread { result.success(ok) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
    private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    fun onActivityResult(code: Int, result: Int, data: Intent?): Boolean {
        if (code != requestCode) return false
        selected = if (result == Activity.RESULT_OK) data?.data else null
        picker?.success(selected?.toString()); picker = null
        return true
    }
    fun close() { picker?.success(null); picker = null; executor.shutdown() }
}
