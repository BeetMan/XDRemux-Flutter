#include "napi/native_api.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <exception>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <string>

// Keep this declaration byte-for-byte compatible with xdremux/rust/src/lib.rs.
// The Rust result owns all six string pointers until the by-value free function
// is called. Do not change this to a pointer-to-struct ABI.
extern "C" {
struct XdremuxClassificationResult {
    char *mode_key;
    char *folder_name;
    char *status;
    char *raw_user_comment;
    bool has_tag_flags;
    std::uint64_t tag_flags;
    std::uint64_t unknown_flags;
    char *hdr_kind;
    char *family;
};

struct XdremuxConversionResult {
    bool success;
    char *mode;
    char *family;
    double edr_scale;
    double gain_map_max;
    char *error_message;
};

struct XdremuxConvertConfig {
    std::uint8_t oppo_compat;
    std::uint8_t oppo_camera_tail;
    std::uint8_t strict_tmap;
    std::uint8_t apple_photographic_styles;
    std::uint8_t apple_portrait;
};

char *xdremux_version();
void xdremux_free_string(char *value);
XdremuxClassificationResult xdremux_classify(const char *input_path);
void xdremux_free_classification_result(XdremuxClassificationResult result);
char *xdremux_inspect_photo_details(const char *input_path);
XdremuxConversionResult xdremux_convert_with_progress(
    const char *input_path,
    const char *output_path,
    const XdremuxConvertConfig *config,
    std::uint32_t handle);
std::uint32_t xdremux_progress_begin();
void xdremux_progress_end(std::uint32_t handle);
void xdremux_read_progress_for(std::uint32_t handle, std::uint32_t *buf);
void xdremux_free_result(XdremuxConversionResult result);
}

static_assert(sizeof(bool) == 1, "Rust bool ABI must be one byte on OHOS");
static_assert(offsetof(XdremuxClassificationResult, mode_key) == 0);
static_assert(offsetof(XdremuxClassificationResult, folder_name) == 8);
static_assert(offsetof(XdremuxClassificationResult, status) == 16);
static_assert(offsetof(XdremuxClassificationResult, raw_user_comment) == 24);
static_assert(offsetof(XdremuxClassificationResult, has_tag_flags) == 32);
static_assert(offsetof(XdremuxClassificationResult, tag_flags) == 40);
static_assert(offsetof(XdremuxClassificationResult, unknown_flags) == 48);
static_assert(offsetof(XdremuxClassificationResult, hdr_kind) == 56);
static_assert(offsetof(XdremuxClassificationResult, family) == 64);
static_assert(sizeof(XdremuxClassificationResult) == 72);
static_assert(offsetof(XdremuxConversionResult, success) == 0);
static_assert(offsetof(XdremuxConversionResult, mode) == 8);
static_assert(offsetof(XdremuxConversionResult, family) == 16);
static_assert(offsetof(XdremuxConversionResult, edr_scale) == 24);
static_assert(offsetof(XdremuxConversionResult, gain_map_max) == 32);
static_assert(offsetof(XdremuxConversionResult, error_message) == 40);
static_assert(sizeof(XdremuxConversionResult) == 48);
static_assert(sizeof(XdremuxConvertConfig) == 5);

namespace {

std::mutex g_core_mutex;

struct RustStringDeleter {
    void operator()(char *value) const noexcept
    {
        if (value != nullptr) {
            xdremux_free_string(value);
        }
    }
};

struct ClassificationResultGuard {
    XdremuxClassificationResult value{};
    bool owns_result = false;

    ~ClassificationResultGuard()
    {
        if (owns_result) {
            xdremux_free_classification_result(value);
        }
    }
};

struct ConversionResultGuard {
    XdremuxConversionResult value{};
    bool owns_result = false;

    ~ConversionResultGuard()
    {
        if (owns_result) {
            xdremux_free_result(value);
        }
    }
};

struct ClassificationCopy {
    std::optional<std::string> mode_key;
    std::optional<std::string> folder_name;
    std::optional<std::string> status;
    std::optional<std::string> raw_user_comment;
    bool has_tag_flags = false;
    std::uint64_t tag_flags = 0;
    std::uint64_t unknown_flags = 0;
    std::optional<std::string> hdr_kind;
    std::optional<std::string> family;
};

struct ConversionCopy {
    bool success = false;
    std::optional<std::string> mode;
    std::optional<std::string> family;
    double edr_scale = 0.0;
    double gain_map_max = 0.0;
    std::optional<std::string> error_message;
};

struct AsyncContext {
    enum class Operation {
        VERSION,
        CLASSIFY,
        INSPECT,
        CONVERT,
    };

    napi_async_work async_work = nullptr;
    napi_deferred deferred = nullptr;
    Operation operation = Operation::VERSION;
    std::string input_path;
    std::string output_path;
    std::string version;
    std::string details_json;
    ClassificationCopy classification;
    ConversionCopy conversion;
    XdremuxConvertConfig config{};
    std::uint32_t progress_handle = 0;
    bool failed = false;
    std::array<char, 512> error_message{};
};

void set_error(AsyncContext &context, const char *message) noexcept
{
    context.failed = true;
    const char *source = message == nullptr ? "native xdremux operation failed" : message;
    const size_t capacity = context.error_message.size() - 1;
    const size_t length = std::min(std::strlen(source), capacity);
    std::memcpy(context.error_message.data(), source, length);
    context.error_message[length] = '\0';
}

std::optional<std::string> copy_optional_string(const char *value)
{
    if (value == nullptr) {
        return std::nullopt;
    }
    return std::string(value);
}

bool read_string(napi_env env, napi_value value, std::string &output)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        return false;
    }
    std::string buffer(length + 1, '\0');
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &length) != napi_ok) {
        return false;
    }
    output.assign(buffer.data(), length);
    return true;
}

void execute_operation(napi_env, void *data)
{
    auto *context = static_cast<AsyncContext *>(data);
    try {
        // Keep the Rust call off the UI thread and serialize it for P1.
        // Progress polling does not use this mutex.
        std::lock_guard<std::mutex> lock(g_core_mutex);
        switch (context->operation) {
        case AsyncContext::Operation::VERSION: {
            std::unique_ptr<char, RustStringDeleter> value(xdremux_version());
            if (!value) {
                set_error(*context, "xdremux_version returned a null string");
                return;
            }
            context->version.assign(value.get());
            return;
        }
        case AsyncContext::Operation::INSPECT: {
            std::unique_ptr<char, RustStringDeleter> value(
                xdremux_inspect_photo_details(context->input_path.c_str()));
            if (!value) {
                set_error(*context, "xdremux_inspect_photo_details returned a null report");
                return;
            }
            context->details_json.assign(value.get());
            return;
        }
        case AsyncContext::Operation::CLASSIFY: {
            ClassificationResultGuard result;
            result.value = xdremux_classify(context->input_path.c_str());
            result.owns_result = true;

            // Copy every owned field before the by-value result is released.
            // std::optional preserves null versus an empty C string.
            context->classification.mode_key = copy_optional_string(result.value.mode_key);
            context->classification.folder_name = copy_optional_string(result.value.folder_name);
            context->classification.status = copy_optional_string(result.value.status);
            context->classification.raw_user_comment = copy_optional_string(result.value.raw_user_comment);
            context->classification.has_tag_flags = result.value.has_tag_flags;
            context->classification.tag_flags = result.value.tag_flags;
            context->classification.unknown_flags = result.value.unknown_flags;
            context->classification.hdr_kind = copy_optional_string(result.value.hdr_kind);
            context->classification.family = copy_optional_string(result.value.family);
            return;
        }
        case AsyncContext::Operation::CONVERT: {
            ConversionResultGuard result;
            result.value = xdremux_convert_with_progress(
                context->input_path.c_str(),
                context->output_path.c_str(),
                &context->config,
                context->progress_handle);
            result.owns_result = true;
            context->conversion.success = result.value.success;
            context->conversion.mode = copy_optional_string(result.value.mode);
            context->conversion.family = copy_optional_string(result.value.family);
            context->conversion.edr_scale = result.value.edr_scale;
            context->conversion.gain_map_max = result.value.gain_map_max;
            context->conversion.error_message = copy_optional_string(result.value.error_message);
            return;
        }
        }
        set_error(*context, "unknown native operation");
    } catch (const std::exception &error) {
        set_error(*context, error.what());
    } catch (...) {
        set_error(*context, "native xdremux operation failed");
    }
}

void reject_with_message(napi_env env, napi_deferred deferred, const char *message)
{
    napi_value value = nullptr;
    if (napi_create_string_utf8(env, message, NAPI_AUTO_LENGTH, &value) != napi_ok) {
        napi_get_undefined(env, &value);
    }
    napi_reject_deferred(env, deferred, value);
}

bool set_optional_string(napi_env env, napi_value object, const char *name,
                         const std::optional<std::string> &value)
{
    napi_value js_value = nullptr;
    if (value.has_value()) {
        if (napi_create_string_utf8(env, value->c_str(), NAPI_AUTO_LENGTH, &js_value) != napi_ok) {
            return false;
        }
    } else {
        if (napi_get_null(env, &js_value) != napi_ok) {
            return false;
        }
    }
    return napi_set_named_property(env, object, name, js_value) == napi_ok;
}

bool set_bool(napi_env env, napi_value object, const char *name, bool value)
{
    napi_value js_value = nullptr;
    if (napi_get_boolean(env, value, &js_value) != napi_ok) {
        return false;
    }
    return napi_set_named_property(env, object, name, js_value) == napi_ok;
}

bool set_bigint(napi_env env, napi_value object, const char *name, std::uint64_t value)
{
    napi_value js_value = nullptr;
    if (napi_create_bigint_uint64(env, value, &js_value) != napi_ok) {
        return false;
    }
    return napi_set_named_property(env, object, name, js_value) == napi_ok;
}

bool set_double(napi_env env, napi_value object, const char *name, double value)
{
    napi_value js_value = nullptr;
    if (napi_create_double(env, value, &js_value) != napi_ok) {
        return false;
    }
    return napi_set_named_property(env, object, name, js_value) == napi_ok;
}

bool set_uint32(napi_env env, napi_value object, const char *name, std::uint32_t value)
{
    napi_value js_value = nullptr;
    if (napi_create_uint32(env, value, &js_value) != napi_ok) {
        return false;
    }
    return napi_set_named_property(env, object, name, js_value) == napi_ok;
}

napi_value make_classification(napi_env env, const ClassificationCopy &classification, napi_status &status)
{
    napi_value object = nullptr;
    status = napi_create_object(env, &object);
    if (status != napi_ok) {
        return nullptr;
    }
    if (!set_optional_string(env, object, "modeKey", classification.mode_key) ||
        !set_optional_string(env, object, "folderName", classification.folder_name) ||
        !set_optional_string(env, object, "status", classification.status) ||
        !set_optional_string(env, object, "rawUserComment", classification.raw_user_comment) ||
        !set_bool(env, object, "hasTagFlags", classification.has_tag_flags)) {
        status = napi_generic_failure;
        return nullptr;
    }
    // BigInt keeps the Rust u64 values lossless in ArkTS/JavaScript.
    if (!set_bigint(env, object, "tagFlags", classification.tag_flags) ||
        !set_bigint(env, object, "unknownFlags", classification.unknown_flags) ||
        !set_optional_string(env, object, "hdrKind", classification.hdr_kind) ||
        !set_optional_string(env, object, "family", classification.family)) {
        status = napi_generic_failure;
        return nullptr;
    }
    status = napi_ok;
    return object;
}

napi_value make_conversion(napi_env env, const ConversionCopy &conversion, napi_status &status)
{
    napi_value object = nullptr;
    status = napi_create_object(env, &object);
    if (status != napi_ok) {
        return nullptr;
    }
    if (!set_bool(env, object, "success", conversion.success) ||
        !set_optional_string(env, object, "mode", conversion.mode) ||
        !set_optional_string(env, object, "family", conversion.family) ||
        !set_double(env, object, "edrScale", conversion.edr_scale) ||
        !set_double(env, object, "gainMapMax", conversion.gain_map_max) ||
        !set_optional_string(env, object, "errorMessage", conversion.error_message)) {
        status = napi_generic_failure;
        return nullptr;
    }
    status = napi_ok;
    return object;
}

napi_value make_progress(napi_env env, std::uint32_t stage, std::uint32_t current,
                         std::uint32_t total, napi_status &status)
{
    napi_value object = nullptr;
    status = napi_create_object(env, &object);
    if (status != napi_ok) {
        return nullptr;
    }
    if (!set_uint32(env, object, "stage", stage) ||
        !set_uint32(env, object, "current", current) ||
        !set_uint32(env, object, "total", total)) {
        status = napi_generic_failure;
        return nullptr;
    }
    status = napi_ok;
    return object;
}

void complete_operation(napi_env env, napi_status status, void *data)
{
    std::unique_ptr<AsyncContext> context(static_cast<AsyncContext *>(data));
    if (status != napi_ok && !context->failed) {
        set_error(*context, "native async work failed");
    }

    if (context->failed) {
        reject_with_message(env, context->deferred, context->error_message.data());
    } else if (context->operation == AsyncContext::Operation::VERSION) {
        napi_value value = nullptr;
        if (napi_create_string_utf8(env, context->version.c_str(), NAPI_AUTO_LENGTH, &value) == napi_ok) {
            napi_resolve_deferred(env, context->deferred, value);
        } else {
            reject_with_message(env, context->deferred, "unable to create version result");
        }
    } else if (context->operation == AsyncContext::Operation::INSPECT) {
        napi_value value = nullptr;
        if (napi_create_string_utf8(env, context->details_json.c_str(), NAPI_AUTO_LENGTH, &value) == napi_ok) {
            napi_resolve_deferred(env, context->deferred, value);
        } else {
            reject_with_message(env, context->deferred, "unable to create photo details result");
        }
    } else {
        napi_status result_status = napi_ok;
        napi_value result = nullptr;
        if (context->operation == AsyncContext::Operation::CLASSIFY) {
            result = make_classification(env, context->classification, result_status);
        } else {
            result = make_conversion(env, context->conversion, result_status);
        }
        if (result_status == napi_ok && result != nullptr) {
            napi_resolve_deferred(env, context->deferred, result);
        } else {
            reject_with_message(
                env,
                context->deferred,
                context->operation == AsyncContext::Operation::CLASSIFY
                    ? "unable to create classification result"
                    : "unable to create conversion result");
        }
    }

    napi_delete_async_work(env, context->async_work);
}

void release_unqueued_progress(AsyncContext *context) noexcept
{
    if (context != nullptr && context->progress_handle != 0) {
        xdremux_progress_end(context->progress_handle);
        context->progress_handle = 0;
    }
}

napi_value queue_operation(napi_env env, AsyncContext *context)
{
    napi_value promise = nullptr;
    if (napi_create_promise(env, &context->deferred, &promise) != napi_ok) {
        release_unqueued_progress(context);
        delete context;
        napi_throw_error(env, nullptr, "unable to create native promise");
        return nullptr;
    }

    napi_value resource_name = nullptr;
    if (napi_create_string_utf8(env, "XdRemuxNative", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, execute_operation, complete_operation, context,
                               &context->async_work) != napi_ok) {
        release_unqueued_progress(context);
        delete context;
        napi_throw_error(env, nullptr, "unable to create native async work");
        return nullptr;
    }
    if (napi_queue_async_work(env, context->async_work) != napi_ok) {
        napi_delete_async_work(env, context->async_work);
        release_unqueued_progress(context);
        delete context;
        napi_throw_error(env, nullptr, "unable to queue native async work");
        return nullptr;
    }
    return promise;
}

napi_value version(napi_env env, napi_callback_info)
{
    auto *context = new (std::nothrow) AsyncContext();
    if (context == nullptr) {
        napi_throw_error(env, nullptr, "unable to allocate native async context");
        return nullptr;
    }
    context->operation = AsyncContext::Operation::VERSION;
    return queue_operation(env, context);
}

napi_value classify(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "classify(path) requires one filesystem path");
        return nullptr;
    }

    auto *context = new (std::nothrow) AsyncContext();
    if (context == nullptr) {
        napi_throw_error(env, nullptr, "unable to allocate native async context");
        return nullptr;
    }
    context->operation = AsyncContext::Operation::CLASSIFY;
    try {
        if (!read_string(env, args[0], context->input_path) || context->input_path.empty()) {
            delete context;
            napi_throw_type_error(env, nullptr, "classify(path) requires a non-empty filesystem path");
            return nullptr;
        }
        if (context->input_path.find('\0') != std::string::npos ||
            context->input_path.find("://") != std::string::npos) {
            delete context;
            napi_throw_type_error(env, nullptr, "classify(path) requires a local filesystem path, not a URI");
            return nullptr;
        }
    } catch (...) {
        delete context;
        napi_throw_error(env, nullptr, "unable to read classify path");
        return nullptr;
    }
    return queue_operation(env, context);
}

bool read_local_path(napi_env env, napi_value value, std::string &output)
{
    try {
        if (!read_string(env, value, output) || output.empty()) {
            return false;
        }
        return output.find('\0') == std::string::npos &&
               output.find("://") == std::string::npos;
    } catch (...) {
        return false;
    }
}

bool read_uint8_property(napi_env env, napi_value object, const char *name, std::uint8_t &output)
{
    napi_value value = nullptr;
    double number = 0.0;
    if (napi_get_named_property(env, object, name, &value) != napi_ok ||
        napi_get_value_double(env, value, &number) != napi_ok ||
        !std::isfinite(number) || number < 0.0 || number > 255.0 ||
        std::floor(number) != number) {
        return false;
    }
    output = static_cast<std::uint8_t>(number);
    return true;
}

bool read_convert_config(napi_env env, napi_value value, XdremuxConvertConfig &config)
{
    if (!read_uint8_property(env, value, "oppoCompat", config.oppo_compat) ||
        !read_uint8_property(env, value, "oppoCameraTail", config.oppo_camera_tail) ||
        !read_uint8_property(env, value, "strictTmap", config.strict_tmap) ||
        !read_uint8_property(env, value, "applePhotographicStyles",
                             config.apple_photographic_styles) ||
        !read_uint8_property(env, value, "applePortrait", config.apple_portrait)) {
        return false;
    }
    // Keep the native boundary aligned with the Rust config's documented
    // domains instead of allowing arbitrary byte values from JS.
    const bool compat_valid = config.oppo_compat <= 6;
    const bool tail_valid = config.oppo_camera_tail <= 9 || config.oppo_camera_tail == 255;
    const bool flags_valid = (config.strict_tmap == 0 || config.strict_tmap == 1) &&
                             (config.apple_photographic_styles == 0 ||
                              config.apple_photographic_styles == 1) &&
                             (config.apple_portrait == 0 || config.apple_portrait == 1);
    return compat_valid && tail_valid && flags_valid;
}

napi_value inspect(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "inspect(path) requires one filesystem path");
        return nullptr;
    }

    auto *context = new (std::nothrow) AsyncContext();
    if (context == nullptr) {
        napi_throw_error(env, nullptr, "unable to allocate native async context");
        return nullptr;
    }
    context->operation = AsyncContext::Operation::INSPECT;
    try {
        if (!read_local_path(env, args[0], context->input_path)) {
            delete context;
            napi_throw_type_error(env, nullptr, "inspect(path) requires a local filesystem path");
            return nullptr;
        }
    } catch (...) {
        delete context;
        napi_throw_error(env, nullptr, "unable to read inspect path");
        return nullptr;
    }
    return queue_operation(env, context);
}

napi_value convert(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value args[4] = {nullptr, nullptr, nullptr, nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 4) {
        napi_throw_type_error(
            env,
            nullptr,
            "convert(inputPath, outputPath, config, progressHandle) requires four arguments");
        return nullptr;
    }

    auto *context = new (std::nothrow) AsyncContext();
    if (context == nullptr) {
        napi_throw_error(env, nullptr, "unable to allocate native async context");
        return nullptr;
    }
    context->operation = AsyncContext::Operation::CONVERT;
    try {
        if (!read_local_path(env, args[0], context->input_path)) {
            delete context;
            napi_throw_type_error(env, nullptr, "convert requires a local input filesystem path");
            return nullptr;
        }
        if (!read_local_path(env, args[1], context->output_path)) {
            delete context;
            napi_throw_type_error(env, nullptr, "convert requires a local output filesystem path");
            return nullptr;
        }
        if (context->input_path == context->output_path) {
            delete context;
            napi_throw_type_error(env, nullptr, "convert output must differ from input");
            return nullptr;
        }
        if (!read_convert_config(env, args[2], context->config)) {
            delete context;
            napi_throw_type_error(env, nullptr, "convert requires a complete u8 configuration snapshot");
            return nullptr;
        }
        if (napi_get_value_uint32(env, args[3], &context->progress_handle) != napi_ok ||
            context->progress_handle == 0) {
            delete context;
            napi_throw_type_error(env, nullptr, "convert requires a live progress handle");
            return nullptr;
        }
    } catch (...) {
        delete context;
        napi_throw_error(env, nullptr, "unable to read convert arguments");
        return nullptr;
    }
    return queue_operation(env, context);
}

napi_value progress_begin(napi_env env, napi_callback_info)
{
    const std::uint32_t handle = xdremux_progress_begin();
    napi_value result = nullptr;
    if (napi_create_uint32(env, handle, &result) != napi_ok) {
        // JS never received this handle, so clean it up at the native boundary.
        xdremux_progress_end(handle);
        napi_throw_error(env, nullptr, "unable to create progress handle");
        return nullptr;
    }
    return result;
}

napi_value progress_read(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "progressRead(handle) requires one handle");
        return nullptr;
    }
    std::uint32_t handle = 0;
    if (napi_get_value_uint32(env, args[0], &handle) != napi_ok || handle == 0) {
        napi_throw_type_error(env, nullptr, "progressRead(handle) requires a non-zero handle");
        return nullptr;
    }

    // This path intentionally does not take g_core_mutex: Rust progress
    // registry reads must remain responsive while conversion owns that mutex.
    std::uint32_t values[3] = {0, 0, 0};
    xdremux_read_progress_for(handle, values);
    napi_status status = napi_ok;
    napi_value result = make_progress(env, values[0], values[1], values[2], status);
    if (status != napi_ok || result == nullptr) {
        napi_throw_error(env, nullptr, "unable to create progress result");
        return nullptr;
    }
    return result;
}

napi_value progress_end(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 1) {
        napi_throw_type_error(env, nullptr, "progressEnd(handle) requires one handle");
        return nullptr;
    }
    std::uint32_t handle = 0;
    if (napi_get_value_uint32(env, args[0], &handle) != napi_ok || handle == 0) {
        napi_throw_type_error(env, nullptr, "progressEnd(handle) requires a non-zero handle");
        return nullptr;
    }
    xdremux_progress_end(handle);
    napi_value result = nullptr;
    if (napi_get_undefined(env, &result) != napi_ok) {
        napi_throw_error(env, nullptr, "unable to create progress end result");
        return nullptr;
    }
    return result;
}

napi_value initialize(napi_env env, napi_value exports)
{
    const napi_property_descriptor descriptors[] = {
        {"version", nullptr, version, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"classify", nullptr, classify, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"inspect", nullptr, inspect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"convert", nullptr, convert, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"progressBegin", nullptr, progress_begin, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"progressRead", nullptr, progress_read, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"progressEnd", nullptr, progress_end, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    if (napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors) != napi_ok) {
        napi_throw_error(env, nullptr, "unable to define native module properties");
        return nullptr;
    }
    return exports;
}

} // namespace

extern "C" __attribute__((constructor)) void register_xdremux_native_module()
{
    static napi_module module = {
        1,
        0,
        nullptr,
        initialize,
        "entry",
        nullptr,
        {nullptr, nullptr, nullptr, nullptr},
    };
    napi_module_register(&module);
}
