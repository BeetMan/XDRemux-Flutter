#pragma once

#include <cstdint>
#include <string>

namespace xdremux_bridge {

struct Ps3PipelineOptions {
    bool enabled = false;
    std::uint64_t grain_seed = 0;
    bool verify_styles = false;
    bool verify_portrait = false;
};

struct Ps3PipelineCallbacks {
    std::uint8_t (*inject_texture_styles)(
        const char *input_path,
        const char *output_path,
        std::uint64_t grain_seed) = nullptr;
    std::uint8_t (*inject_semantic_mattes)(
        const char *input_path,
        const char *output_path) = nullptr;
    bool (*verify_styles_output)(const char *path) = nullptr;
    bool (*verify_portrait_output)(const char *path) = nullptr;
};

/**
 * Apply the bridge-only PS3 stages to a task-owned temporary output.
 *
 * This helper keeps the order and publication gate independent of N-API. The
 * caller holds the core mutex for the whole call and only publishes the
 * temporary path after this function returns true. A failed stage leaves the
 * caller with a concrete message and never runs a later stage.
 */
inline bool run_ps3_pipeline(
    const char *path,
    const Ps3PipelineOptions &options,
    const Ps3PipelineCallbacks &callbacks,
    std::string &error)
{
    if (path == nullptr || callbacks.verify_styles_output == nullptr ||
        callbacks.verify_portrait_output == nullptr) {
        error = "PS3 桥接回调不可用";
        return false;
    }
    if (options.enabled) {
        if (callbacks.inject_texture_styles == nullptr ||
            callbacks.inject_texture_styles(path, path, options.grain_seed) == 0) {
            error = "PS3 texture_styles 注入失败";
            return false;
        }
        if (callbacks.inject_semantic_mattes == nullptr ||
            callbacks.inject_semantic_mattes(path, path) == 0) {
            error = "PS3 语义分区 matte 注入失败";
            return false;
        }
    }
    if (options.verify_styles && !callbacks.verify_styles_output(path)) {
        error = "Apple 摄影风格输出结构验证失败";
        return false;
    }
    if (options.verify_portrait && !callbacks.verify_portrait_output(path)) {
        error = "Apple 人像输出结构验证失败";
        return false;
    }
    return true;
}

} // namespace xdremux_bridge
