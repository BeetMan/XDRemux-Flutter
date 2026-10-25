// Canon EOS R5 Picture Style engine (PhotonCamera-bjzhou CanonToneAlgorithm GLSL + CanonIccShader),
// for the master LMT baker. tools/mastercolor/engines_canon.py is the reference. Every intermediate of the
// integer recipe stays within Int32 over the whole 16-bit input domain (checked offline), so int64
// arithmetic here equals the GLSL Int32 result.
#pragma once

#include <cstdint>
#include <vector>

namespace mastercolor {
namespace canon {

struct Icc {
    uint32_t grid = 0, n = 0, m = 0;
    std::vector<float> inputCurves, clut, outputCurves;  // [3][n], [grid^3][3], [3][m]
    float xyzToTarget[9] = {}, white[3] = {};            // row major
    std::vector<float> trc[3];
};

struct Style {
    std::vector<int32_t> words;  // 0x168 kernel words
    std::vector<int32_t> atlas;  // gamma_y 0x20000, gamma_c 0x20000, gamma_uv 0x10000, weights 4096
    bool hasIcc = false;
    Icc icc;
};

// applyEngineTone: EOS R5 white-balanced camera RGB (nominal white 1) -> linear sRGB.
void render(const Style &s, const double camera[3], double out[3]);

}  // namespace canon
}  // namespace mastercolor
