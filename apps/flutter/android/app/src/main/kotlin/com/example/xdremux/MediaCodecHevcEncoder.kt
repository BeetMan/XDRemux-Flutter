package com.example.xdremux

import android.media.Image
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import java.io.ByteArrayOutputStream

/**
 * Hardware HEVC encoding for gain-map tiles via MediaCodec.
 *
 * The Rust core tiles each gain map into 512×512 YUV420 (I420) buffers and
 * hands them to Dart; Dart funnels each buffer here, and we encode a single
 * frame to an Annex-B HEVC byte stream (VPS/SPS/PPS + IDR) that is handed
 * back to Rust for ISOBMFF assembly. Any failure returns null so the caller
 * can fall back to the x265 software path.
 */
object MediaCodecHevcEncoder {

    private const val TAG = "XdRemuxHW"
    private const val MIME = MediaFormat.MIMETYPE_VIDEO_HEVC

    /**
     * Encode one I420 frame of `width`×`height` into an Annex-B HEVC stream.
     * `yuv` layout: Y (width*height), then U ((w/2)*(h/2)), then V.
     * Returns null on any error.
     */
    fun encodeTile(yuv: ByteArray, width: Int, height: Int): ByteArray? {
        val ySize = width * height
        val cSize = (width / 2) * (height / 2)
        val frameSize = ySize + 2 * cSize
        if (yuv.size < frameSize) {
            Log.e(TAG, "YUV buffer too small: ${yuv.size} < $frameSize")
            return null
        }
        var codec: MediaCodec? = null
        try {
            val format = MediaFormat.createVideoFormat(MIME, width, height)
            format.setInteger(
                MediaFormat.KEY_COLOR_FORMAT,
                MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible,
            )
            format.setInteger(MediaFormat.KEY_BIT_RATE, 1_500_000)
            format.setInteger(MediaFormat.KEY_FRAME_RATE, 1)
            format.setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            // 8-bit Main profile; without this some encoders pick Main10 and
            // produce a 10-bit SPS that breaks hvcC extraction.
            format.setInteger(
                MediaFormat.KEY_PROFILE,
                MediaCodecInfo.CodecProfileLevel.HEVCProfileMain,
            )
            // Match the x265 full-range encoding so decoded gain values are
            // identical. Honors only on API 29+; older devices fall back.
            if (Build.VERSION.SDK_INT >= 29) {
                format.setInteger(MediaFormat.KEY_COLOR_RANGE, MediaFormat.COLOR_RANGE_FULL)
            }

            codec = MediaCodec.createEncoderByType(MIME)
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()

            // 1. Queue the single frame.
            val inIdx = codec.dequeueInputBuffer(10_000)
            if (inIdx < 0) {
                Log.e(TAG, "dequeueInputBuffer timed out")
                return null
            }
            val image = codec.getInputImage(inIdx)
            if (image != null) {
                copyIntoImage(yuv, width, height, ySize, cSize, image)
            } else {
                // Fallback: write a packed planar buffer directly.
                val buf = codec.getInputBuffer(inIdx)
                    ?: throw RuntimeException("no input buffer")
                writePacked(buf, yuv, frameSize)
            }
            codec.queueInputBuffer(inIdx, 0, frameSize, 0L, 0)

            // 2. Signal end of stream.
            val eosIdx = codec.dequeueInputBuffer(10_000)
            if (eosIdx >= 0) {
                codec.queueInputBuffer(eosIdx, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
            }

            // 3. Drain output (codec config NALs + frame NALs).
            val out = ByteArrayOutputStream()
            val info = MediaCodec.BufferInfo()
            var attempts = 0
            while (attempts < 200) {
                val outIdx = codec.dequeueOutputBuffer(info, 10_000)
                when {
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        attempts++
                        continue
                    }
                    outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> {
                        attempts++
                        if (attempts > 100) {
                            Log.e(TAG, "encoder stalled waiting for output")
                            break
                        }
                        continue
                    }
                    outIdx < 0 -> {
                        attempts++
                        continue
                    }
                }
                attempts = 0 // real output — keep waiting for EOS
                val buf = codec.getOutputBuffer(outIdx)
                if (buf != null && info.size > 0) {
                    buf.position(info.offset)
                    buf.limit(info.offset + info.size)
                    val chunk = ByteArray(info.size)
                    buf.get(chunk)
                    out.write(chunk)
                }
                val eos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                codec.releaseOutputBuffer(outIdx, false)
                if (eos) break
            }

            val result = out.toByteArray()
            if (result.isEmpty()) {
                Log.e(TAG, "encoder produced no output")
                return null
            }
            Log.i(TAG, "encoded ${width}x$height -> ${result.size} bytes")
            return result
        } catch (e: Exception) {
            Log.e(TAG, "encodeTile failed: ${e.message}", e)
            return null
        } finally {
            try {
                codec?.stop()
            } catch (_: Exception) {
            }
            try {
                codec?.release()
            } catch (_: Exception) {
            }
        }
    }

    private fun writePacked(buf: java.nio.ByteBuffer, yuv: ByteArray, frameSize: Int) {
        buf.clear()
        buf.put(yuv, 0, frameSize)
    }

    /** Copy the packed I420 frame into the MediaCodec input Image planes,
     *  honoring per-plane row/pixel strides (handles planar and semi-planar). */
    private fun copyIntoImage(
        yuv: ByteArray,
        width: Int,
        height: Int,
        ySize: Int,
        cSize: Int,
        image: Image,
    ) {
        val planes = image.planes
        copyPlane(planes[0], yuv, 0, width, height)
        copyChroma(planes, yuv, ySize, cSize)
    }

    /**
     * Copy the packed I420 chroma (U then V) into the encoder's chroma
     * planes. Handles both planar (pixelStride == 1, separate buffers) and
     * semi-planar NV12 (pixelStride == 2, one shared interleaved buffer).
     * For the shared case both U and V are written through the first chroma
     * plane's buffer (even/odd offsets) — some drivers report a V-plane view
     * whose limit is one byte short, which would silently drop V data if we
     * wrote through it.
     */
    private fun copyChroma(
        planes: Array<Image.Plane>,
        yuv: ByteArray,
        ySize: Int,
        cSize: Int,
    ) {
        val pu = planes[1]
        val pv = planes[2]
        // columns per chroma row derived from rowStride: NV12 row is 2x columns
        val chromaCols = pu.rowStride / 2
        val chromaRows = cSize / chromaCols
        val ps = pu.pixelStride
        val bufU = pu.buffer
        val bufV = pv.buffer

        if (ps == 1) {
            // Planar: separate buffers, each chromaCols × chromaRows
            copyPlane(pu, yuv, ySize, chromaCols, chromaRows)
            copyPlane(pv, yuv, ySize + cSize, chromaCols, chromaRows)
            return
        }

        // Semi-planar NV12: one shared buffer; write U at even, V at odd.
        val shared = bufU
        val limit = shared.limit()
        // rowStride for NV12 = 2 * chromaCols bytes (interleaved U/V per row)
        var rowStride = pu.rowStride
        for (row in 0 until chromaRows) {
            var srcU = ySize + row * chromaCols
            var srcV = ySize + cSize + row * chromaCols
            var dst = row * rowStride
            for (col in 0 until chromaCols) {
                if (dst + 1 >= limit) break
                shared.put(dst, yuv[srcU])       // U at even offset
                shared.put(dst + 1, yuv[srcV])   // V at odd offset
                dst += 2
                srcU += 1
                srcV += 1
            }
            if (dst + 1 >= limit) break
        }
    }

    /**
     * Copy a packed source plane into a MediaCodec input plane, honoring the
     * plane's rowStride and pixelStride (handles planar chroma with row
     * padding). Semi-planar NV12 chroma is written by [copyChroma] instead,
     * because some drivers expose a V-plane view whose limit is one byte short
     * and would silently drop V data.
     */
    private fun copyPlane(
        plane: Image.Plane,
        yuv: ByteArray,
        srcOffset: Int,
        planeWidth: Int,
        planeHeight: Int,
    ) {
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val buf = plane.buffer
        val limit = buf.limit()

        if (rowStride == planeWidth && pixelStride == 1) {
            val total = planeWidth * planeHeight
            if (total <= limit) {
                buf.clear()
                buf.put(yuv, srcOffset, total)
                return
            }
            // Fall back to row-wise writes when the fast path overflows.
            for (row in 0 until planeHeight) {
                val src = srcOffset + row * planeWidth
                val dst = row * rowStride
                if (dst + planeWidth > limit) break
                buf.clear()
                buf.position(dst)
                buf.put(yuv, src, planeWidth)
            }
            return
        }

        for (row in 0 until planeHeight) {
            var src = srcOffset + row * planeWidth
            var dst = row * rowStride
            for (col in 0 until planeWidth) {
                if (dst >= limit) break
                buf.put(dst, yuv[src])
                dst += pixelStride
                src += 1
            }
            if (dst >= limit) break
        }
    }
}
