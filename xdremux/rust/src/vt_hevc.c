/* VideoToolbox HEVC still-picture encoder for the Rust core (hevc/vt.rs).
 *
 * Public C API of VideoToolbox / CoreMedia / CoreVideo only: no private
 * symbols, no dlopen/dlsym. One session encodes a batch of same-format
 * pictures; every picture is a forced keyframe and is returned synchronously
 * as an Annex-B stream that starts with the session's VPS/SPS/PPS.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <VideoToolbox/VideoToolbox.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Keep in sync with `VtConfig` in hevc/vt.rs. */
typedef struct {
    int32_t width;
    int32_t height;
    int32_t monochrome;     /* 1: 4:0:0, 0: 4:2:0 */
    int32_t bit_depth;      /* 8 or 10 */
    int32_t full_range;     /* sample range of the pixel buffer */
    int32_t primaries;      /* 0 unspecified, 1 BT.709, 2 EBU 3213 (bt470bg), 9 BT.2020 */
    int32_t transfer;       /* 0 unspecified, 1 BT.709, 2 sRGB */
    int32_t matrix;         /* 0 unspecified, 1 BT.709, 2 BT.601, 9 BT.2020 */
    int32_t force_software; /* 1: never use the hardware encoder */
    float quality;          /* kVTCompressionPropertyKey_Quality, 0..1 */
} xdremux_vt_config;

/* Failure stages reported through `stage` (see vt.rs for the wording). */
enum {
    VT_STAGE_ARGUMENT = 1,
    VT_STAGE_CREATE = 2,
    VT_STAGE_PROFILE = 3,
    VT_STAGE_PROPERTY = 4,
    VT_STAGE_PREPARE = 5,
    VT_STAGE_PIXEL_BUFFER = 6,
    VT_STAGE_ENCODE = 7,
    VT_STAGE_OUTPUT = 8,
};

typedef struct {
    VTCompressionSessionRef session;
    xdremux_vt_config config;
    OSType pixel_format;
    int64_t frame_index;
    /* Written by the output callback, read after CompleteFrames returns. */
    CMSampleBufferRef sample;
    OSStatus sample_status;
} vt_session;

static void vt_output(void *refcon, void *frame_refcon, OSStatus status,
                      VTEncodeInfoFlags flags, CMSampleBufferRef sample) {
    (void)frame_refcon;
    (void)flags;
    vt_session *s = (vt_session *)refcon;
    s->sample_status = status;
    if (status == noErr && sample != NULL) {
        if (s->sample != NULL) {
            CFRelease(s->sample);
        }
        s->sample = (CMSampleBufferRef)CFRetain(sample);
    }
}

static CFDictionaryRef vt_encoder_spec(int force_software, int allow_hardware) {
    /* Prefer the hardware encoder and let VideoToolbox fall back to the
     * software one; `force_software` (or a retry after a failed create)
     * turns hardware off. The key is public on macOS and, from 17.4, on iOS;
     * older iOS has no public way to choose and uses the system default. */
    CFBooleanRef enable = (force_software || !allow_hardware) ? kCFBooleanFalse : kCFBooleanTrue;
    if (__builtin_available(macOS 10.9, iOS 17.4, *)) {
        const void *keys[] = {kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder};
        const void *values[] = {enable};
        return CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                  &kCFTypeDictionaryValueCallBacks);
    }
    return NULL;
}

static OSStatus vt_set_number(VTCompressionSessionRef session, CFStringRef key, CFNumberType type,
                              const void *value) {
    CFNumberRef number = CFNumberCreate(NULL, type, value);
    OSStatus status = VTSessionSetProperty(session, key, number);
    CFRelease(number);
    return status;
}

void xdremux_vt_close(void *handle) {
    vt_session *s = (vt_session *)handle;
    if (s == NULL) {
        return;
    }
    if (s->session != NULL) {
        VTCompressionSessionInvalidate(s->session);
        CFRelease(s->session);
    }
    if (s->sample != NULL) {
        CFRelease(s->sample);
    }
    free(s);
}

/* Open a session. Returns NULL on failure with `*stage` / `*status` set.
 * `*using_hardware` reports the encoder VideoToolbox picked (-1 unknown). */
void *xdremux_vt_open(const xdremux_vt_config *config, int32_t *stage, int32_t *status,
                      int32_t *using_hardware) {
    *stage = 0;
    *status = 0;
    *using_hardware = -1;
    if (config == NULL || config->width <= 0 || config->height <= 0 ||
        (config->bit_depth != 8 && config->bit_depth != 10) ||
        (config->monochrome && config->bit_depth != 8)) {
        *stage = VT_STAGE_ARGUMENT;
        return NULL;
    }
    vt_session *s = (vt_session *)calloc(1, sizeof(vt_session));
    if (s == NULL) {
        *stage = VT_STAGE_ARGUMENT;
        return NULL;
    }
    s->config = *config;

    CFStringRef profile;
    if (config->monochrome) {
        profile = kVTProfileLevel_HEVC_Monochrome_AutoLevel;
        s->pixel_format = kCVPixelFormatType_OneComponent8;
    } else if (config->bit_depth == 10) {
        profile = kVTProfileLevel_HEVC_Main10_AutoLevel;
        s->pixel_format = config->full_range ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                                             : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    } else {
        profile = kVTProfileLevel_HEVC_Main_AutoLevel;
        s->pixel_format = config->full_range ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                             : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }

    OSStatus st = -1;
    for (int attempt = 0; attempt < 2 && s->session == NULL; attempt++) {
        /* Second attempt: hardware off, for hosts whose hardware encoder
         * refuses the session (virtual machines, exotic sizes). */
        if (attempt == 1 && config->force_software) {
            break;
        }
        CFDictionaryRef spec = vt_encoder_spec(config->force_software, attempt == 0);
        st = VTCompressionSessionCreate(NULL, config->width, config->height, kCMVideoCodecType_HEVC,
                                        spec, NULL, NULL, vt_output, s, &s->session);
        if (spec != NULL) {
            CFRelease(spec);
        }
        if (st != noErr) {
            s->session = NULL;
            continue;
        }
        st = VTSessionSetProperty(s->session, kVTCompressionPropertyKey_ProfileLevel, profile);
        if (st != noErr) {
            /* E.g. an encoder without this profile: drop it and retry. */
            VTCompressionSessionInvalidate(s->session);
            CFRelease(s->session);
            s->session = NULL;
            *stage = VT_STAGE_PROFILE;
        }
    }
    if (s->session == NULL) {
        if (*stage == 0) {
            *stage = VT_STAGE_CREATE;
        }
        *status = (int32_t)st;
        xdremux_vt_close(s);
        return NULL;
    }
    *stage = 0;

    VTSessionSetProperty(s->session, kVTCompressionPropertyKey_RealTime, kCFBooleanFalse);
    VTSessionSetProperty(s->session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    int32_t one = 1;
    st = vt_set_number(s->session, kVTCompressionPropertyKey_MaxKeyFrameInterval, kCFNumberSInt32Type, &one);
    if (st == noErr) {
        float quality = config->quality;
        st = vt_set_number(s->session, kVTCompressionPropertyKey_Quality, kCFNumberFloat32Type, &quality);
    }
    /* The VUI colour description comes from session properties; attachments
     * on the pixel buffer alone are not written to the stream. */
    if (st == noErr && config->primaries != 0) {
        CFStringRef primaries = kCVImageBufferColorPrimaries_ITU_R_709_2;
        if (config->primaries == 2) primaries = kCVImageBufferColorPrimaries_EBU_3213;
        if (config->primaries == 9) primaries = kCVImageBufferColorPrimaries_ITU_R_2020;
        st = VTSessionSetProperty(s->session, kVTCompressionPropertyKey_ColorPrimaries, primaries);
    }
    if (st == noErr && config->transfer != 0) {
        st = VTSessionSetProperty(s->session, kVTCompressionPropertyKey_TransferFunction,
                                  config->transfer == 2 ? kCVImageBufferTransferFunction_sRGB
                                                        : kCVImageBufferTransferFunction_ITU_R_709_2);
    }
    if (st == noErr && config->matrix != 0) {
        CFStringRef matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2;
        if (config->matrix == 2) matrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4;
        if (config->matrix == 9) matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020;
        st = VTSessionSetProperty(s->session, kVTCompressionPropertyKey_YCbCrMatrix, matrix);
    }
    if (st != noErr) {
        *stage = VT_STAGE_PROPERTY;
        *status = (int32_t)st;
        xdremux_vt_close(s);
        return NULL;
    }
    st = VTCompressionSessionPrepareToEncodeFrames(s->session);
    if (st != noErr) {
        *stage = VT_STAGE_PREPARE;
        *status = (int32_t)st;
        xdremux_vt_close(s);
        return NULL;
    }

    /* Readable on macOS and, from 17.4, on iOS; left at -1 elsewhere. */
    if (__builtin_available(macOS 10.9, iOS 17.4, *)) {
        CFTypeRef hardware = NULL;
        if (VTSessionCopyProperty(s->session, kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                  NULL, &hardware) == noErr && hardware != NULL) {
            *using_hardware = CFBooleanGetValue((CFBooleanRef)hardware) ? 1 : 0;
            CFRelease(hardware);
        }
    }
    return s;
}

static void vt_copy_plane8(CVPixelBufferRef buffer, size_t plane, int planar, const uint8_t *src,
                           size_t width, size_t height) {
    uint8_t *dst = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, plane)
                          : CVPixelBufferGetBaseAddress(buffer);
    size_t stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                           : CVPixelBufferGetBytesPerRow(buffer);
    for (size_t y = 0; y < height; y++) {
        memcpy(dst + y * stride, src + y * width, width);
    }
}

static CVPixelBufferRef vt_make_buffer(const vt_session *s, const void *p0, const void *p1,
                                       const void *p2) {
    const size_t width = (size_t)s->config.width, height = (size_t)s->config.height;
    const size_t cw = (width + 1) / 2, ch = (height + 1) / 2;
    const void *keys[] = {kCVPixelBufferIOSurfacePropertiesKey};
    CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    const void *values[] = {empty};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CVPixelBufferRef buffer = NULL;
    CVReturn cr = CVPixelBufferCreate(NULL, width, height, s->pixel_format, attrs, &buffer);
    CFRelease(attrs);
    CFRelease(empty);
    if (cr != kCVReturnSuccess || buffer == NULL) {
        return NULL;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    if (s->config.monochrome) {
        vt_copy_plane8(buffer, 0, CVPixelBufferIsPlanar(buffer), (const uint8_t *)p0, width, height);
    } else if (s->config.bit_depth == 8) {
        vt_copy_plane8(buffer, 0, 1, (const uint8_t *)p0, width, height);
        const uint8_t *u = (const uint8_t *)p1, *v = (const uint8_t *)p2;
        uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
        for (size_t y = 0; y < ch; y++) {
            uint8_t *row = dst + y * stride;
            for (size_t x = 0; x < cw; x++) {
                row[2 * x] = u[y * cw + x];
                row[2 * x + 1] = v[y * cw + x];
            }
        }
    } else {
        /* 10 significant bits per sample, stored MSB-aligned in 16 bits. */
        const uint16_t *luma = (const uint16_t *)p0, *u = (const uint16_t *)p1,
                       *v = (const uint16_t *)p2;
        uint8_t *dst = CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
        for (size_t y = 0; y < height; y++) {
            uint16_t *row = (uint16_t *)(dst + y * stride);
            for (size_t x = 0; x < width; x++) {
                row[x] = (uint16_t)(luma[y * width + x] << 6);
            }
        }
        dst = CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
        stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
        for (size_t y = 0; y < ch; y++) {
            uint16_t *row = (uint16_t *)(dst + y * stride);
            for (size_t x = 0; x < cw; x++) {
                row[2 * x] = (uint16_t)(u[y * cw + x] << 6);
                row[2 * x + 1] = (uint16_t)(v[y * cw + x] << 6);
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return buffer;
}

static int vt_append(uint8_t **out, size_t *len, size_t *cap, const uint8_t *data, size_t size) {
    static const uint8_t start_code[4] = {0, 0, 0, 1};
    if (*len + size + 4 > *cap) {
        size_t grown = (*cap + size + 4) * 2;
        uint8_t *next = (uint8_t *)realloc(*out, grown);
        if (next == NULL) {
            return 0;
        }
        *out = next;
        *cap = grown;
    }
    memcpy(*out + *len, start_code, 4);
    memcpy(*out + *len + 4, data, size);
    *len += size + 4;
    return 1;
}

/* Encode one picture. Planes: monochrome uses p0 only (8-bit, width*height);
 * 4:2:0 8-bit takes Y, U, V as uint8 (chroma (w+1)/2 x (h+1)/2); 10-bit takes
 * the same three planes as uint16 holding 0..1023.
 * On success returns 0 and a malloc'd Annex-B stream (free with
 * xdremux_vt_free): VPS/SPS/PPS first (`*parameter_len` bytes including
 * start codes), then the picture's slice NALs. Non-VCL NALs in the sample
 * (SEI, AUD) are not copied. */
int32_t xdremux_vt_encode(void *handle, const void *p0, const void *p1, const void *p2,
                          uint8_t **out, size_t *out_len, size_t *parameter_len,
                          int32_t *status) {
    vt_session *s = (vt_session *)handle;
    *out = NULL;
    *out_len = 0;
    *parameter_len = 0;
    *status = 0;
    if (s == NULL || p0 == NULL || (!s->config.monochrome && (p1 == NULL || p2 == NULL))) {
        return VT_STAGE_ARGUMENT;
    }
    CVPixelBufferRef buffer = vt_make_buffer(s, p0, p1, p2);
    if (buffer == NULL) {
        return VT_STAGE_PIXEL_BUFFER;
    }
    if (s->sample != NULL) {
        CFRelease(s->sample);
        s->sample = NULL;
    }
    s->sample_status = -1;

    const void *keys[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
    const void *values[] = {kCFBooleanTrue};
    CFDictionaryRef frame_props = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                                     &kCFTypeDictionaryValueCallBacks);
    CMTime pts = CMTimeMake(s->frame_index++, 1);
    OSStatus st = VTCompressionSessionEncodeFrame(s->session, buffer, pts, CMTimeMake(1, 1), frame_props,
                                                  NULL, NULL);
    CFRelease(frame_props);
    CFRelease(buffer);
    if (st == noErr) {
        /* Blocks until the output callback has run for this frame. */
        st = VTCompressionSessionCompleteFrames(s->session, kCMTimeInvalid);
    }
    if (st == noErr) {
        st = s->sample_status;
    }
    if (st != noErr || s->sample == NULL) {
        *status = (int32_t)st;
        return VT_STAGE_ENCODE;
    }

    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(s->sample);
    CMBlockBufferRef block = CMSampleBufferGetDataBuffer(s->sample);
    if (format == NULL || block == NULL) {
        return VT_STAGE_OUTPUT;
    }
    uint8_t *stream = NULL;
    size_t len = 0, cap = 0;
    size_t set_count = 0;
    int nal_length_size = 4;
    st = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, 0, NULL, NULL, &set_count,
                                                            &nal_length_size);
    int ok = st == noErr && set_count > 0 && nal_length_size >= 1 && nal_length_size <= 4;
    for (size_t i = 0; ok && i < set_count; i++) {
        const uint8_t *set = NULL;
        size_t set_size = 0;
        st = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, i, &set, &set_size, NULL, NULL);
        ok = st == noErr && set != NULL && vt_append(&stream, &len, &cap, set, set_size);
    }
    const size_t params = len;

    size_t total = CMBlockBufferGetDataLength(block);
    uint8_t *data = ok && total > 0 ? (uint8_t *)malloc(total) : NULL;
    ok = ok && data != NULL && CMBlockBufferCopyDataBytes(block, 0, total, data) == kCMBlockBufferNoErr;
    size_t cursor = 0, pictures = 0;
    while (ok && cursor + (size_t)nal_length_size < total) {
        size_t nal_size = 0;
        for (int i = 0; i < nal_length_size; i++) {
            nal_size = (nal_size << 8) | data[cursor + (size_t)i];
        }
        cursor += (size_t)nal_length_size;
        if (nal_size == 0 || cursor + nal_size > total) {
            ok = 0;
            break;
        }
        int nal_type = (data[cursor] >> 1) & 0x3f;
        if (nal_type < 32) { /* VCL only */
            ok = vt_append(&stream, &len, &cap, data + cursor, nal_size);
            pictures++;
        }
        cursor += nal_size;
    }
    free(data);
    CFRelease(s->sample);
    s->sample = NULL;
    if (!ok || pictures == 0) {
        free(stream);
        *status = (int32_t)st;
        return VT_STAGE_OUTPUT;
    }
    *out = stream;
    *out_len = len;
    *parameter_len = params;
    return 0;
}

void xdremux_vt_free(uint8_t *stream) {
    free(stream);
}
