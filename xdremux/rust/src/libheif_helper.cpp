// Bounded SDR RGB decode only. Never re-encode or rewrite source metadata.
#include <libheif/heif.h>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <mutex>

#if !LIBHEIF_HAVE_VERSION(1, 23, 4)
#error libheif-decoder requires libheif >= 1.23.4
#endif

namespace {
constexpr uint64_t max_pixels = 64ull * 1024 * 1024;
constexpr size_t max_input = 256ull * 1024 * 1024;
std::mutex decoder_mutex;
using Clock = std::chrono::steady_clock;
int cancelled(void* data) { return Clock::now() > *static_cast<Clock::time_point*>(data); }
void error_text(char* out, size_t len, const char* message) {
    if (out && len) std::snprintf(out, len, "%s", message ? message : "libheif error");
}
struct Init {
    heif_error status = heif_init(nullptr);
    ~Init() { if (status.code == heif_error_Ok) heif_deinit(); }
};
}

extern "C" int xdremux_heif_decode_rgb(const uint8_t* input, size_t input_len,
    uint8_t** output, size_t* output_len, uint32_t* width, uint32_t* height,
    char* error, size_t error_len) noexcept {
    if (!output || !output_len || !width || !height) return 0;
    *output = nullptr; *output_len = 0; *width = 0; *height = 0;
    try {
        if (!input || !input_len || input_len > max_input) {
            error_text(error, error_len, "HEIF input exceeds native decode limit"); return 0;
        }
        // Serialize rare fallbacks: balances init/deinit and bounds concurrent
        // native memory. The normal Rust decode path remains parallel.
        std::lock_guard<std::mutex> lock(decoder_mutex);
        Init init;
        if (init.status.code != heif_error_Ok) { error_text(error, error_len, init.status.message); return 0; }
        if (heif_get_version_number() < LIBHEIF_MAKE_VERSION(1, 23, 4)) {
            error_text(error, error_len, "libheif runtime version is too old"); return 0;
        }
        std::unique_ptr<heif_context, decltype(&heif_context_free)> ctx(heif_context_alloc(), heif_context_free);
        if (!ctx) { error_text(error, error_len, "cannot allocate libheif context"); return 0; }
        auto limits = heif_context_get_security_limits(ctx.get());
        limits->max_image_size_pixels = max_pixels;
        limits->max_memory_block_size = 256ull * 1024 * 1024;
        limits->max_total_memory = 512ull * 1024 * 1024;
        limits->max_number_of_tiles = 4096;
        auto status = heif_context_read_from_memory_without_copy(ctx.get(), input, input_len, nullptr);
        if (status.code != heif_error_Ok) { error_text(error, error_len, status.message); return 0; }
        heif_image_handle* raw_handle = nullptr;
        status = heif_context_get_primary_image_handle(ctx.get(), &raw_handle);
        std::unique_ptr<heif_image_handle, decltype(&heif_image_handle_release)> handle(raw_handle, heif_image_handle_release);
        if (status.code != heif_error_Ok || !handle) { error_text(error, error_len, status.message); return 0; }
        // This entry is an SDR fallback, not an HDR tone mapper.
        heif_color_profile_nclx* raw_profile = nullptr;
        heif_image_handle_get_nclx_color_profile(handle.get(), &raw_profile);
        std::unique_ptr<heif_color_profile_nclx, decltype(&heif_nclx_color_profile_free)> profile(raw_profile, heif_nclx_color_profile_free);
        if (profile && (profile->transfer_characteristics == 16 || profile->transfer_characteristics == 18)) {
            error_text(error, error_len, "PQ/HLG HEIF needs HDR-aware decoding, not SDR fallback"); return 0;
        }
        std::unique_ptr<heif_decoding_options, decltype(&heif_decoding_options_free)> options(heif_decoding_options_alloc(), heif_decoding_options_free);
        if (!options) { error_text(error, error_len, "cannot allocate decoding options"); return 0; }
        auto deadline = Clock::now() + std::chrono::seconds(30);
        options->strict_decoding = 1;
        options->convert_hdr_to_8bit = 1;
        options->ignore_transformations = 0;
        options->num_codec_threads = 4;
        options->cancel_decoding = cancelled;
        options->progress_user_data = &deadline;
        // Default requested output NCLX is sRGB in the pinned libheif API.
        heif_image* raw_image = nullptr;
        status = heif_decode_image(handle.get(), &raw_image, heif_colorspace_RGB, heif_chroma_interleaved_RGB, options.get());
        std::unique_ptr<heif_image, decltype(&heif_image_release)> image(raw_image, heif_image_release);
        if (status.code != heif_error_Ok || !image) { error_text(error, error_len, status.message); return 0; }
        int w = heif_image_get_width(image.get(), heif_channel_interleaved);
        int h = heif_image_get_height(image.get(), heif_channel_interleaved);
        if (w <= 0 || h <= 0 || uint64_t(w) * uint64_t(h) > max_pixels) {
            error_text(error, error_len, "invalid or oversized native HEIF raster"); return 0;
        }
        int stride = 0;
        const auto plane = heif_image_get_plane_readonly(image.get(), heif_channel_interleaved, &stride);
        const size_t row = size_t(w) * 3;
        if (!plane || stride <= 0 || size_t(stride) < row) {
            error_text(error, error_len, "invalid native HEIF pixel stride"); return 0;
        }
        size_t length = row * size_t(h);
        std::unique_ptr<uint8_t, decltype(&std::free)> packed(static_cast<uint8_t*>(std::malloc(length)), std::free);
        if (!packed) { error_text(error, error_len, "cannot allocate native HEIF pixels"); return 0; }
        for (int y = 0; y < h; ++y) std::memcpy(packed.get() + size_t(y) * row, plane + size_t(y) * size_t(stride), row);
        *output = packed.release(); *output_len = length; *width = uint32_t(w); *height = uint32_t(h);
        return 1;
    } catch (const std::exception& e) { error_text(error, error_len, e.what()); }
    catch (...) { error_text(error, error_len, "native HEIF decoder exception"); }
    return 0;
}

extern "C" void xdremux_heif_free_rgb(uint8_t* pixels) noexcept { std::free(pixels); }
