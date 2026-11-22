// N-API wrapper for the LocalSend transfer C ABI (crates/xdremux-transfer-ffi,
// include/xdremux_transfer.h). Every exported call is non-blocking: create and
// submit only queue work on the library's own Tokio runtime, and poll drains
// already produced records. So these wrappers run synchronously on the JS
// thread; ArkTS polls on a timer. File bytes never cross this boundary.
#include "transfer_bridge.h"

#include <cstdint>
#include <cstring>
#include <string>

extern "C" {
std::uint32_t xdremux_transfer_abi_version(void);
std::int32_t xdremux_transfer_create(const std::uint8_t *json, std::size_t len, std::uint64_t *handle);
std::int32_t xdremux_transfer_submit(std::uint64_t handle, const std::uint8_t *json, std::size_t len,
                                     std::uint64_t *operation);
std::int32_t xdremux_transfer_poll(std::uint64_t handle, std::uint32_t max_events, std::uint32_t max_bytes,
                                   char **json);
std::int32_t xdremux_transfer_stop(std::uint64_t handle);
std::int32_t xdremux_transfer_release(std::uint64_t handle);
std::int32_t xdremux_transfer_free_string(char *json);
}

namespace {

// Handles and operation IDs travel as JS numbers; refuse anything a double
// cannot hold exactly instead of silently rounding to another handle.
constexpr std::uint64_t kMaxSafeInteger = 9007199254740991ULL;
constexpr std::size_t kMaxRequestBytes = 1024 * 1024;

const char *status_name(std::int32_t status)
{
    switch (status) {
        case 1: return "InvalidInput";
        case 2: return "InvalidHandle";
        case 3: return "Busy";
        case 4: return "Closed";
        case 5: return "TooSmall";
        case 6: return "Internal";
        default: return "Unknown";
    }
}

void throw_status(napi_env env, const char *call, std::int32_t status)
{
    const std::string code = "TRANSFER_" + std::to_string(status);
    const std::string message = std::string(call) + " failed: " + status_name(status) +
        " (" + std::to_string(status) + ")";
    napi_throw_error(env, code.c_str(), message.c_str());
}

bool read_args(napi_env env, napi_callback_info info, size_t expected, napi_value *args, const char *usage)
{
    size_t argc = expected;
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != expected) {
        napi_throw_type_error(env, nullptr, usage);
        return false;
    }
    return true;
}

bool read_handle(napi_env env, napi_value value, std::uint64_t &handle)
{
    double number = 0;
    if (napi_get_value_double(env, value, &number) != napi_ok || !(number >= 1) ||
        number > static_cast<double>(kMaxSafeInteger) || number != static_cast<double>(static_cast<std::uint64_t>(number))) {
        napi_throw_type_error(env, nullptr, "transfer handle must be a positive safe integer");
        return false;
    }
    handle = static_cast<std::uint64_t>(number);
    return true;
}

bool read_utf8(napi_env env, napi_value value, std::string &output)
{
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok || length == 0 ||
        length > kMaxRequestBytes) {
        napi_throw_type_error(env, nullptr, "transfer request must be a non-empty JSON string up to 1 MiB");
        return false;
    }
    output.resize(length + 1);
    size_t written = 0;
    if (napi_get_value_string_utf8(env, value, output.data(), output.size(), &written) != napi_ok ||
        written != length) {
        napi_throw_error(env, nullptr, "unable to read transfer request");
        return false;
    }
    output.resize(length);
    return true;
}

napi_value make_number(napi_env env, std::uint64_t value, const char *what)
{
    if (value > kMaxSafeInteger) {
        napi_throw_range_error(env, nullptr, what);
        return nullptr;
    }
    napi_value result = nullptr;
    if (napi_create_double(env, static_cast<double>(value), &result) != napi_ok) {
        napi_throw_error(env, nullptr, "unable to create transfer number");
        return nullptr;
    }
    return result;
}

} // namespace

namespace xdremux_transfer_napi {

napi_value abi_version(napi_env env, napi_callback_info)
{
    napi_value result = nullptr;
    if (napi_create_uint32(env, xdremux_transfer_abi_version(), &result) != napi_ok) {
        napi_throw_error(env, nullptr, "unable to create transfer ABI version");
        return nullptr;
    }
    return result;
}

napi_value create(napi_env env, napi_callback_info info)
{
    napi_value args[1] = {nullptr};
    std::string config;
    if (!read_args(env, info, 1, args, "transferCreate(configJson) requires one JSON string") ||
        !read_utf8(env, args[0], config)) {
        return nullptr;
    }
    std::uint64_t handle = 0;
    const std::int32_t status = xdremux_transfer_create(
        reinterpret_cast<const std::uint8_t *>(config.data()), config.size(), &handle);
    if (status != 0) {
        throw_status(env, "xdremux_transfer_create", status);
        return nullptr;
    }
    if (handle > kMaxSafeInteger) {
        // Unreachable with the library's counter, but never leak a service.
        xdremux_transfer_stop(handle);
        napi_throw_range_error(env, nullptr, "transfer handle exceeds the JS safe integer range");
        return nullptr;
    }
    return make_number(env, handle, "transfer handle exceeds the JS safe integer range");
}

napi_value submit(napi_env env, napi_callback_info info)
{
    napi_value args[2] = {nullptr, nullptr};
    std::uint64_t handle = 0;
    std::string request;
    if (!read_args(env, info, 2, args, "transferSubmit(handle, requestJson) requires two arguments") ||
        !read_handle(env, args[0], handle) || !read_utf8(env, args[1], request)) {
        return nullptr;
    }
    std::uint64_t operation = 0;
    const std::int32_t status = xdremux_transfer_submit(
        handle, reinterpret_cast<const std::uint8_t *>(request.data()), request.size(), &operation);
    if (status != 0) {
        throw_status(env, "xdremux_transfer_submit", status);
        return nullptr;
    }
    return make_number(env, operation, "transfer operation ID exceeds the JS safe integer range");
}

napi_value poll(napi_env env, napi_callback_info info)
{
    napi_value args[3] = {nullptr, nullptr, nullptr};
    std::uint64_t handle = 0;
    std::uint32_t max_events = 0;
    std::uint32_t max_bytes = 0;
    if (!read_args(env, info, 3, args, "transferPoll(handle, maxEvents, maxBytes) requires three arguments") ||
        !read_handle(env, args[0], handle)) {
        return nullptr;
    }
    if (napi_get_value_uint32(env, args[1], &max_events) != napi_ok || max_events == 0 ||
        napi_get_value_uint32(env, args[2], &max_bytes) != napi_ok || max_bytes == 0) {
        napi_throw_type_error(env, nullptr, "transferPoll limits must be positive integers");
        return nullptr;
    }
    char *json = nullptr;
    const std::int32_t status = xdremux_transfer_poll(handle, max_events, max_bytes, &json);
    if (status != 0) {
        xdremux_transfer_free_string(json);
        throw_status(env, "xdremux_transfer_poll", status);
        return nullptr;
    }
    napi_value result = nullptr;
    const napi_status created = napi_create_string_utf8(
        env, json == nullptr ? "" : json, NAPI_AUTO_LENGTH, &result);
    // Free through the transfer library only, exactly once.
    xdremux_transfer_free_string(json);
    if (created != napi_ok) {
        napi_throw_error(env, nullptr, "unable to create transfer poll result");
        return nullptr;
    }
    return result;
}

napi_value stop(napi_env env, napi_callback_info info)
{
    napi_value args[1] = {nullptr};
    std::uint64_t handle = 0;
    if (!read_args(env, info, 1, args, "transferStop(handle) requires one handle") ||
        !read_handle(env, args[0], handle)) {
        return nullptr;
    }
    napi_value result = nullptr;
    napi_create_int32(env, xdremux_transfer_stop(handle), &result);
    return result;
}

napi_value release(napi_env env, napi_callback_info info)
{
    napi_value args[1] = {nullptr};
    std::uint64_t handle = 0;
    if (!read_args(env, info, 1, args, "transferRelease(handle) requires one handle") ||
        !read_handle(env, args[0], handle)) {
        return nullptr;
    }
    napi_value result = nullptr;
    napi_create_int32(env, xdremux_transfer_release(handle), &result);
    return result;
}

} // namespace xdremux_transfer_napi
