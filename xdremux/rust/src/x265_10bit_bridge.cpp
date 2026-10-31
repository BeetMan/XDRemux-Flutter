// 10-bit (Main10) x265 bridge.
//
// The port links two x265 static libraries: the existing 8-bit one
// (EXPORT_C_API=ON, provides the global C API) and a 10-bit one built with
// EXPORT_C_API=OFF (all symbols live in `namespace x265_10bit`). The 10-bit
// encoder is reachable only through `x265_10bit::x265_api_get(0)` and the
// `x265_api` function table, so this bridge is C++ and exposes a plain C ABI
// to the Rust core.
//
// Contract (verified in docs/research/x265-main10-feasibility-20261025.md):
//   * planes are uint16_t 4:2:0 samples in [0, 1023];
//   * one picture is encoded, but `totalFrames` is declared as 2: with
//     totalFrames == 1 x265 sets one-picture-only and signals Main10 Intra
//     (Rext, profile_idc 4), which hardware decoders generally lack;
//   * the returned buffer is Annex-B (x265 NAL payloads already carry the
//     start code) and must be released with xdremux_free_stream().

#include "x265.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>

namespace x265_10bit {
const x265_api* x265_api_get(int bitDepth);
}

namespace {

bool append_nal(unsigned char** buffer, size_t* length, size_t* capacity,
                const x265_nal& nal) {
    if (nal.sizeBytes == 0 || nal.payload == nullptr) {
        return true;
    }
    size_t needed = *length + nal.sizeBytes;
    if (needed > *capacity) {
        size_t grown = *capacity ? *capacity : 4096;
        while (grown < needed) {
            grown *= 2;
        }
        unsigned char* resized =
            static_cast<unsigned char*>(std::realloc(*buffer, grown));
        if (!resized) {
            return false;
        }
        *buffer = resized;
        *capacity = grown;
    }
    std::memcpy(*buffer + *length, nal.payload, nal.sizeBytes);
    *length += nal.sizeBytes;
    return true;
}

}  // namespace

extern "C" {

int xdremux_10bit_available(void) { return 1; }

// Encode one 10-bit 4:2:0 picture. `p1`/`p2` are half-resolution chroma planes.
// Returns 0 on success and stores a malloc'd Annex-B stream in `out`/`out_len`.
int xdremux_encode_10bit_planes(const uint16_t* p0, const uint16_t* p1,
                               const uint16_t* p2, int width, int height,
                               unsigned char** out, int* out_len) {
    if (!p0 || !p1 || !p2 || !out || !out_len || width <= 0 || height <= 0) {
        return -1;
    }
    *out = nullptr;
    *out_len = 0;

    const x265_api* api = x265_10bit::x265_api_get(0);
    if (!api || api->bit_depth != 10) {
        return -2;
    }

    x265_param* param = api->param_alloc();
    if (!param) {
        return -3;
    }
    if (api->param_default_preset(param, "fast", nullptr) != 0) {
        api->param_free(param);
        return -4;
    }
    api->param_parse(param, "log-level", "error");
    api->param_parse(param, "keyint", "250");
    api->param_parse(param, "bframes", "0");
    api->param_parse(param, "crf", "14");
    api->param_parse(param, "internal-csp", "i420");
    param->sourceWidth = width;
    param->sourceHeight = height;
    param->internalBitDepth = 10;
    param->internalCsp = X265_CSP_I420;
    // Two declared frames so the single picture is signalled as Main10
    // (profile_idc 2) instead of Main10 Intra / Rext (profile_idc 4).
    param->totalFrames = 2;
    if (param->fpsNum == 0 || param->fpsDenom == 0) {
        param->fpsNum = 30;
        param->fpsDenom = 1;
    }
    api->param_apply_profile(param, "main10");

    x265_encoder* encoder = api->encoder_open(param);
    if (!encoder) {
        api->param_free(param);
        return -5;
    }
    x265_picture* picture = api->picture_alloc();
    if (!picture) {
        api->encoder_close(encoder);
        api->param_free(param);
        return -6;
    }
    api->picture_init(param, picture);
    picture->planes[0] = const_cast<uint16_t*>(p0);
    picture->planes[1] = const_cast<uint16_t*>(p1);
    picture->planes[2] = const_cast<uint16_t*>(p2);
    // x265 strides are in bytes; 10-bit samples are 16-bit words. A sample
    // count here makes every row read half a row (two squeezed copies).
    const int chroma_width = (width + 1) / 2;
    picture->stride[0] = width * static_cast<int>(sizeof(uint16_t));
    picture->stride[1] = chroma_width * static_cast<int>(sizeof(uint16_t));
    picture->stride[2] = chroma_width * static_cast<int>(sizeof(uint16_t));

    unsigned char* buffer = nullptr;
    size_t length = 0;
    size_t capacity = 0;
    int status = 0;

    // Parameter sets first (VPS/SPS/PPS), then the single picture, then flush.
    x265_nal* nals = nullptr;
    uint32_t nal_count = 0;
    if (api->encoder_headers(encoder, &nals, &nal_count) < 0) {
        status = -7;
    }
    for (uint32_t i = 0; status == 0 && i < nal_count; ++i) {
        if (!append_nal(&buffer, &length, &capacity, nals[i])) {
            status = -8;
        }
    }
    if (status == 0) {
        int encoded = api->encoder_encode(encoder, &nals, &nal_count, picture, nullptr);
        if (encoded < 0) {
            status = -9;
        }
        for (uint32_t i = 0; status == 0 && i < nal_count; ++i) {
            if (!append_nal(&buffer, &length, &capacity, nals[i])) {
                status = -8;
            }
        }
    }
    for (int flush = 0; status == 0 && flush < 4; ++flush) {
        int encoded = api->encoder_encode(encoder, &nals, &nal_count, nullptr, nullptr);
        if (encoded < 0) {
            status = -9;
            break;
        }
        if (encoded == 0 && nal_count == 0) {
            break;
        }
        for (uint32_t i = 0; i < nal_count; ++i) {
            if (!append_nal(&buffer, &length, &capacity, nals[i])) {
                status = -8;
                break;
            }
        }
    }

    api->picture_free(picture);
    api->encoder_close(encoder);
    api->param_free(param);
    api->cleanup();

    if (status != 0 || buffer == nullptr || length == 0) {
        std::free(buffer);
        return status != 0 ? status : -10;
    }
    if (length > 0x7fffffff) {
        std::free(buffer);
        return -11;
    }
    *out = buffer;
    *out_len = static_cast<int>(length);
    return 0;
}

void xdremux_free_stream(unsigned char* buffer) { std::free(buffer); }

}  // extern "C"
