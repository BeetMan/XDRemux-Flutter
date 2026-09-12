#include "napi/native_api.h"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
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

char *xdremux_version();
void xdremux_free_string(char *value);
XdremuxClassificationResult xdremux_classify(const char *input_path);
void xdremux_free_classification_result(XdremuxClassificationResult result);
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

struct AsyncContext {
    enum class Operation {
        VERSION,
        CLASSIFY,
    };

    napi_async_work async_work = nullptr;
    napi_deferred deferred = nullptr;
    Operation operation = Operation::VERSION;
    std::string input_path;
    std::string version;
    ClassificationCopy classification;
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
        // Serialize core calls while keeping them off the UI thread. This is
        // the P0 policy for repeatable smoke calls and is deliberately scoped
        // to the native call, not the UI promise.
        std::lock_guard<std::mutex> lock(g_core_mutex);
        if (context->operation == AsyncContext::Operation::VERSION) {
            std::unique_ptr<char, RustStringDeleter> value(xdremux_version());
            if (!value) {
                set_error(*context, "xdremux_version returned a null string");
                return;
            }
            context->version.assign(value.get());
            return;
        }

        if (context->input_path.empty()) {
            set_error(*context, "classify requires a materialized filesystem path");
            return;
        }

        ClassificationResultGuard result;
        result.value = xdremux_classify(context->input_path.c_str());
        result.owns_result = true;

        // Copy every owned field before the guard releases the by-value Rust
        // result. std::optional preserves null versus an empty C string.
        context->classification.mode_key = copy_optional_string(result.value.mode_key);
        context->classification.folder_name = copy_optional_string(result.value.folder_name);
        context->classification.status = copy_optional_string(result.value.status);
        context->classification.raw_user_comment = copy_optional_string(result.value.raw_user_comment);
        context->classification.has_tag_flags = result.value.has_tag_flags;
        context->classification.tag_flags = result.value.tag_flags;
        context->classification.unknown_flags = result.value.unknown_flags;
        context->classification.hdr_kind = copy_optional_string(result.value.hdr_kind);
        context->classification.family = copy_optional_string(result.value.family);
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
    } else {
        napi_status result_status = napi_ok;
        napi_value result = make_classification(env, context->classification, result_status);
        if (result_status == napi_ok && result != nullptr) {
            napi_resolve_deferred(env, context->deferred, result);
        } else {
            reject_with_message(env, context->deferred, "unable to create classification result");
        }
    }

    napi_delete_async_work(env, context->async_work);
}

napi_value queue_operation(napi_env env, AsyncContext *context)
{
    napi_value promise = nullptr;
    if (napi_create_promise(env, &context->deferred, &promise) != napi_ok) {
        delete context;
        napi_throw_error(env, nullptr, "unable to create native promise");
        return nullptr;
    }

    napi_value resource_name = nullptr;
    if (napi_create_string_utf8(env, "XdRemuxNative", NAPI_AUTO_LENGTH, &resource_name) != napi_ok ||
        napi_create_async_work(env, nullptr, resource_name, execute_operation, complete_operation, context,
                               &context->async_work) != napi_ok) {
        delete context;
        napi_throw_error(env, nullptr, "unable to create native async work");
        return nullptr;
    }
    if (napi_queue_async_work(env, context->async_work) != napi_ok) {
        napi_delete_async_work(env, context->async_work);
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

napi_value initialize(napi_env env, napi_value exports)
{
    const napi_property_descriptor descriptors[] = {
        {"version", nullptr, version, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"classify", nullptr, classify, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(descriptors) / sizeof(descriptors[0]), descriptors);
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
