#include <cassert>
#include <cstdint>
#include <string>
#include <vector>

#include "../entry/src/main/cpp/ps3_pipeline.h"

namespace {

std::vector<std::string> calls;
bool texture_result = true;
bool mattes_result = true;
bool styles_result = true;
bool portrait_result = true;
std::uint64_t observed_seed = 0;

std::uint8_t texture(const char *, const char *, std::uint64_t seed)
{
    calls.emplace_back("texture");
    observed_seed = seed;
    return texture_result ? 1 : 0;
}

std::uint8_t mattes(const char *, const char *)
{
    calls.emplace_back("mattes");
    return mattes_result ? 1 : 0;
}

bool styles(const char *)
{
    calls.emplace_back("styles");
    return styles_result;
}

bool portrait(const char *)
{
    calls.emplace_back("portrait");
    return portrait_result;
}

xdremux_bridge::Ps3PipelineCallbacks callbacks()
{
    return {texture, mattes, styles, portrait};
}

void reset()
{
    calls.clear();
    texture_result = true;
    mattes_result = true;
    styles_result = true;
    portrait_result = true;
    observed_seed = 0;
}

} // namespace

int main()
{
    const char *path = "/sandbox/outputs/job.heic.tmp";
    std::string error;

    reset();
    const bool success = xdremux_bridge::run_ps3_pipeline(
        path,
        {true, 104, true, true},
        callbacks(),
        error);
    assert(success);
    assert((calls == std::vector<std::string>{"texture", "mattes", "styles", "portrait"}));
    assert(observed_seed == 104);

    reset();
    texture_result = false;
    assert(!xdremux_bridge::run_ps3_pipeline(path, {true, 1, true, true}, callbacks(), error));
    assert(error.find("texture_styles") != std::string::npos);
    assert((calls == std::vector<std::string>{"texture"}));

    reset();
    mattes_result = false;
    assert(!xdremux_bridge::run_ps3_pipeline(path, {true, 1, true, true}, callbacks(), error));
    assert(error.find("matte") != std::string::npos);
    assert((calls == std::vector<std::string>{"texture", "mattes"}));

    reset();
    styles_result = false;
    assert(!xdremux_bridge::run_ps3_pipeline(path, {true, 1, true, true}, callbacks(), error));
    assert(error.find("结构验证") != std::string::npos);
    assert((calls == std::vector<std::string>{"texture", "mattes", "styles"}));

    reset();
    portrait_result = false;
    assert(!xdremux_bridge::run_ps3_pipeline(path, {true, 1, true, true}, callbacks(), error));
    assert(error.find("人像") != std::string::npos);
    assert((calls == std::vector<std::string>{"texture", "mattes", "styles", "portrait"}));

    reset();
    const bool styles_only = xdremux_bridge::run_ps3_pipeline(
        path,
        {false, 0, true, false},
        callbacks(),
        error);
    assert(styles_only);
    assert((calls == std::vector<std::string>{"styles"}));

    reset();
    const bool disabled = xdremux_bridge::run_ps3_pipeline(
        path,
        {false, 0, false, false},
        callbacks(),
        error);
    assert(disabled);
    assert(calls.empty());

    return 0;
}
