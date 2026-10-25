// AgX, darktable sigmoid and darktable filmic tone engines (PhotonCamera-bjzhou applyEngineTone),
// for the master LMT baker. tools/mastercolor/engines_dt.py is the reference. Input and output: linear
// BT.2020 (the engines' working space); output is display-linear.
#pragma once

namespace mastercolor {
namespace dt {

struct AgxParams {
    float black = -10.0f, white = 6.5f, toe = 1.5f, shoulder = 3.3f;
};

// RawToneMappingGl.computeFilmicToneCurveUniforms, precomputed offline (looks.py pack_dt).
struct FilmicUniforms {
    float black = 0, dynamicRange = 0, inputMin = 0, inputMax = 0, latitudeMin = 0, latitudeMax = 0;
    float m[5][3] = {};  // M1..M5, columns toe / shoulder / linear
};

// darktable sigmoid: film power ("contrast") and hue preservation (0..1). The paper exposure follows from the
// contrast so that scene mid grey (0.1845) stays at display 0.1845.
struct SigmoidParams {
    float contrast = 1.5f, hue = 1.0f;
};

// RawToneMappingGl.computeFilmicToneCurveUniforms for a black / white relative exposure (EV).
FilmicUniforms filmicUniforms(double black, double white);

void sigmoid(const SigmoidParams &p, const double in[3], double out[3]);
void agx(const AgxParams &p, const double in[3], double out[3]);
void filmic(const FilmicUniforms &u, const double in[3], double out[3]);

}  // namespace dt
}  // namespace mastercolor
