// Master LMT baker (HNCS, Lumix S9 PhotoStyles, Spektrafilm films, Canon, Darktable), platform independent.
// tools/mastercolor/master_lmt.py and tools/mastercolor/looks.py are the reference.
#pragma once

#include <array>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

namespace mastercolor {

enum class Path : int { Main = 0, Thumbnail = 1, Preview = 2 };

// Scene front stage (scene.bin): the Adobe Standard profile of a rear lens. `equivalentFocal` is the
// 35 mm equivalent focal length of the physical camera; false when no lens is within 25 %.
bool sceneLensFor(double equivalentFocal, std::string &lens);

// Everything a bake depends on. Two frames with equal keys share one baked table.
struct Key {
    Path path = Path::Main;
    int cct = 5000;                  // Kelvin, already bucketed by the caller
    std::array<float, 9> ccm{};      // post-AWB CCM of the frame (row major)
    std::string lens;                // scene front stage profile name (scene.bin)
    bool luxBlend = false;           // main path: trunc(luxindex) > 280
    std::vector<float> ipeGamma;     // unused (preview decodes with the capture encoding)
    std::string look = "hncs";       // "hncs" or a looks/<look>.bin name (lumix_*, film_*)
    float exposureEv = 0;            // user exposure compensation on the scene (EV), 0 = engine default
    // Blend mode: how much of the look replaces the stock LMT's tone and colour, 0..1 each.
    // 1 / 1 = plain replacement (the table and its directory name are unchanged).
    float toneWeight = 1;
    float colourWeight = 1;
    // User-facing CMY density values, 0.5..1.5; negative-film gain is (2 - value).
    std::array<float, 3> density{1, 1, 1};
    // Look parameters in the order of MasterLooks.paramsFor; NaN = the look file's default.
    //   basic_gamma: gamma;  agx: black, white (EV), toe, shoulder;  filmic: black, white (EV);  sigmoid: contrast, hue
    std::array<float, 4> param{NAN, NAN, NAN, NAN};
    float value(int index, float fallback) const { return std::isfinite(param[index]) ? param[index] : fallback; }

    bool blended() const { return toneWeight < 1 || colourWeight < 1; }
    std::string name() const;        // stable directory name
};

// Loads hncs_engine.bin (format 4) and scene.bin next to it; false if either is missing or malformed. Look files are read from
// looks/ next to it on first use.
bool loadEngine(const std::string &path, std::string *error);
bool engineReady();

constexpr int kLutSize = 64;
// Planes R, G, B, each [B][G][R] with R fastest (BasicTone / CombineLut LMTLut layout).
bool bake(const Key &key, std::vector<float> &lut, int threads);

constexpr int kStockTables = 6;   // LMTLut0..5: the stock master LMT interpolates them by scene level

// The look's tables: one baked table, or kStockTables slot tables for a look that keeps the stock
// per-frame selection (x8u: another model's stock master LMTs).
bool lookTables(const Key &key, std::vector<std::vector<float>> &tables, int threads);

// Blend mode. `looks` are the look's tables (lookTables(key) with the weights ignored), one for every
// slot or one per slot. Splits the slot's look table and each
// stock table stockDir/LMTLut<i> into tone (the neutral-axis curve, as a function of the scene luma of
// the input code) and colour (per-channel ratio to that curve), both in linear light of the HLG output,
// then recombines tone^(1-wt)*look^wt and colour likewise. Weights 1/1 give the look, 0/0 the stock table.
// Tone is a scalar, so it never changes the chromaticity; colour carries hue, saturation and the
// colour-dependent brightness. tools/mastercolor/blend_check.cpp / .py check it on a host.
bool blendWithStock(const Key &key, const std::vector<std::vector<float>> &looks, const std::string &stockDir,
                    std::vector<std::vector<float>> &tables, int threads);

// Serialised key for the preview directory (written by the Java side, read here).
bool readKeyFile(const std::string &path, Key &key);

}  // namespace mastercolor
