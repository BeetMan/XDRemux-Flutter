// Soft light replacement: the weak level (柔美, Meishe ProMist type 1) renders as a Ricoh GR HDF,
// the medium level (朦胧, type 0) as a 1/4 black mist, the strong level (梦幻, type 2) as a white
// mist.
//
// Every soft light runs in libmsnativefilter on the camera's HLG frame: preview through
// MsRenderHDRTexture (an RGBA8 HLG texture), capture through MsRenderHardwareBuffer (a P010
// hardware buffer). For the two replaced levels the hooks switch the stock ProMist off, let
// Meishe render the rest of the filter, and scatter its output:
//
//   out_c = (core_c * I_c + sum_i w_c,i * L_i,c) / transmission_c      in scene light E (HLG)
//
// L_i is a blur pyramid (13-tap 2x downsample per level, back up through a chain of 2x tent
// upsamples, U_i = w_i * L_i + tent_up(U_i+1)); the weights per level and channel distil a
// physical-optics simulation of each filter (soft_light_weights.h, tools/softlight). The point
// spread is an angle in front of the lens, so the table row follows the focal length in pixels:
//   f_px = focal_35mm / 43.267 * diagonal_px
// The HLG signal is the master LMT output, so it is decoded to scene light through the master
// pipeline's neutral tone curve (soft_light_curve.h, tools/softlight/gen_curve.py: builtin gamma
// then the stock LMT grey axis, per channel) and encoded back through the same curve after the
// scatter; light above the sensor clip goes through a soft shoulder on the peak channel, channels
// scaled together so a halo keeps the hue of its source. A source clipped in the Hybrid Raw is
// brighter than recorded (a desk lamp in RAWMax: at least 1.8 times the white level, from its
// least clipped channel), and its true light both scatters and passes the filter unscattered. For
// the HDF that light is kSourceGain times the recorded value at the clip: the pyramid sees pixels
// scaled up by a gain rising linearly in log2 of the peak channel from 1 at boostStops below the
// clip, and the unscattered core is scaled up where the surroundings within kSourceDeg sit within
// kSourceStops of the clip (the local mean, not the pixel, so texture is never expanded), so the
// shoulder flattens the source into one even glow as a single exposure clips it. With the source's
// true light carrying the halo, the HDF's scatter fraction is about 20 % and the rest of the frame
// stays clear. Black and white mist scatter clipped pixels at their recorded light: on the master
// frame lit white surfaces reach the clip too, and boosting them through a wide halo makes them
// glow like lights.
// Preview runs the passes in Meishe's GL context; capture runs the same arithmetic on the CPU and
// adds the change to the P010 buffer.
#include <EGL/egl.h>
#include <dlfcn.h>
#include <GLES3/gl3.h>
#include <android/hardware_buffer.h>
#include <android/log.h>
#include <jni.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <map>
#include <thread>
#include <vector>

#include "native_hooks.h"
#include "soft_light_curve.h"
#include "soft_light_weights.h"

namespace {

constexpr const char *TAG = "MuseSoftLight";
constexpr float kFullFrameDiagonalMm = 43.267f;
constexpr float kHdfFocalMm = 28.0f;  // the GR lens the HDF belongs to
constexpr float kShoulder = 0.8f;   // of the top: the sensor clip (HLG) or display white (sRGB)
constexpr float kSourceDeg = 0.1f;    // neighbourhood that decides whether a pixel lies in a light source
constexpr float kSourceStops = 0.3f;  // the core gate opens over this many stops below the clip
constexpr float kSourceGain = 2.6f;   // HDF: true light of a clipped source over its recorded value

std::atomic<float> gFocalMm{0.0f};  // 0 until the zoom bar reports
std::atomic<bool> gMasterMode{false};  // the camera is in 大师模式; every other mode keeps the stock path
std::atomic<bool> gNoLocalContrast{false};  // setting: captures with a replaced soft light skip the fusion
std::atomic<bool> gCaptureSoft{false};  // the capture HDRTransform is working on carries a replaced soft light
std::atomic<int> gLevels{0};  // replaced levels, bit = ProMist type; a clear bit leaves the stock soft light

// SMsEffectParam: the ProMist switch and type.
constexpr size_t kSoftEnable = 0x48;
constexpr size_t kSoftType = 0x4c;

const SoftFilter *filterFor(const void *param) {
    auto *p = static_cast<const uint8_t *>(param);
    if (!p || !p[kSoftEnable] || !gMasterMode.load()) return nullptr;
    int32_t type;
    std::memcpy(&type, p + kSoftType, sizeof type);
    if (type < 0 || type > 2 || !(gLevels.load() & (1 << type))) return nullptr;
    if (type == 1) return &kHdf;
    if (type == 0) return &kBlackMist;
    if (type == 2) return &kWhiteMist;
    return nullptr;
}

// Stock ProMist off for one render call.
class StockSoftOff {
public:
    explicit StockSoftOff(const void *param) : flag_(const_cast<uint8_t *>(static_cast<const uint8_t *>(param)) + kSoftEnable) {
        *flag_ = 0;
    }
    ~StockSoftOff() { *flag_ = 1; }
private:
    uint8_t *flag_;
};

enum Transfer { kSrgb, kHlg };

// Per-level, per-channel weights for an image of this diagonal. Beyond the end of the table the
// pyramid base moves up one level per doubling of the focal length.
struct LevelWeights {
    float core[3];
    float transmission[3];
    float w[3][kSoftLevels];
};

LevelWeights levelWeights(const SoftFilter &f, float diagonalPx, int builtLevels) {
    // The HDF sits in the GR's own 28 mm lens: its halo spans the same share of the frame at every
    // zoom. Black and white mist are filters in front of the lens in use and follow its focal length.
    float focal = &f == &kHdf ? kHdfFocalMm : gFocalMm.load();
    if (focal <= 0) focal = 23.0f;  // main camera at 1x until the zoom bar reports
    float l2 = std::log2(focal / kFullFrameDiagonalMm * diagonalPx);
    float last = kSoftLog2First + kSoftLog2Step * (kSoftRows - 1);
    int shift = 0;
    while (l2 - shift > last) shift++;
    float pos = std::clamp((l2 - shift - kSoftLog2First) / kSoftLog2Step, 0.0f, float(kSoftRows - 1));
    int r0 = int(pos);
    int r1 = std::min(r0 + 1, kSoftRows - 1);
    float t = pos - r0;
    LevelWeights out{};
    for (int c = 0; c < 3; c++) {
        out.core[c] = f.core[c];
        out.transmission[c] = f.transmission[c];
        for (int i = 0; i < kSoftLevels; i++) {
            int level = std::min(i + shift, builtLevels);  // levels the image is too small for go to the coarsest
            out.w[c][level] += f.weights[r0][c][i] * (1 - t) + f.weights[r1][c][i] * t;
        }
    }
    return out;
}

// Light of a clipped source over its recorded value: the HDF only, 1 elsewhere.
float sourceGain(const SoftFilter &f) { return &f == &kHdf ? kSourceGain : 1.0f; }

// Pyramid level (1 = half size) whose texels average about kSourceDeg, for this image diagonal.
int sourceLevel(const SoftFilter &f, float diagonalPx, int builtLevels) {
    float focal = &f == &kHdf ? kHdfFocalMm : gFocalMm.load();
    if (focal <= 0) focal = 23.0f;
    float px = focal / kFullFrameDiagonalMm * diagonalPx * kSourceDeg * float(M_PI) / 180.0f;
    return std::clamp(int(std::lround(std::log2(std::max(px, 1.0f)))), 1, builtLevels);
}

// ---- transfer functions: signal <-> scene light ---------------------------------------------

inline float tableAt(const float *t, float pos) {
    pos = std::clamp(pos, 0.0f, float(kSoftCurveN - 1));
    int i = std::min(int(pos), kSoftCurveN - 2);
    float f = pos - i;
    return t[i] * (1 - f) + t[i + 1] * f;
}

inline float decode(float v, Transfer tr) {
    v = std::clamp(v, 0.0f, 1.0f);
    if (tr == kHlg) return tableAt(kSoftHlgToScene, v * (kSoftCurveN - 1));
    return v <= 0.04045f ? v / 12.92f : std::pow((v + 0.055f) / 1.055f, 2.4f);
}

inline float encode(float e, Transfer tr) {
    if (tr == kHlg) {
        float lo = std::exp2(kSoftLog2SceneMin);
        if (e <= lo) return std::max(e, 0.0f) / lo * kSoftSceneToHlg[0];
        float pos = (std::log2(e) - kSoftLog2SceneMin) / (kSoftLog2SceneMax - kSoftLog2SceneMin) * (kSoftCurveN - 1);
        return tableAt(kSoftSceneToHlg, pos);
    }
    e = std::clamp(e, 0.0f, 1.0f);
    return e <= 0.0031308f ? 12.92f * e : 1.055f * std::pow(e, 1.0f / 2.4f) - 0.055f;
}

inline float topOf(Transfer tr) { return tr == kHlg ? kSoftSceneMax : 1.0f; }

inline void shoulder(float rgb[3], float top) {
    float peak = std::max(rgb[0], std::max(rgb[1], rgb[2]));
    float knee = kShoulder * top;
    if (peak <= knee) return;
    float comp = knee + (top - knee) * std::tanh((peak - knee) / (top - knee));
    for (int c = 0; c < 3; c++) rgb[c] *= comp / peak;
}

// Stops below the clip where the boost starts: the top half stop of the frame, the shoulder knee on display white.
inline float boostStops(Transfer tr) { return tr == kHlg ? 0.5f : -std::log2(kShoulder); }

// Scatter source: pixels near the clip scaled up, gain times at the clip.
inline void boostClipped(float rgb[3], float log2Top, float stops, float gain) {
    float peak = std::max(rgb[0], std::max(rgb[1], rgb[2]));
    if (peak <= 0.0f) return;
    float t = (std::log2(peak) - (log2Top - stops)) / stops;
    if (t <= 0.0f) return;
    float s = 1.0f + (gain - 1.0f) * std::min(t, 1.0f);
    for (int c = 0; c < 3; c++) rgb[c] *= s;
}

// Core gain for a neighbourhood whose peak channel averages `peak`.
inline float coreGain(float peak, float log2Top, float gain) {
    if (gain <= 1.0f || peak <= 0.0f) return 1.0f;
    float t = std::clamp((std::log2(peak) - (log2Top - kSourceStops)) / kSourceStops, 0.0f, 1.0f);
    return 1.0f + (gain - 1.0f) * t;
}

// ---- capture: CPU pyramid on the P010 buffer --------------------------------------------------

template <typename F>
void parallelRows(int rows, F &&body) {
    int n = std::clamp(int(std::thread::hardware_concurrency()), 1, 8);
    std::vector<std::thread> pool;
    for (int k = 0; k < n; k++) {
        pool.emplace_back([&, k] {
            for (int y = k; y < rows; y += n) body(y);
        });
    }
    for (auto &t : pool) t.join();
}

struct Image {
    int w = 0, h = 0;
    std::vector<float> px;  // RGB
    float *at(int x, int y) { return &px[(size_t(y) * w + x) * 3]; }
    const float *at(int x, int y) const { return &px[(size_t(y) * w + x) * 3]; }
};

inline int reflect(int i, int n) {  // cv2.BORDER_REFLECT, as the weights were fitted with
    while (i < 0 || i >= n) i = i < 0 ? -i - 1 : 2 * n - i - 1;
    return i;
}

// PASS_DOWN: every tap sits between four texels, i.e. a 2x2 mean at an integer offset.
template <typename Fetch>
Image downsample(int sw, int sh, Fetch fetch) {
    Image d;
    d.w = sw / 2;
    d.h = sh / 2;
    d.px.assign(size_t(d.w) * d.h * 3, 0.0f);
    static const struct { int dx, dy; float w; } taps[] = {
        {0, 0, 0.125f}, {-1, -1, 0.125f}, {1, -1, 0.125f}, {-1, 1, 0.125f}, {1, 1, 0.125f},
        {-2, -2, 0.03125f}, {2, -2, 0.03125f}, {-2, 2, 0.03125f}, {2, 2, 0.03125f},
        {-2, 0, 0.0625f}, {2, 0, 0.0625f}, {0, -2, 0.0625f}, {0, 2, 0.0625f}};
    parallelRows(d.h, [&](int y) {
        for (int x = 0; x < d.w; x++) {
            float acc[3] = {0, 0, 0};
            for (auto &tap : taps) {
                int x0 = 2 * x + tap.dx, y0 = 2 * y + tap.dy;
                float box[3] = {0, 0, 0};
                for (int j = 0; j < 2; j++)
                    for (int i = 0; i < 2; i++) {
                        float v[3];
                        fetch(reflect(x0 + i, sw), reflect(y0 + j, sh), v);
                        for (int c = 0; c < 3; c++) box[c] += v[c];
                    }
                for (int c = 0; c < 3; c++) acc[c] += tap.w * 0.25f * box[c];
            }
            std::memcpy(d.at(x, y), acc, sizeof acc);
        }
    });
    return d;
}

// 2x tent upsample ([1 2 1]^2 / 16 of bilinear fetches one coarse texel apart) as a separable
// 4-tap kernel: even output 2k reads k-2..k+1, odd output 2k+1 reads k-1..k+2.
constexpr float kTentEven[4] = {0.0625f, 0.3125f, 0.4375f, 0.1875f};
constexpr float kTentOdd[4] = {0.1875f, 0.4375f, 0.3125f, 0.0625f};

inline void tentAt(const Image &s, int x, int y, float out[3]) {
    int bx = (x >> 1) - ((x & 1) ? 1 : 2), by = (y >> 1) - ((y & 1) ? 1 : 2);
    const float *wx = (x & 1) ? kTentOdd : kTentEven;
    const float *wy = (y & 1) ? kTentOdd : kTentEven;
    out[0] = out[1] = out[2] = 0;
    for (int j = 0; j < 4; j++) {
        int sy = reflect(by + j, s.h);
        for (int i = 0; i < 4; i++) {
            const float *v = s.at(reflect(bx + i, s.w), sy);
            float w = wx[i] * wy[j];
            for (int c = 0; c < 3; c++) out[c] += w * v[c];
        }
    }
}

// Level texel (x, y) covers full-resolution pixels around ((x + 0.5) * 2^k - 0.5): bilinear, clamped.
inline void levelAt(const Image &s, int k, int x, int y, float out[3]) {
    float scale = 1.0f / float(1 << k);
    float fx = std::clamp((x + 0.5f) * scale - 0.5f, 0.0f, float(s.w - 1));
    float fy = std::clamp((y + 0.5f) * scale - 0.5f, 0.0f, float(s.h - 1));
    int x0 = int(fx), y0 = int(fy), x1 = std::min(x0 + 1, s.w - 1), y1 = std::min(y0 + 1, s.h - 1);
    float ax = fx - x0, ay = fy - y0;
    const float *a = s.at(x0, y0), *b = s.at(x1, y0), *c = s.at(x0, y1), *d = s.at(x1, y1);
    for (int i = 0; i < 3; i++) out[i] = (a[i] * (1 - ax) + b[i] * ax) * (1 - ay) + (c[i] * (1 - ax) + d[i] * ax) * ay;
}

struct YuvCoding {
    float kr, kb;
    bool full;
    bool msb;   // 10 significant bits at the top of each 16-bit word
};

YuvCoding yuvCoding(int matrix, int range) {
    // EMsYuvColorMatrix 0 / 1 / 2 = BT.601 / BT.709 / BT.2020; EMsYuvRange 1 = full.
    YuvCoding y{0.299f, 0.114f, range == 1, false};
    if (matrix == 1) { y.kr = 0.2126f; y.kb = 0.0722f; }
    if (matrix == 2) { y.kr = 0.2627f; y.kb = 0.0593f; }
    return y;
}

struct P010 {
    AHardwareBuffer_Planes planes{};
    int w = 0, h = 0;
    uint16_t *y(int x, int r) { return reinterpret_cast<uint16_t *>(static_cast<uint8_t *>(planes.planes[0].data) + size_t(r) * planes.planes[0].rowStride) + x; }
    uint16_t *u(int x, int r) { return reinterpret_cast<uint16_t *>(static_cast<uint8_t *>(planes.planes[1].data) + size_t(r) * planes.planes[1].rowStride + size_t(x) * planes.planes[1].pixelStride); }
    uint16_t *v(int x, int r) { return reinterpret_cast<uint16_t *>(static_cast<uint8_t *>(planes.planes[2].data) + size_t(r) * planes.planes[2].rowStride + size_t(x) * planes.planes[2].pixelStride); }
};

inline float codeToUnit(uint16_t raw, const YuvCoding &c) { return float(c.msb ? raw >> 6 : raw & 0x3ff); }
inline uint16_t unitToCode(float v, const YuvCoding &c) {
    int q = int(std::lround(std::clamp(v, 0.0f, 1023.0f)));
    return uint16_t(c.msb ? q << 6 : q);
}

// Encoded (non-linear) RGB of one pixel from its YUV codes.
inline void yuvToRgb(float Y, float U, float V, const YuvCoding &c, float rgb[3]) {
    float y = c.full ? Y / 1023.0f : (Y - 64.0f) / 876.0f;
    float cb = c.full ? (U - 512.0f) / 1023.0f : (U - 512.0f) / 896.0f;
    float cr = c.full ? (V - 512.0f) / 1023.0f : (V - 512.0f) / 896.0f;
    float kg = 1 - c.kr - c.kb;
    rgb[0] = y + 2 * (1 - c.kr) * cr;
    rgb[2] = y + 2 * (1 - c.kb) * cb;
    rgb[1] = (y - c.kr * rgb[0] - c.kb * rgb[2]) / kg;
}

inline void rgbToYuvDelta(const float d[3], const YuvCoding &c, float &dy, float &du, float &dv) {
    float kg = 1 - c.kr - c.kb;
    float y = c.kr * d[0] + kg * d[1] + c.kb * d[2];
    float cb = (d[2] - y) / (2 * (1 - c.kb));
    float cr = (d[0] - y) / (2 * (1 - c.kr));
    dy = y * (c.full ? 1023.0f : 876.0f);
    du = cb * (c.full ? 1023.0f : 896.0f);
    dv = cr * (c.full ? 1023.0f : 896.0f);
}

void scatterP010(AHardwareBuffer *ahb, const SoftFilter &filter, Transfer tr, YuvCoding coding) {
    AHardwareBuffer_Desc desc{};
    AHardwareBuffer_describe(ahb, &desc);
    P010 img;
    img.w = int(desc.width) & ~1;
    img.h = int(desc.height) & ~1;
    // API 29; the module's minimum is 28.
    using LockPlanes = int (*)(AHardwareBuffer *, uint64_t, int32_t, const ARect *, AHardwareBuffer_Planes *);
    static auto lockPlanes = reinterpret_cast<LockPlanes>(dlsym(RTLD_DEFAULT, "AHardwareBuffer_lockPlanes"));
    if (!lockPlanes ||
        lockPlanes(ahb, AHARDWAREBUFFER_USAGE_CPU_READ_OFTEN | AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN, -1, nullptr, &img.planes) != 0 ||
        img.planes.planeCount < 3) {
        __android_log_print(ANDROID_LOG_ERROR, TAG, "capture: P010 buffer not lockable (format 0x%x)", desc.format);
        return;
    }
    // 10-bit codes at the top of the word leave the low 6 bits empty.
    bool lowBits = false;
    for (int r = 0; r < img.h && !lowBits; r += 97)
        for (int x = 0; x < img.w; x += 13) lowBits |= (*img.y(x, r) & 0x3f) != 0;
    coding.msb = !lowBits;

    // Level 0: scene light of every pixel (chroma shared by its 2x2 block), half precision.
    struct {
        int w, h;
        std::vector<__fp16> px;
        __fp16 *at(int x, int y) { return &px[(size_t(y) * w + x) * 3]; }
        void get(int x, int y, float v[3]) { const __fp16 *p = at(x, y); v[0] = p[0]; v[1] = p[1]; v[2] = p[2]; }
    } l0{img.w, img.h, {}};
    l0.px.resize(size_t(l0.w) * l0.h * 3);
    parallelRows(img.h / 2, [&](int by) {
        for (int bx = 0; bx < img.w / 2; bx++) {
            float U = codeToUnit(*img.u(bx, by), coding), V = codeToUnit(*img.v(bx, by), coding);
            for (int j = 0; j < 2; j++)
                for (int i = 0; i < 2; i++) {
                    int x = 2 * bx + i, y = 2 * by + j;
                    float rgb[3];
                    yuvToRgb(codeToUnit(*img.y(x, y), coding), U, V, coding, rgb);
                    __fp16 *e = l0.at(x, y);
                    for (int c = 0; c < 3; c++) e[c] = __fp16(decode(rgb[c], tr));
                }
        }
    });

    std::vector<Image> levels;
    {
        int w = l0.w, h = l0.h;
        float log2Top = std::log2(topOf(tr)), stops = boostStops(tr), boost = sourceGain(filter);
        auto fetch0 = [&](int x, int y, float v[3]) {
            l0.get(x, y, v);
            boostClipped(v, log2Top, stops, boost);
        };
        levels.push_back(downsample(w, h, fetch0));
        while (int(levels.size()) < kSoftLevels - 1 && std::min(levels.back().w, levels.back().h) >= 4) {
            const Image &s = levels.back();
            levels.push_back(downsample(s.w, s.h, [&](int x, int y, float v[3]) { std::memcpy(v, s.at(x, y), 3 * sizeof(float)); }));
        }
    }
    int built = int(levels.size());
    LevelWeights lw = levelWeights(filter, std::hypot(float(l0.w), float(l0.h)), built);
    float gain = sourceGain(filter), log2Top = std::log2(topOf(tr));
    int gateLevel = sourceLevel(filter, std::hypot(float(l0.w), float(l0.h)), built);
    Image gate;
    if (gain > 1.0f) gate = levels[gateLevel - 1];

    // Up chain: U_n = w_n L_n; U_i = w_i L_i + tent_up(U_i+1).
    Image up = levels[built - 1];
    for (size_t k = 0; k < up.px.size(); k++) up.px[k] *= lw.w[k % 3][built];
    for (int i = built - 1; i >= 1; i--) {
        Image &L = levels[i - 1];
        Image next;
        next.w = L.w;
        next.h = L.h;
        next.px.resize(L.px.size());
        parallelRows(L.h, [&](int y) {
            for (int x = 0; x < L.w; x++) {
                float t[3];
                tentAt(up, x, y, t);
                const float *l = L.at(x, y);
                float *o = next.at(x, y);
                for (int c = 0; c < 3; c++) o[c] = lw.w[c][i] * l[c] + t[c];
            }
        });
        up = std::move(next);
    }
    levels.clear();

    // Composite and write back the change of each pixel's encoded RGB, chroma per 2x2 block.
    std::atomic<int64_t> changed{0};
    parallelRows(img.h / 2, [&](int by) {
        for (int bx = 0; bx < img.w / 2; bx++) {
            float dU = 0, dV = 0;
            for (int j = 0; j < 2; j++)
                for (int i = 0; i < 2; i++) {
                    int x = 2 * bx + i, y = 2 * by + j;
                    float e[3];
                    l0.get(x, y, e);
                    float t[3];
                    tentAt(up, x, y, t);
                    float acc[3], d[3];
                    float k = 1.0f;
                    if (gain > 1.0f) {
                        float m[3];
                        levelAt(gate, gateLevel, x, y, m);
                        k = coreGain(std::max(m[0], std::max(m[1], m[2])), log2Top, gain);
                    }
                    for (int c = 0; c < 3; c++) acc[c] = ((lw.core[c] + lw.w[c][0]) * k * e[c] + t[c]) / lw.transmission[c];
                    shoulder(acc, topOf(tr));
                    for (int c = 0; c < 3; c++) d[c] = encode(acc[c], tr) - encode(e[c], tr);
                    float dy, du, dv;
                    rgbToYuvDelta(d, coding, dy, du, dv);
                    uint16_t *py = img.y(x, y);
                    if (std::fabs(dy) >= 0.5f) changed.fetch_add(1, std::memory_order_relaxed);
                    *py = unitToCode(codeToUnit(*py, coding) + dy, coding);
                    dU += du * 0.25f;
                    dV += dv * 0.25f;
                }
            uint16_t *pu = img.u(bx, by), *pv = img.v(bx, by);
            *pu = unitToCode(codeToUnit(*pu, coding) + dU, coding);
            *pv = unitToCode(codeToUnit(*pv, coding) + dV, coding);
        }
    });
    AHardwareBuffer_unlock(ahb, nullptr);
    __android_log_print(ANDROID_LOG_INFO, TAG, "capture: %s P010, %d levels, %.1f%% of pixels changed", coding.msb ? "MSB" : "LSB",
                        built, 100.0 * double(changed.load()) / (double(img.w) * img.h));
}

// ---- preview: the same passes in Meishe's GL context -----------------------------------------

const char *kVertex = R"(#version 300 es
out vec2 vUv;
void main() {
    vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    vUv = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

const char *kCommon = R"(#version 300 es
precision highp float;
precision highp int;
out vec4 fragColor;
// HLG: the master tone curve, row 0 signal -> scene light, row 1 log2 scene light -> signal.
uniform int uHlg;
uniform highp sampler2D uCurve;
uniform vec3 uCurveLimits;   // log2 scene min, log2 scene max, first forward value
float curveAt(int row, float pos) {
    float n = float(textureSize(uCurve, 0).x - 1);
    pos = clamp(pos, 0.0, n);
    int i = min(int(pos), int(n) - 1);
    float f = pos - float(i);
    return mix(texelFetch(uCurve, ivec2(i, row), 0).r, texelFetch(uCurve, ivec2(i + 1, row), 0).r, f);
}
vec3 decode(vec3 v) {
    v = clamp(v, 0.0, 1.0);
    if (uHlg == 1) {
        float n = float(textureSize(uCurve, 0).x - 1);
        return vec3(curveAt(0, v.r * n), curveAt(0, v.g * n), curveAt(0, v.b * n));
    }
    return mix(v / 12.92, pow((v + 0.055) / 1.055, vec3(2.4)), step(0.04045, v));
}
float encodeHlg(float e) {
    float lo = exp2(uCurveLimits.x);
    if (e <= lo) return max(e, 0.0) / lo * uCurveLimits.z;
    float n = float(textureSize(uCurve, 0).x - 1);
    return curveAt(1, (log2(e) - uCurveLimits.x) / (uCurveLimits.y - uCurveLimits.x) * n);
}
vec3 encode(vec3 e) {
    if (uHlg == 1) return vec3(encodeHlg(e.r), encodeHlg(e.g), encodeHlg(e.b));
    e = clamp(e, 0.0, 1.0);
    return mix(12.92 * e, 1.055 * pow(e, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, e));
}
// 2x tent upsample: fine texel centre (x + 0.5) sits at coarse coordinate (x + 0.5) / 2.
vec3 tentUp(sampler2D src, vec2 coarseTexel) {
    vec2 c = gl_FragCoord.xy * 0.5;
    vec3 acc = vec3(0.0);
    for (int y = -1; y <= 1; y++)
        for (int x = -1; x <= 1; x++) {
            float w = (x == 0 ? 0.5 : 0.25) * (y == 0 ? 0.5 : 0.25);
            acc += w * texture(src, (c + vec2(float(x), float(y))) * coarseTexel).rgb;
        }
    return acc;
}
)";

const char *kLinearize = R"(
uniform sampler2D uSrc;
void main() {
    fragColor = vec4(decode(texelFetch(uSrc, ivec2(gl_FragCoord.xy), 0).rgb), 1.0);
}
)";

const char *kDown = R"(
uniform sampler2D uSrc;
uniform vec2 uSrcTexel;
uniform vec3 uBoost;   // log2 clip, ramp stops, gain at the clip (first level only; gain 1 = off)
vec3 tap(vec2 c) {
    vec3 v = texture(uSrc, c * uSrcTexel).rgb;
    float peak = max(v.r, max(v.g, v.b));
    float t = clamp((log2(max(peak, 1e-6)) - (uBoost.x - uBoost.y)) / uBoost.y, 0.0, 1.0);
    return v * (1.0 + (uBoost.z - 1.0) * t);
}
void main() {
    // Output texel x is centred at source coordinate 2x + 1 (texel edges at integers).
    vec2 c = gl_FragCoord.xy * 2.0;
    vec3 a = tap(c) * 0.125;
    a += (tap(c + vec2(-1.0, -1.0)) + tap(c + vec2(1.0, -1.0)) + tap(c + vec2(-1.0, 1.0)) + tap(c + vec2(1.0, 1.0))) * 0.125;
    a += (tap(c + vec2(-2.0, -2.0)) + tap(c + vec2(2.0, -2.0)) + tap(c + vec2(-2.0, 2.0)) + tap(c + vec2(2.0, 2.0))) * 0.03125;
    a += (tap(c + vec2(-2.0, 0.0)) + tap(c + vec2(2.0, 0.0)) + tap(c + vec2(0.0, -2.0)) + tap(c + vec2(0.0, 2.0))) * 0.0625;
    fragColor = vec4(a, 1.0);
}
)";

const char *kUp = R"(
uniform sampler2D uLevel;
uniform sampler2D uCoarser;
uniform vec2 uCoarserTexel;
uniform vec3 uWeight;
uniform int uHasCoarser;
void main() {
    vec3 u = uWeight * texelFetch(uLevel, ivec2(gl_FragCoord.xy), 0).rgb;
    if (uHasCoarser == 1) u += tentUp(uCoarser, uCoarserTexel);
    fragColor = vec4(u, 1.0);
}
)";

const char *kComposite = R"(
uniform sampler2D uLinear;
uniform sampler2D uUp1;
uniform vec2 uUp1Texel;
uniform vec3 uCore;
uniform vec3 uTransmission;
uniform float uShoulder;   // knee
uniform float uTop;
uniform sampler2D uGate;   // pyramid level averaging the source neighbourhood
uniform vec2 uFullTexel;
uniform vec3 uSource;      // log2 clip, gate stops, core gain at the clip (1 = off)
void main() {
    float k = 1.0;
    if (uSource.z > 1.0) {
        vec3 m = texture(uGate, gl_FragCoord.xy * uFullTexel).rgb;
        float t = clamp((log2(max(max(m.r, max(m.g, m.b)), 1e-6)) - (uSource.x - uSource.y)) / uSource.y, 0.0, 1.0);
        k = 1.0 + (uSource.z - 1.0) * t;
    }
    vec3 acc = (uCore * k * texelFetch(uLinear, ivec2(gl_FragCoord.xy), 0).rgb + tentUp(uUp1, uUp1Texel)) / uTransmission;
    float peak = max(acc.r, max(acc.g, acc.b));
    float comp = peak <= uShoulder ? peak : uShoulder + (uTop - uShoulder) * tanh((peak - uShoulder) / (uTop - uShoulder));
    acc *= comp / max(peak, 1e-6);
    fragColor = vec4(encode(acc), 1.0);
}
)";

GLuint compile(GLenum type, const char *const *parts, int count) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, count, parts, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetShaderInfoLog(s, sizeof log, nullptr, log);
        __android_log_print(ANDROID_LOG_ERROR, TAG, "shader: %s", log);
    }
    return s;
}

GLuint program(const char *fragment) {
    GLuint vs = compile(GL_VERTEX_SHADER, &kVertex, 1);
    const char *parts[] = {kCommon, fragment};
    GLuint fs = compile(GL_FRAGMENT_SHADER, parts, 2);
    GLuint p = glCreateProgram();
    glAttachShader(p, vs);
    glAttachShader(p, fs);
    glLinkProgram(p);
    glDeleteShader(vs);
    glDeleteShader(fs);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetProgramInfoLog(p, sizeof log, nullptr, log);
        __android_log_print(ANDROID_LOG_ERROR, TAG, "program: %s", log);
        glDeleteProgram(p);
        return 0;
    }
    return p;
}

struct Target {
    GLuint tex = 0;
    int w = 0, h = 0;
};

struct GlPipeline {
    GLuint linearize = 0, down = 0, up = 0, composite = 0, vao = 0, fbo = 0, curve = 0;
    int w = 0, h = 0;
    Target l0;
    std::vector<Target> levels, ups;  // levels[i] = L_i+1, ups[i] = U_i+1

    bool ready() const { return linearize && down && up && composite; }
};

Target makeTarget(int w, int h) {
    Target t{0, w, h};
    glGenTextures(1, &t.tex);
    glBindTexture(GL_TEXTURE_2D, t.tex);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA16F, w, h);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    return t;
}

void releaseTargets(GlPipeline &p) {
    auto drop = [](Target &t) { if (t.tex) glDeleteTextures(1, &t.tex); t = Target{}; };
    drop(p.l0);
    for (auto &t : p.levels) drop(t);
    for (auto &t : p.ups) drop(t);
    p.levels.clear();
    p.ups.clear();
}

void sizeTargets(GlPipeline &p, int w, int h) {
    if (p.w == w && p.h == h) return;
    releaseTargets(p);
    p.w = w;
    p.h = h;
    p.l0 = makeTarget(w, h);
    int lw = w, lh = h;
    while (int(p.levels.size()) < kSoftLevels - 1 && std::min(lw, lh) >= 4) {
        lw /= 2;
        lh /= 2;
        p.levels.push_back(makeTarget(lw, lh));
        p.ups.push_back(makeTarget(lw, lh));
    }
}

std::map<EGLContext, GlPipeline> gPipelines;

// GL state Meishe may rely on after the call.
struct SavedGl {
    GLint fbo, program, vao, active, tex0, tex1, tex2, tex3, sampler0, sampler1, sampler2, sampler3, viewport[4];
    GLboolean blend, depth, scissor, stencil, cull;
    void save() {
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fbo);
        glGetIntegerv(GL_CURRENT_PROGRAM, &program);
        glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
        glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
        glActiveTexture(GL_TEXTURE0);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex0);
        glGetIntegerv(GL_SAMPLER_BINDING, &sampler0);
        glActiveTexture(GL_TEXTURE1);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex1);
        glGetIntegerv(GL_SAMPLER_BINDING, &sampler1);
        glActiveTexture(GL_TEXTURE2);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex2);
        glGetIntegerv(GL_SAMPLER_BINDING, &sampler2);
        glActiveTexture(GL_TEXTURE3);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex3);
        glGetIntegerv(GL_SAMPLER_BINDING, &sampler3);
        glGetIntegerv(GL_VIEWPORT, viewport);
        blend = glIsEnabled(GL_BLEND);
        depth = glIsEnabled(GL_DEPTH_TEST);
        scissor = glIsEnabled(GL_SCISSOR_TEST);
        stencil = glIsEnabled(GL_STENCIL_TEST);
        cull = glIsEnabled(GL_CULL_FACE);
    }
    void restore() const {
        auto set = [](GLenum cap, GLboolean on) { on ? glEnable(cap) : glDisable(cap); };
        set(GL_BLEND, blend);
        set(GL_DEPTH_TEST, depth);
        set(GL_SCISSOR_TEST, scissor);
        set(GL_STENCIL_TEST, stencil);
        set(GL_CULL_FACE, cull);
        glViewport(viewport[0], viewport[1], viewport[2], viewport[3]);
        glActiveTexture(GL_TEXTURE3);
        glBindTexture(GL_TEXTURE_2D, tex3);
        glBindSampler(3, sampler3);
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_2D, tex2);
        glBindSampler(2, sampler2);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, tex1);
        glBindSampler(1, sampler1);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, tex0);
        glBindSampler(0, sampler0);
        glActiveTexture(active);
        glBindVertexArray(vao);
        glUseProgram(program);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    }
};

void drawInto(GlPipeline &p, GLuint tex, int w, int h) {
    glBindFramebuffer(GL_FRAMEBUFFER, p.fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    glViewport(0, 0, w, h);
    glDrawArrays(GL_TRIANGLES, 0, 3);
}

void bindTex(int unit, GLuint tex) {
    glActiveTexture(GL_TEXTURE0 + unit);
    glBindTexture(GL_TEXTURE_2D, tex);
}

void scatterTexture(GLuint outTex, int w, int h, const SoftFilter &filter, Transfer tr) {
    EGLContext ctx = eglGetCurrentContext();
    if (ctx == EGL_NO_CONTEXT) return;
    SavedGl saved;
    saved.save();
    GlPipeline &p = gPipelines[ctx];
    if (!p.vao) {
        p.linearize = program(kLinearize);
        p.down = program(kDown);
        p.up = program(kUp);
        p.composite = program(kComposite);
        glGenVertexArrays(1, &p.vao);
        glGenFramebuffers(1, &p.fbo);
        std::vector<float> rows(kSoftHlgToScene, kSoftHlgToScene + kSoftCurveN);
        rows.insert(rows.end(), kSoftSceneToHlg, kSoftSceneToHlg + kSoftCurveN);
        glGenTextures(1, &p.curve);
        glBindTexture(GL_TEXTURE_2D, p.curve);
        glTexStorage2D(GL_TEXTURE_2D, 1, GL_R32F, kSoftCurveN, 2);
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, kSoftCurveN, 2, GL_RED, GL_FLOAT, rows.data());
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    }
    if (!p.ready()) {
        saved.restore();
        return;
    }
    sizeTargets(p, w, h);
    glDisable(GL_BLEND);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_STENCIL_TEST);
    glDisable(GL_CULL_FACE);
    glBindSampler(0, 0);
    glBindSampler(1, 0);
    glBindSampler(2, 0);
    glBindSampler(3, 0);
    glBindVertexArray(p.vao);
    int hlg = tr == kHlg ? 1 : 0;

    glUseProgram(p.linearize);
    glUniform1i(glGetUniformLocation(p.linearize, "uHlg"), hlg);
    glUniform1i(glGetUniformLocation(p.linearize, "uSrc"), 0);
    glUniform1i(glGetUniformLocation(p.linearize, "uCurve"), 2);
    glUniform3f(glGetUniformLocation(p.linearize, "uCurveLimits"), kSoftLog2SceneMin, kSoftLog2SceneMax, kSoftSceneToHlg[0]);
    bindTex(2, p.curve);
    bindTex(0, outTex);
    drawInto(p, p.l0.tex, w, h);

    glUseProgram(p.down);
    glUniform1i(glGetUniformLocation(p.down, "uSrc"), 0);
    const Target *src = &p.l0;
    for (auto &level : p.levels) {
        glUniform3f(glGetUniformLocation(p.down, "uBoost"), std::log2(topOf(tr)), boostStops(tr), src == &p.l0 ? sourceGain(filter) : 1.0f);
        glUniform2f(glGetUniformLocation(p.down, "uSrcTexel"), 1.0f / src->w, 1.0f / src->h);
        bindTex(0, src->tex);
        drawInto(p, level.tex, level.w, level.h);
        src = &level;
    }

    int built = int(p.levels.size());
    LevelWeights lw = levelWeights(filter, std::hypot(float(w), float(h)), built);
    glUseProgram(p.up);
    glUniform1i(glGetUniformLocation(p.up, "uLevel"), 0);
    glUniform1i(glGetUniformLocation(p.up, "uCoarser"), 1);
    for (int i = built; i >= 1; i--) {
        glUniform3f(glGetUniformLocation(p.up, "uWeight"), lw.w[0][i], lw.w[1][i], lw.w[2][i]);
        glUniform1i(glGetUniformLocation(p.up, "uHasCoarser"), i < built ? 1 : 0);
        bindTex(0, p.levels[i - 1].tex);
        if (i < built) {
            const Target &coarser = p.ups[i];
            glUniform2f(glGetUniformLocation(p.up, "uCoarserTexel"), 1.0f / coarser.w, 1.0f / coarser.h);
            bindTex(1, coarser.tex);
        }
        drawInto(p, p.ups[i - 1].tex, p.ups[i - 1].w, p.ups[i - 1].h);
    }

    glUseProgram(p.composite);
    glUniform1i(glGetUniformLocation(p.composite, "uHlg"), hlg);
    glUniform1i(glGetUniformLocation(p.composite, "uLinear"), 0);
    glUniform1i(glGetUniformLocation(p.composite, "uUp1"), 1);
    glUniform2f(glGetUniformLocation(p.composite, "uUp1Texel"), 1.0f / p.ups[0].w, 1.0f / p.ups[0].h);
    glUniform3f(glGetUniformLocation(p.composite, "uCore"), lw.core[0] + lw.w[0][0], lw.core[1] + lw.w[1][0], lw.core[2] + lw.w[2][0]);
    glUniform3f(glGetUniformLocation(p.composite, "uTransmission"), lw.transmission[0], lw.transmission[1], lw.transmission[2]);
    glUniform1f(glGetUniformLocation(p.composite, "uShoulder"), kShoulder * topOf(tr));
    glUniform1f(glGetUniformLocation(p.composite, "uTop"), topOf(tr));
    glUniform1i(glGetUniformLocation(p.composite, "uCurve"), 2);
    glUniform3f(glGetUniformLocation(p.composite, "uCurveLimits"), kSoftLog2SceneMin, kSoftLog2SceneMax, kSoftSceneToHlg[0]);
    float gain = sourceGain(filter);
    int gateLevel = sourceLevel(filter, std::hypot(float(w), float(h)), built);
    glUniform1i(glGetUniformLocation(p.composite, "uGate"), 3);
    glUniform2f(glGetUniformLocation(p.composite, "uFullTexel"), 1.0f / w, 1.0f / h);
    glUniform3f(glGetUniformLocation(p.composite, "uSource"), std::log2(topOf(tr)), kSourceStops, gain);
    bindTex(3, p.levels[gateLevel - 1].tex);
    bindTex(0, p.l0.tex);
    bindTex(1, p.ups[0].tex);
    drawInto(p, outTex, w, h);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);

    saved.restore();
}

// ---- hooks -----------------------------------------------------------------------------------

// SMsGPUTextureInfo: texture id, width, height, -, format, primaries, transfer (2 = HLG), -.
struct GpuTextureInfo {
    uint32_t texture, width, height, reserved, format, primaries, transfer, extra;
};
// SMsHardwareBufferInfo: buffer, primaries, transfer (2 = HLG), YUV matrix, YUV range.
struct HardwareBufferInfo {
    AHardwareBuffer *buffer;
    int32_t primaries, transfer, matrix, range;
};

bool transferOf(uint32_t transfer, Transfer &out) {
    if (transfer == 2) { out = kHlg; return true; }
    if (transfer == 0) { out = kSrgb; return true; }
    return false;  // PQ: left to the stock soft light
}

using RenderHdrTexture = int (*)(void *, void *, const GpuTextureInfo *, unsigned, GpuTextureInfo *, const void *, const void *, int);
RenderHdrTexture origHdrTexture;
int hookHdrTexture(void *core, void *effect, const GpuTextureInfo *in, unsigned n, GpuTextureInfo *out, const void *param,
                   const void *metadata, int flags) {
    const SoftFilter *filter = filterFor(param);
    Transfer tr;
    if (!filter || !out || !transferOf(out->transfer, tr)) return origHdrTexture(core, effect, in, n, out, param, metadata, flags);
    int ret;
    {
        StockSoftOff off(param);
        ret = origHdrTexture(core, effect, in, n, out, param, metadata, flags);
    }
    if (ret & 1) scatterTexture(out->texture, int(out->width), int(out->height), *filter, tr);
    return ret;
}

using RenderHardwareBuffer = int (*)(void *, void *, const HardwareBufferInfo *, unsigned, const HardwareBufferInfo *, const void *,
                                     const void *, int);
RenderHardwareBuffer origHardwareBuffer;
int hookHardwareBuffer(void *core, void *effect, const HardwareBufferInfo *in, unsigned n, const HardwareBufferInfo *out,
                       const void *param, const void *metadata, int flags) {
    const SoftFilter *filter = filterFor(param);
    Transfer tr;
    gCaptureSoft.store(filter != nullptr);
    if (!filter || !out || !out->buffer || !transferOf(uint32_t(out->transfer), tr)) {
        return origHardwareBuffer(core, effect, in, n, out, param, metadata, flags);
    }
    int ret;
    {
        StockSoftOff off(param);
        ret = origHardwareBuffer(core, effect, in, n, out, param, metadata, flags);
    }
    if (ret & 1) {
        AHardwareBuffer_Desc desc{};
        AHardwareBuffer_describe(out->buffer, &desc);
        __android_log_print(ANDROID_LOG_INFO, TAG, "capture %ux%u %s, focal %.0f mm", desc.width, desc.height,
                            filter == &kHdf ? "HDF" : filter == &kBlackMist ? "black mist" : "white mist", double(gFocalMm.load()));
        auto start = std::chrono::steady_clock::now();
        scatterP010(out->buffer, *filter, tr, yuvCoding(out->matrix, out->range));
        __android_log_print(ANDROID_LOG_INFO, TAG, "capture took %lld ms", (long long)std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::steady_clock::now() - start).count());
    }
    return ret;
}

// ---- capture: HDRTransform's local fusion off -------------------------------------------------
//
// The quick image and the preview render the HLG frame through the master tone curve alone; the
// main image goes through HDRTransform processMasterV2, whose TmcDownTransEF::odtFusionPro (at 1K)
// takes the base from the tone-curve rendition and the detail of two pyramid levels from the
// linear rendition. That adds about 8 % local contrast at 0.03-0.5 degree over the whole frame,
// the scales the soft light lowers. With 关闭对比度增强 on and a replaced soft light the fused image is the tone-curve
// rendition itself, so the main image renders as the preview does.
//
// static odtFusionPro(CLBuffer &bright, CLBuffer &dark, CLBuffer &out, bool, bool): bright feeds
// buildPyramid, dark buildPyramidLaplacian.

using OdtFusionPro = int (*)(void *bright, void *dark, void *out, bool, bool);
using CopyTo = int (*)(const void *self, void *dst, const bool &blocking);
// Both HDRTransform libraries carry their own copy; the main image uses the Camera one.
template <int Lib>
struct FusionHook {
    static OdtFusionPro orig;
    static CopyTo copyTo;
    static int call(void *bright, void *dark, void *out, bool a, bool b) {
        if (!gNoLocalContrast.load() || !gCaptureSoft.load() || !copyTo) return orig(bright, dark, out, a, b);
        bool blocking = true;
        int ret = copyTo(bright, out, blocking);
        __android_log_print(ANDROID_LOG_INFO, TAG, "capture: HDRTransform local fusion off (lib %d, copy %d)", Lib, ret);
        return 0;
    }
    static void install(HookFunction hook, const char *name, void *handle) {
        copyTo = reinterpret_cast<CopyTo>(dlsym(handle, "_ZNK9framework3ocl8CLBuffer6copyToERS1_RKb"));
        hookExport(hook, handle, "_ZN14TmcDownTransEF12odtFusionProERN9framework3ocl8CLBufferES3_S3_bb",
                   reinterpret_cast<void *>(&call), reinterpret_cast<void **>(&orig), TAG);
        __android_log_print(ANDROID_LOG_INFO, TAG, "odtFusionPro hooked in %s (copyTo %p)", name, reinterpret_cast<void *>(copyTo));
    }
};
template <int Lib> OdtFusionPro FusionHook<Lib>::orig = nullptr;
template <int Lib> CopyTo FusionHook<Lib>::copyTo = nullptr;

}  // namespace

void onLibraryLoadedForSoftLight(HookFunction hook, const char *name, void *handle) {
    static bool fusionCamera = false, fusionQuick = false;
    if (!fusionCamera && std::strstr(name, "libOPAlgoCamHDRTransformCamera.so")) {
        fusionCamera = true;
        FusionHook<0>::install(hook, name, handle);
    } else if (!fusionQuick && std::strstr(name, "libOPAlgoCamHDRTransformQuick.so")) {
        fusionQuick = true;
        FusionHook<1>::install(hook, name, handle);
    }
    // The camera and libAlgoInterface both dlopen the library; the exports are hooked once.
    static bool hooked = false;
    if (hooked || !std::strstr(name, "libmsnativefilter.so")) return;
    hooked = true;
    hookExport(hook, handle, "MsRenderHDRTexture", reinterpret_cast<void *>(hookHdrTexture),
               reinterpret_cast<void **>(&origHdrTexture), TAG);
    hookExport(hook, handle, "MsRenderHardwareBuffer", reinterpret_cast<void *>(hookHardwareBuffer),
               reinterpret_cast<void **>(&origHardwareBuffer), TAG);
}

extern "C" JNIEXPORT void JNICALL Java_local_jiege_hook_softlight_SoftLight_nativeSetFocal(JNIEnv *, jclass, jfloat millimetres) {
    if (std::fabs(gFocalMm.exchange(millimetres) - millimetres) > 0.5f) {
        __android_log_print(ANDROID_LOG_INFO, TAG, "focal %.1f mm", double(millimetres));
    }
}

extern "C" JNIEXPORT void JNICALL Java_local_jiege_hook_softlight_SoftLight_nativeSetMasterMode(JNIEnv *, jclass, jboolean master) {
    if (gMasterMode.exchange(master) != bool(master)) __android_log_print(ANDROID_LOG_INFO, TAG, "master mode %s", master ? "on" : "off");
}

extern "C" JNIEXPORT void JNICALL Java_local_jiege_hook_softlight_SoftLight_nativeSetNoLocalContrast(JNIEnv *, jclass, jboolean on) {
    gNoLocalContrast.store(on);
}

extern "C" JNIEXPORT void JNICALL Java_local_jiege_hook_softlight_SoftLight_nativeSetLevels(JNIEnv *, jclass, jboolean weak,
                                                                                           jboolean medium, jboolean strong) {
    // ProMist types: weak (柔美) 1, medium (朦胧) 0, strong (梦幻) 2.
    gLevels.store((weak ? 1 << 1 : 0) | (medium ? 1 << 0 : 0) | (strong ? 1 << 2 : 0));
}
