// Master LMT baker. Mirrors tools/mastercolor/master_lmt.py stage by stage; see that file for the
// node evidence behind each stage. Platform independent so it can be checked on a host.
#include "master_core.h"
#include "master_canon.h"
#include "master_dt.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <thread>

namespace mastercolor {
namespace {

using Mat3 = std::array<double, 9>;
using Vec3 = std::array<double, 3>;

Mat3 mul(const Mat3 &a, const Mat3 &b) {
    Mat3 r{};
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 3; j++)
            r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
    return r;
}

Mat3 inv(const Mat3 &m) {
    double a = m[0], b = m[1], c = m[2], d = m[3], e = m[4], f = m[5], g = m[6], h = m[7], i = m[8];
    double A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g;
    double det = a * A + b * B + c * C;
    return {A / det, -(b * i - c * h) / det, (b * f - c * e) / det,
            B / det, (a * i - c * g) / det, -(a * f - c * d) / det,
            C / det, -(a * h - b * g) / det, (a * e - b * d) / det};
}

Vec3 xform(const Mat3 &m, const Vec3 &v) {
    return {m[0] * v[0] + m[1] * v[1] + m[2] * v[2], m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
            m[6] * v[0] + m[7] * v[1] + m[8] * v[2]};
}

Mat3 diag(double a, double b, double c) { return {a, 0, 0, 0, b, 0, 0, 0, c}; }

const Mat3 kP3ToXyz = {0.4865709, 0.2656677, 0.1982173, 0.2289746, 0.6917385, 0.0792869,
                       0.0000000, 0.0451134, 1.0439444};
const Mat3 kBradford = {0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296};
const Vec3 kD65 = {0.95047, 1.0, 1.08883};
const Vec3 kD50 = {0.96422, 1.0, 0.82521};
const Mat3 kHncsToXyzD50 = {0.79767, 0.13519, 0.03134, 0.28804, 0.71188, 0.00009, 0.0, 0.0, 0.82491};
constexpr double kKr = 0.28804, kKg = 0.71188, kKb = 0.00009;
const Mat3 kRgbToYcc = {kKr, kKg, kKb,
                        -kKr / (2 * (1 - kKb)), -kKg / (2 * (1 - kKb)), 0.5,
                        0.5, -kKg / (2 * (1 - kKr)), -kKb / (2 * (1 - kKr))};
const Vec3 kP3Luma = {0.2289746, 0.6917385, 0.0792869};
const Vec3 kW601 = {0.299, 0.587, 0.114};

Mat3 cat(const Vec3 &src, const Vec3 &dst) {
    auto s = xform(kBradford, src), d = xform(kBradford, dst);
    return mul(mul(inv(kBradford), diag(d[0] / s[0], d[1] / s[1], d[2] / s[2])), kBradford);
}

// Scene white: Planckian locus below 4000 K, CIE daylight locus from 4000 K (hncs_engine.white_xyz).
Vec3 whiteXyz(double t) {
    double x, y;
    if (t < 4000) {
        x = -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910;
        y = t < 2222 ? -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
                     : -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867;
    } else {
        x = t <= 7000 ? -4.6070e9 / (t * t * t) + 2.9678e6 / (t * t) + 0.09911e3 / t + 0.244063
                      : -2.0064e9 / (t * t * t) + 1.9018e6 / (t * t) + 0.24748e3 / t + 0.237040;
        y = -3.0 * x * x + 2.87 * x - 0.275;
    }
    return {x / y, 1.0, (1 - x - y) / y};
}

struct Anchor {
    float temperature;
    std::vector<float> values;
};

struct EngineData {
    float k = 0, greyScene = 0;
    int gw = 0, gh = 0;
    float cbStart = 0, crStart = 0, divFactor = 0;
    float matrixMax = 0, tableMax = 0;
    std::vector<Anchor> matrices, tables;
    Mat3 cm{};
    std::vector<float> film, toneCurve, builtin, proproc;
    float greyCode = 0, cap = 0;
    std::vector<float> luxInverse;  // 64^3 x 3, [B][G][R][3]: luxIndex > 280 encoding inverse at the nodes
};

std::mutex engineMutex;
EngineData engineData;
bool engineOk = false;
std::string engineDir;

template <typename T>
bool readValue(const std::vector<uint8_t> &blob, size_t &at, T &out) {
    if (at + sizeof(T) > blob.size()) return false;
    std::memcpy(&out, blob.data() + at, sizeof(T));
    at += sizeof(T);
    return true;
}

bool readFloats(const std::vector<uint8_t> &blob, size_t &at, size_t count, std::vector<float> &out) {
    if (at + count * 4 > blob.size()) return false;
    out.resize(count);
    std::memcpy(out.data(), blob.data() + at, count * 4);
    at += count * 4;
    return true;
}

bool readMat(const std::vector<uint8_t> &blob, size_t &at, Mat3 &m) {
    std::vector<float> v;
    if (!readFloats(blob, at, 9, v)) return false;
    for (int i = 0; i < 9; i++) m[i] = v[i];
    return true;
}

std::vector<double> interpolate(const std::vector<Anchor> &anchors, double t) {
    std::vector<const Anchor *> sorted;
    for (auto &a : anchors) sorted.push_back(&a);
    std::sort(sorted.begin(), sorted.end(), [](auto *a, auto *b) { return a->temperature < b->temperature; });
    auto pick = [](const Anchor *a) { return std::vector<double>(a->values.begin(), a->values.end()); };
    if (t <= sorted.front()->temperature) return pick(sorted.front());
    if (t >= sorted.back()->temperature) return pick(sorted.back());
    for (size_t i = 0; i + 1 < sorted.size(); i++) {
        double t0 = sorted[i]->temperature, t1 = sorted[i + 1]->temperature;
        if (t >= t0 && t <= t1) {
            double w = (t - t0) / (t1 - t0);
            std::vector<double> r(sorted[i]->values.size());
            for (size_t j = 0; j < r.size(); j++) r[j] = sorted[i]->values[j] * (1 - w) + sorted[i + 1]->values[j] * w;
            return r;
        }
    }
    return pick(sorted.back());
}

// ---------------------------------------------------------------- HLG / sRGB
constexpr double kA = 0.17883277, kB = 0.28466892, kC = 0.55991073;
double hlgOetf(double e) {
    e = std::max(e, 0.0);
    return e <= 1.0 / 12.0 ? std::sqrt(3.0 * e) : kA * std::log(std::max(12.0 * e - kB, 1e-12)) + kC;
}
double srgbEncode(double x) {
    x = std::max(x, 0.0);
    return x < 0.0030412825601275209 ? 12.92 * x : 1.0550107189475866 * std::pow(x, 1 / 2.4) - 0.0550107189475866;
}

// ---------------------------------------------------------------- LMT input encodings
// np.interp(code, table, linspace(0, 1, n)) for a non-decreasing table.
double invertTable(const float *t, int n, double code) {
    code = std::min(std::max(code, double(t[0])), double(t[n - 1]));
    int hi = int(std::upper_bound(t, t + n, float(code)) - t);
    if (hi >= n) return 1.0;
    int lo = std::max(hi - 1, 0);
    double span = double(t[hi]) - t[lo];
    double f = span > 0 ? (code - t[lo]) / span : 0.0;
    return (lo + f * (hi - lo)) / double(n - 1);
}

double lookup(const std::vector<float> &t, double lin) {
    int i = int(std::min(std::max(lin, 0.0), 1.0) * 65535.0);
    return t[std::min(std::max(i, 0), 65535)];
}

// luxIndex > 280: trilinear lookup of the frame-independent inverse of the blended proproc encoding
// at the LMT nodes (tools/mastercolor/lux_blend_inverse.py). At a node this is the node's own solution.
Vec3 luxInverse(const EngineData &d, const Vec3 &code) {
    constexpr int n = kLutSize;
    double p[3];
    int i0[3];
    double f[3];
    for (int c = 0; c < 3; c++) {
        p[c] = std::min(std::max(code[c], 0.0), 1.0) * (n - 1);
        i0[c] = std::min(int(std::floor(p[c])), n - 2);
        f[c] = p[c] - i0[c];
    }
    Vec3 out = {0, 0, 0};
    for (int db = 0; db < 2; db++)
        for (int dg = 0; dg < 2; dg++)
            for (int dr = 0; dr < 2; dr++) {
                double w = (dr ? f[0] : 1 - f[0]) * (dg ? f[1] : 1 - f[1]) * (db ? f[2] : 1 - f[2]);
                size_t at = ((size_t(i0[2] + db) * n + (i0[1] + dg)) * n + (i0[0] + dr)) * 3;
                for (int c = 0; c < 3; c++) out[c] += w * d.luxInverse[at + c];
            }
    return out;
}

Vec3 decode(const EngineData &d, const Key &key, const float *ipe, const Vec3 &code) {
    Vec3 lin;
    switch (key.path) {
        case Path::Main:
        case Path::Preview:
            // Preview shares the stock LMTLut with capture, so its codes carry the capture encoding.
            // (com.oplus.ipe.gamma.info acts on ISP tone-mapped data: decoded as linear it spans
            // ~5 stops against ~11 for the builtin table, which rendered the preview flat.)
            if (key.path == Path::Main && key.luxBlend) return luxInverse(d, code);
            for (int c = 0; c < 3; c++) lin[c] = invertTable(d.builtin.data(), 65536, std::min(code[c], double(d.cap)));
            break;
        case Path::Thumbnail:
            for (int c = 0; c < 3; c++) lin[c] = invertTable(d.proproc.data(), 65536, code[c]);
            break;
    }
    return lin;
}

// ---------------------------------------------------------------- HNCS engine
struct Plan {
    const EngineData *d;
    float p3ToHncs[9], hncsToP3[9], rgbToYcc[9], yccToRgb[9];
    std::vector<float> table;
    const float *film = nullptr;
};

inline void mat(const float *m, const float *v, float *o) {
    o[0] = m[0] * v[0] + m[1] * v[1] + m[2] * v[2];
    o[1] = m[3] * v[0] + m[4] * v[1] + m[5] * v[2];
    o[2] = m[6] * v[0] + m[7] * v[1] + m[8] * v[2];
}

void render(const Plan &p, const float scene[3], float out[3]) {
    const EngineData &d = *p.d;
    float h[3], ycc[3];
    mat(p.p3ToHncs, scene, h);
    mat(p.rgbToYcc, h, ycc);
    if (ycc[0] > 1e-6f) {
        float px = std::min(std::max(d.divFactor * ycc[1] / ycc[0] - d.cbStart, 0.0f), float(d.gw - 1));
        float py = std::min(std::max(d.divFactor * ycc[2] / ycc[0] - d.crStart, 0.0f), float(d.gh - 1));
        int x0 = std::min(std::max(int(std::floor(px)), 0), d.gw - 2);
        int y0 = std::min(std::max(int(std::floor(py)), 0), d.gh - 2);
        float fx = px - x0, fy = py - y0;
        const float *t = p.table.data();
        auto at = [&](int y, int x, int c) { return t[(size_t(y) * d.gw + x) * 2 + c]; };
        float mapped[2];
        for (int c = 0; c < 2; c++) {
            float r0 = at(y0, x0, c) * (1 - fx) + at(y0, x0 + 1, c) * fx;
            float r1 = at(y0 + 1, x0, c) * (1 - fx) + at(y0 + 1, x0 + 1, c) * fx;
            mapped[c] = r0 * (1 - fy) + r1 * fy;
        }
        float yc[3] = {ycc[0], mapped[0] * ycc[0] / d.divFactor, mapped[1] * ycc[0] / d.divFactor};
        mat(p.yccToRgb, yc, h);
    }
    float lin[3];
    for (int c = 0; c < 3; c++) {
        float v = std::max(h[c], 0.0f) * 65536.0f;
        int index = std::min(std::max(int(std::floor(v)), 0), 65535);
        lin[c] = std::pow(p.film[index], 2.2f);
    }
    mat(p.hncsToP3, lin, out);
    for (int c = 0; c < 3; c++) out[c] = std::min(std::max(out[c], 0.0f), 1.0f);
}

void makePlan(const EngineData &d, double cct, Plan &p) {
    p.d = &d;
    p.film = d.film.data();
    double tmat = std::floor(std::min(std::max(cct, 2000.0), double(d.matrixMax)));
    double ttab = std::floor(std::min(std::max(cct, 2000.0), double(d.tableMax)));
    std::vector<double> m = interpolate(d.matrices, tmat);
    std::vector<double> t = interpolate(d.tables, ttab);
    Mat3 camToXyzD50;
    for (int i = 0; i < 9; i++) camToXyzD50[i] = m[i];
    Vec3 white = whiteXyz(cct);
    Vec3 camWhite = xform(d.cm, white);
    Mat3 p3ToCamWb = mul(mul(diag(1 / camWhite[0], 1 / camWhite[1], 1 / camWhite[2]), d.cm),
                         mul(cat(kD65, white), kP3ToXyz));
    Mat3 p3ToHncs = mul(mul(inv(kHncsToXyzD50), camToXyzD50), p3ToCamWb);
    Mat3 hncsToP3 = mul(mul(inv(kP3ToXyz), cat(kD50, kD65)), kHncsToXyzD50);
    Mat3 yccToRgb = inv(kRgbToYcc);
    for (int i = 0; i < 9; i++) {
        p.p3ToHncs[i] = float(p3ToHncs[i]);
        p.hncsToP3[i] = float(hncsToP3[i]);
        p.rgbToYcc[i] = float(kRgbToYcc[i]);
        p.yccToRgb[i] = float(yccToRgb[i]);
    }
    p.table.assign(t.begin(), t.end());
}

// ---------------------------------------------------------------- colour + output
// Display-linear P3 -> LMT output through the HDRTransform master model (toneCurve luma, HLG ratio).
void invertOutput(const EngineData &d, const float t[3], float out[3]) {
    double T[3], target = 0;
    for (int c = 0; c < 3; c++) {
        T[c] = std::min(std::max(double(t[c]), 0.0), 1.0);
        target += kW601[c] * srgbEncode(T[c]);
    }
    double lo = 0, hi = 8;
    // Twenty-four bisections resolve the scale below float precision in the output LUT.
    for (int it = 0; it < 24; it++) {
        double s = (lo + hi) / 2, y = 0;
        for (int c = 0; c < 3; c++) {
            double h = std::min(std::max(hlgOetf(s * T[c]), 0.0), 1.0) * 1023;
            int index = int(h);                    // lround for h >= 0, without the library call
            if (h - index >= 0.5) index++;
            y += kW601[c] * d.toneCurve[index];
        }
        if (y < target) lo = s; else hi = s;
    }
    double s = (lo + hi) / 2;
    for (int c = 0; c < 3; c++) out[c] = float(std::min(std::max(hlgOetf(s * T[c]), 0.0), 1.0));
}

// ---------------------------------------------------------------- Lumix / Spektrafilm (tools/mastercolor/looks.py)
const Mat3 kProPhotoToXyz = {0.7976749, 0.1351917, 0.0313534, 0.2880402, 0.7118741, 0.0000857,
                             0.0, 0.0, 0.8252100};
// From the BT.2020 primaries and D65 white (as ColorSpace.BT2020 / DngSdkColorSpec).
const Mat3 kBt2020ToXyz = {0.6369580483, 0.1446169036, 0.1688809752, 0.2627002120, 0.6779980715, 0.0593017165,
                           0.0000000000, 0.0280726930, 1.0609850577};
const Mat3 kSrgbToXyz = {0.4124564, 0.3575761, 0.1804375, 0.2126729, 0.7151522, 0.0721750,
                         0.0193339, 0.1191920, 0.9503041};

struct LookData {
    int kind = 0;  // 1 Lumix, 2 film, 3 darktable sigmoid, 4 AgX, 5 darktable filmic, 7 Canon
    // Lumix
    float grey = 0, gain = 1, clip = 1, il1 = 0, il2 = 0;
    Mat3 cm1{}, cm2{};
    std::vector<float> curve, low, high;  // 2048; 33^3 x 3 [B][G][R][3]
    // film
    bool hasPrint = false;
    float inScale = 0, printGain = 0;
    std::vector<float> film, print;       // 65^3 x 3 [B][G][R][3]
    std::vector<Anchor> hncsTables;  // alternate HNCS render intent
    // AgX / filmic / sigmoid defaults
    dt::AgxParams agx;
    float filmicBlack = -7.65f, filmicWhite = 4.56f;
    dt::SigmoidParams sigmoid;
    // Canon: engine EV, il1 / il2 / cm1 / cm2 as Lumix (EOS R5 calibration), recipe + ICC
    float engineEv = 0;
    canon::Style canon;
    std::vector<int32_t> leicaMatrices;
    std::vector<float> firmware;
    // Basic (kind 12): transfer curve type (0 pass-through, 1 Rec.709, 2 power gamma) and its default gamma
    uint32_t basicType = 0;
    float basicGamma = 2.4f;
    std::vector<float> basicCurve;  // type 3: ACR3 tone curve, uniform samples over [0, 1]
    float basicGainEv = 0;
};

bool readInts(const std::vector<uint8_t> &blob, size_t &at, size_t count, std::vector<int32_t> &out) {
    if (at + count * 4 > blob.size()) return false;
    out.resize(count);
    std::memcpy(out.data(), blob.data() + at, count * 4);
    at += count * 4;
    return true;
}

float halfToFloat(uint16_t h) {
    uint32_t sign = uint32_t(h & 0x8000) << 16, exp = (h >> 10) & 0x1f, man = h & 0x3ff, bits;
    if (exp == 0) {
        if (man == 0) {
            bits = sign;
        } else {
            exp = 127 - 15 + 1;
            while (!(man & 0x400)) {
                man <<= 1;
                exp--;
            }
            bits = sign | (exp << 23) | ((man & 0x3ff) << 13);
        }
    } else if (exp == 31) {
        bits = sign | 0x7f800000 | (man << 13);
    } else {
        bits = sign | ((exp + 127 - 15) << 23) | (man << 13);
    }
    float f;
    std::memcpy(&f, &bits, 4);
    return f;
}

bool readHalves(const std::vector<uint8_t> &blob, size_t &at, size_t count, std::vector<float> &out) {
    if (at + count * 2 > blob.size()) return false;
    out.resize(count);
    for (size_t i = 0; i < count; i++) {
        uint16_t v;
        std::memcpy(&v, blob.data() + at + i * 2, 2);
        out[i] = halfToFloat(v);
    }
    at += count * 2;
    return true;
}

bool readUnorm16(const std::vector<uint8_t> &blob, size_t &at, size_t count, std::vector<float> &out) {
    if (at + count * 2 > blob.size()) return false;
    out.resize(count);
    for (size_t i = 0; i < count; i++) {
        uint16_t v;
        std::memcpy(&v, blob.data() + at + i * 2, 2);
        out[i] = v / 65535.0f;
    }
    at += count * 2;
    return true;
}

std::mutex lookMutex;
std::map<std::string, std::shared_ptr<const LookData>> lookCache;

bool validLookName(const std::string &name) {
    if (name.empty() || name.size() > 64) return false;
    for (char c : name)
        if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) return false;
    return true;
}

std::shared_ptr<const LookData> loadLook(const std::string &name) {
    std::lock_guard<std::mutex> lock(lookMutex);
    auto it = lookCache.find(name);
    if (it != lookCache.end()) return it->second;
    if (!validLookName(name)) return nullptr;
    FILE *file = std::fopen((engineDir + "/looks/" + name + ".bin").c_str(), "rb");
    if (!file) return nullptr;
    std::vector<uint8_t> blob;
    uint8_t chunk[65536];
    size_t got;
    while ((got = std::fread(chunk, 1, sizeof(chunk), file)) > 0) blob.insert(blob.end(), chunk, chunk + got);
    std::fclose(file);
    auto d = std::make_shared<LookData>();
    size_t at = 8;
    uint32_t version = 0, kind = 0;
    bool ok = blob.size() >= 16 && std::memcmp(blob.data(), "MCOLLOOK", 8) == 0 && readValue(blob, at, version) &&
              version == 1 && readValue(blob, at, kind);
    constexpr size_t kCube33 = size_t(33) * 33 * 33 * 3, kCube65 = size_t(65) * 65 * 65 * 3;
    if (ok && kind == 10) {
        ok = readValue(blob, at, d->il1) && readValue(blob, at, d->il2) &&
             readMat(blob, at, d->cm1) && readMat(blob, at, d->cm2) &&
             readInts(blob, at, 18, d->leicaMatrices) && at + 2048 == blob.size();
        if (ok) { d->curve.resize(2048); for (int i=0; i<2048; ++i) d->curve[i] = blob[at+i]/255.0f; at += 2048; }
    } else if (ok && kind == 11) {
        ok = readFloats(blob, at, 165 + 17*17*17*3, d->firmware);
    } else if (ok && kind == 1) {
        ok = readValue(blob, at, d->grey) && readValue(blob, at, d->gain) && readValue(blob, at, d->clip) &&
             readValue(blob, at, d->il1) && readValue(blob, at, d->il2) && readMat(blob, at, d->cm1) &&
             readMat(blob, at, d->cm2) && readHalves(blob, at, 2048, d->curve) &&
             readHalves(blob, at, kCube33, d->low) && readHalves(blob, at, kCube33, d->high) && d->grey > 0;
    } else if (ok && kind == 2) {
        uint32_t hasPrint = 0;
        ok = readValue(blob, at, hasPrint) && readValue(blob, at, d->inScale) && readValue(blob, at, d->printGain) &&
             readUnorm16(blob, at, kCube65, d->film) && (!hasPrint || readUnorm16(blob, at, kCube65, d->print));
        d->hasPrint = hasPrint != 0;
    } else if (ok && kind == 9) {
        uint32_t count = 0;
        ok = readUnorm16(blob, at, 65536, d->film) && readValue(blob, at, count) && count >= 2;
        for (uint32_t i = 0; ok && i < count; ++i) {
            Anchor anchor;
            ok = readValue(blob, at, anchor.temperature) &&
                 readFloats(blob, at, size_t(engineData.gw) * engineData.gh * 2, anchor.values);
            d->hncsTables.push_back(std::move(anchor));
        }
    } else if (ok && kind == 8) {
        ok = readValue(blob, at, d->inScale) && readValue(blob, at, d->printGain);
        auto stage = [&](std::vector<float> &values, bool optional) {
            uint32_t length = 0;
            if (!readValue(blob, at, length) || at + length > blob.size()) return false;
            std::string name(reinterpret_cast<const char *>(blob.data() + at), length);
            at += length;
            if (name.empty()) return optional;
            if (!validLookName(name)) return false;
            FILE *f = std::fopen((engineDir + "/looks/tables/" + name + ".u16").c_str(), "rb");
            if (!f) return false;
            std::vector<uint8_t> bytes(kCube65 * 2);
            bool complete = std::fread(bytes.data(), 1, bytes.size(), f) == bytes.size() && std::fgetc(f) == EOF;
            std::fclose(f);
            size_t offset = 0;
            return complete && readUnorm16(bytes, offset, kCube65, values);
        };
        ok = ok && stage(d->film, false) && stage(d->print, true);
        d->hasPrint = !d->print.empty();
        kind = 2;  // identical spectral rendering; storage uses shared film lattices
    } else if (ok && kind == 7) {
        canon::Style &cs = d->canon;
        uint32_t hasIcc = 0;
        ok = readValue(blob, at, d->engineEv) && readValue(blob, at, d->il1) && readValue(blob, at, d->il2) &&
             readMat(blob, at, d->cm1) && readMat(blob, at, d->cm2) && readInts(blob, at, 0x168, cs.words) &&
             readInts(blob, at, size_t(1024) * 324, cs.atlas) && readValue(blob, at, hasIcc);
        cs.hasIcc = hasIcc != 0;
        if (ok && cs.hasIcc) {
            canon::Icc &icc = cs.icc;
            ok = readValue(blob, at, icc.grid) && readValue(blob, at, icc.n) && readValue(blob, at, icc.m) &&
                 icc.grid >= 2 && icc.grid <= 65 && icc.n >= 2 && icc.n <= 65536 && icc.m >= 2 && icc.m <= 65536 &&
                 readFloats(blob, at, size_t(3) * icc.n, icc.inputCurves) &&
                 readFloats(blob, at, size_t(icc.grid) * icc.grid * icc.grid * 3, icc.clut) &&
                 readFloats(blob, at, size_t(3) * icc.m, icc.outputCurves);
            for (int i = 0; ok && i < 9; i++) ok = readValue(blob, at, icc.xyzToTarget[i]);
            for (int i = 0; ok && i < 3; i++) ok = readValue(blob, at, icc.white[i]);
            uint32_t sizes[3] = {};
            for (int i = 0; ok && i < 3; i++) ok = readValue(blob, at, sizes[i]) && sizes[i] >= 2 && sizes[i] <= 65536;
            for (int i = 0; ok && i < 3; i++) ok = readFloats(blob, at, sizes[i], icc.trc[i]);
        }
        ok = ok && (cs.words[0xf] == 1 || cs.hasIcc);
    } else if (ok && kind == 12) {
        ok = readValue(blob, at, d->basicType) && readValue(blob, at, d->basicGamma) && d->basicType <= 3 &&
             d->basicGamma >= 1.0f && d->basicGamma <= 4.0f;
        uint32_t curveCount = 0;
        if (ok && d->basicType == 3)
            ok = readValue(blob, at, curveCount) && curveCount >= 2 && curveCount <= 65536 &&
                 readFloats(blob, at, curveCount, d->basicCurve) && readValue(blob, at, d->basicGainEv) &&
                 std::fabs(d->basicGainEv) <= 4;
    } else if (ok && kind == 3) {
        ok = readValue(blob, at, d->sigmoid.contrast) && readValue(blob, at, d->sigmoid.hue) &&
             d->sigmoid.contrast > 0 && d->sigmoid.hue >= 0 && d->sigmoid.hue <= 1;
    } else if (ok && kind == 4) {
        ok = readValue(blob, at, d->agx.black) && readValue(blob, at, d->agx.white) &&
             readValue(blob, at, d->agx.toe) && readValue(blob, at, d->agx.shoulder);
    } else if (ok && kind == 5) {
        ok = readValue(blob, at, d->filmicBlack) && readValue(blob, at, d->filmicWhite) &&
             d->filmicBlack < d->filmicWhite;
    } else {
        ok = false;
    }
    if (!ok || at != blob.size()) return nullptr;
    d->kind = int(kind);
    if (lookCache.size() >= 3) lookCache.clear();  // film tables take ~7 MB each in memory
    lookCache[name] = d;
    return d;
}

// Trilinear lookup of an n^3 [B][G][R][3] table at v (clamped to [0, 1]).
Vec3 cube(const std::vector<float> &t, int n, const Vec3 &v) {
    double p[3], f[3];
    int i0[3];
    for (int c = 0; c < 3; c++) {
        p[c] = std::min(std::max(v[c], 0.0), 1.0) * (n - 1);
        i0[c] = std::min(int(std::floor(p[c])), n - 2);
        f[c] = p[c] - i0[c];
    }
    Vec3 out = {0, 0, 0};
    for (int db = 0; db < 2; db++)
        for (int dg = 0; dg < 2; dg++)
            for (int dr = 0; dr < 2; dr++) {
                double w = (dr ? f[0] : 1 - f[0]) * (dg ? f[1] : 1 - f[1]) * (db ? f[2] : 1 - f[2]);
                size_t at = ((size_t(i0[2] + db) * n + (i0[1] + dg)) * n + (i0[0] + dr)) * 3;
                for (int c = 0; c < 3; c++) out[c] += w * t[at + c];
            }
    return out;
}

double srgbDecode(double e) { return e < 0.04045 ? e / 12.92 : std::pow((e + 0.055) / 1.055, 2.4); }
double ppEncode(double x) {
    x = std::max(x, 0.0);
    return x >= 0.001953125 ? std::pow(x, 1 / 1.8) : 16 * x;
}
double ppDecode(double x) {
    x = std::min(std::max(x, 0.0), 1.0);
    return x >= 0.03125 ? std::pow(x, 1.8) : x / 16;
}

// LumixColorTemperature.coordinateForKelvin / highWeight.
double lumixHighWeight(double kelvin) {
    const double kp[4] = {3000, 5000, 6500, 7500}, cp[4] = {256, 512, 618, 725};
    int seg = kelvin < kp[1] ? 0 : kelvin < kp[2] ? 1 : 2;
    double c = cp[seg] + (kelvin - kp[seg]) * (cp[seg + 1] - cp[seg]) / (kp[seg + 1] - kp[seg]);
    int coordinate = int(std::min(std::max(c, 0.0), 65535.0));
    return std::min(std::max((coordinate - 256) / 256.0, 0.0), 1.0);
}

// Linear ProPhoto (D50) -> S9 white-balanced camera RGB at the scene white.
Mat3 prophotoToS9(const LookData &l, double cct) {
    double g = std::min(std::max((1 / cct - 1 / double(l.il1)) / (1 / double(l.il2) - 1 / double(l.il1)), 0.0), 1.0);
    Mat3 cm;
    for (int i = 0; i < 9; i++) cm[i] = l.cm1[i] * (1 - g) + l.cm2[i] * g;
    Vec3 white = whiteXyz(cct);
    Vec3 camWhite = xform(cm, white);
    Mat3 camToXyz = mul(mul(cat(white, kD50), inv(cm)), diag(camWhite[0], camWhite[1], camWhite[2]));
    return mul(inv(camToXyz), kProPhotoToXyz);
}

struct LookPlan {
    const LookData *l = nullptr;
    Mat3 toS9{}, srgbToP3{}, ppToP3{}, ppToBt2020{}, bt2020ToP3{};
    double camScale = 1, highWeight = 0, outputClip = 1;
    std::array<float, 3> density{1, 1, 1};
    double gamma = 2.4;  // basic
    double standardGain = 1;  // basic standard: scene gain before the ACR3 curve
    dt::AgxParams agx;
    dt::FilmicUniforms filmic;
    dt::SigmoidParams sigmoid;
};

// ---------------------------------------------------------------- HSV / HueSatMap helpers (scene front stage)
void dcpRgbToHsv(const Vec3 &c, double hsv[3]) {
    double mx = std::max(c[0], std::max(c[1], c[2])), mn = std::min(c[0], std::min(c[1], c[2])), d = mx - mn;
    double h = 0;
    if (d > 1e-6) {
        if (mx == c[0]) h = std::fmod((c[1] - c[2]) / d, 6.0), h = h < 0 ? h + 6.0 : h;
        else if (mx == c[1]) h = (c[2] - c[0]) / d + 2.0;
        else h = (c[0] - c[1]) / d + 4.0;
    }
    hsv[0] = h, hsv[1] = mx > 1e-6 ? d / mx : 0.0, hsv[2] = mx;
}

double glslMod(double x, double y) { return x - y * std::floor(x / y); }

Vec3 dcpHsvToRgb(const double hsv[3]) {
    double h = glslMod(hsv[0], 6.0), s = std::max(hsv[1], 0.0), v = std::max(hsv[2], 0.0);
    double c = v * s, x = c * (1.0 - std::fabs(glslMod(h, 2.0) - 1.0)), m = v - c;
    Vec3 rgb;
    if (h < 1.0) rgb = {c, x, 0};
    else if (h < 2.0) rgb = {x, c, 0};
    else if (h < 3.0) rgb = {0, c, x};
    else if (h < 4.0) rgb = {0, x, c};
    else if (h < 5.0) rgb = {x, 0, c};
    else rgb = {c, 0, x};
    return {rgb[0] + m, rgb[1] + m, rgb[2] + m};
}

Vec3 dcpSampleDims(int vd, int hd, int sd, const std::vector<float> &t, const double hsv[3]) {
    double hs = hsv[0] * hd / 6.0, ss = hsv[1] * std::max(sd - 1, 0), vs = hsv[2] * std::max(vd - 1, 0);
    int h0 = int(std::floor(hs)), s0 = std::min(int(std::floor(ss)), std::max(sd - 2, 0));
    int v0 = std::min(int(std::floor(vs)), std::max(vd - 2, 0)), h1 = h0 + 1;
    if (h0 >= hd - 1) h0 = hd - 1, h1 = 0;
    double hf = hs - h0, sf = ss - s0, vf = vs - v0;
    int s1 = std::min(s0 + 1, sd - 1), v1 = std::min(v0 + 1, vd - 1);
    auto at = [&](int v, int h, int s, int c) { return double(t[((size_t(v) * hd + h) * sd + s) * 3 + c]); };
    Vec3 out;
    for (int c = 0; c < 3; c++) {
        double a000 = at(v0, h0, s0, c), a001 = at(v0, h1, s0, c), a010 = at(v0, h0, s1, c), a011 = at(v0, h1, s1, c);
        if (vd > 1) {
            a000 = a000 * (1 - vf) + at(v1, h0, s0, c) * vf;
            a001 = a001 * (1 - vf) + at(v1, h1, s0, c) * vf;
            a010 = a010 * (1 - vf) + at(v1, h0, s1, c) * vf;
            a011 = a011 * (1 - vf) + at(v1, h1, s1, c) * vf;
        }
        double e0 = a000 * (1 - hf) + a001 * hf, e1 = a010 * (1 - hf) + a011 * hf;
        out[c] = e0 * (1 - sf) + e1 * sf;
    }
    return out;
}

// Photon firmware adapters: retain the original integer M9 lookup and Fuji Bezier geometry.
double firmwareBezier(const float *v, const float *edges, int segments, double x) {
    int k=0;
    for (int j=1; j<segments; ++j) if (x >= edges[j]) k=j;
    double t=(x-edges[k])/(edges[k+1]-edges[k]), a=1-t;
    return v[k*3]*a*a*a + 3*v[k*3+1]*t*a*a + 3*v[k*3+2]*t*t*a + v[k*3+3]*t*t*t;
}
Vec3 firmwareRender(const LookPlan &p, const Vec3 &pp) {
    const LookData &l=*p.l;
    Vec3 input=xform(p.toS9, pp), encoded{};
    if (l.kind == 10) {
        int camera[3];
        for (int i=0;i<3;++i) camera[i]=int(std::floor(std::min(std::max(input[i],0.0),1.0)*16383));
        int branch=camera[0]>=camera[1]?0:9;
        for (int i=0;i<3;++i) {
            int32_t value=0;
            for (int j=0;j<3;++j) value+=l.leicaMatrices[branch+i*3+j]*camera[j];
            // Explicit floor division matches the DSP signed high word on all host compilers.
            int index=std::min(std::max(int(std::floor(value/65536.0)),0),2047);
            encoded[i]=l.curve[index];
        }
    } else {
        const float *v=l.firmware.data();
        constexpr float edges[14]={0,16,32,64,128,256,512,1024,2048,4096,6144,8192,12288,16384};
        double lum=input[0]*v[162]+input[1]*v[163]+input[2]*v[164];
        double x=std::min(std::max(lum*16384,0.0),16384.0);
        double gain=lum>0 ? x/16384*firmwareBezier(v,edges,13,x)/lum : 1;
        Vec3 mixed{}, shaped{}, code{};
        for (int i=0;i<3;++i) {
            for (int j=0;j<3;++j) mixed[i]+=v[144+i*3+j]*input[j]*gain;
            shaped[i]=firmwareBezier(v+40+i*31,v+133,10,std::min(std::max(mixed[i]*16384,0.0),16384.0));
        }
        int base[3]; double frac[3];
        for (int i=0;i<3;++i) {
            for (int j=0;j<3;++j) code[i]+=v[153+i*3+j]*shaped[j];
            code[i]=std::min(std::max(code[i],0.0),1.0)*4095;
            base[i]=std::min(int(std::floor(code[i]/256)),15);
            frac[i]=(code[i]-base[i]*256)/(base[i]==15?255:256);
        }
        for (int z=0;z<2;++z) for (int y=0;y<2;++y) for (int x=0;x<2;++x) {
            double weight=(x?frac[0]:1-frac[0])*(y?frac[1]:1-frac[1])*(z?frac[2]:1-frac[2]);
            int at=165+(((base[2]+z)*17+base[1]+y)*17+base[0]+x)*3;
            for (int c=0;c<3;++c) encoded[c]+=weight*v[at+c];
        }
    }
    return xform(p.srgbToP3,{srgbDecode(encoded[0]),srgbDecode(encoded[1]),srgbDecode(encoded[2])});
}

double curveAt(const std::vector<float> &lut, double v) {
    double p = std::min(std::max(v, 0.0), 1.0) * double(lut.size() - 1);
    size_t i = std::min(size_t(std::floor(p)), lut.size() - 2);
    return lut[i] + (lut[i + 1] - lut[i]) * (p - double(i));
}

// Basic types 0..2: scene ProPhoto -> display-linear P3 through a transfer curve of the P3 luma. The colour is scaled
// by the luma ratio (hue preserving) and a pixel with a channel above 1 is scaled down instead of clipped.
// Type 3 (standard): the ACR3 default tone curve (a linear result) as Lightroom renders a DNG, on the luma like the
// other types, so the chroma ratios are kept (the SDK's per-channel RGBTone changes them); the scene gain puts 18 %
// grey at display 0.18 like the other engines.
Vec3 basicRender(const LookPlan &p, const Vec3 &pp) {
    const LookData &l = *p.l;
    Vec3 p3 = xform(p.ppToP3, pp);
    for (double &v : p3) v = std::max(v, 0.0);
    if (l.basicType == 3)
        for (double &v : p3) v *= p.standardGain;
    double y = p3[0] * kP3Luma[0] + p3[1] * kP3Luma[1] + p3[2] * kP3Luma[2];
    if (!(y > 0)) return {0, 0, 0};
    double scale;
    if (l.basicType == 3) {
        scale = curveAt(l.basicCurve, y) / y;
    } else {
        double code;
        if (l.basicType == 0) code = srgbEncode(y);
        else if (l.basicType == 1) code = y < 0.018 ? 4.5 * y : 1.099 * std::pow(y, 0.45) - 0.099;
        else code = std::pow(y, 1.0 / p.gamma);
        scale = srgbDecode(std::min(code, 1.0)) / y;
    }
    Vec3 out = {p3[0] * scale, p3[1] * scale, p3[2] * scale};
    double peak = std::max(out[0], std::max(out[1], out[2]));
    if (peak > 1.0) for (double &v : out) v /= peak;
    return out;
}

// Scene ProPhoto (18 % grey = 0.18) -> display-linear P3 in [0, 1].
void renderLook(const LookPlan &p, const Vec3 &pp, float out[3]) {
    const LookData &l = *p.l;
    Vec3 p3;
    if (l.kind == 12) {
        p3 = basicRender(p, pp);
    } else if (l.kind == 10 || l.kind == 11) {
        p3 = firmwareRender(p, pp);
    } else if (l.kind == 7) {
        Vec3 cam = xform(p.toS9, pp);
        double c[3] = {cam[0] * p.camScale, cam[1] * p.camScale, cam[2] * p.camScale}, lin[3];
        canon::render(l.canon, c, lin);
        p3 = xform(p.srgbToP3, {lin[0], lin[1], lin[2]});
    } else if (l.kind == 1) {
        Vec3 cam = xform(p.toS9, pp), shaped, lin;
        for (int c = 0; c < 3; c++) {
            double v = std::min(std::max(cam[c] * p.camScale, 0.0), 1.0) * 2047.0;
            int lower = std::min(int(std::floor(v)), 2046);
            shaped[c] = l.curve[lower] + (l.curve[lower + 1] - l.curve[lower]) * (v - lower);
        }
        Vec3 lo = cube(l.low, 33, shaped), hi = cube(l.high, 33, shaped);
        for (int c = 0; c < 3; c++) {
            double e = std::min(std::max(lo[c] * (1 - p.highWeight) + hi[c] * p.highWeight, 0.0), p.outputClip);
            lin[c] = srgbDecode(std::floor(e * 4095.0) / 4095.0);
        }
        p3 = xform(p.srgbToP3, lin);
    } else if (l.kind >= 3) {
        Vec3 x = xform(p.ppToBt2020, pp);
        double y[3];
        if (l.kind == 3) dt::sigmoid(p.sigmoid, x.data(), y);
        else if (l.kind == 4) dt::agx(p.agx, x.data(), y);
        else dt::filmic(p.filmic, x.data(), y);
        p3 = xform(p.bt2020ToP3, {y[0], y[1], y[2]});
    } else {
        Vec3 enc = {ppEncode(pp[0] * l.inScale), ppEncode(pp[1] * l.inScale), ppEncode(pp[2] * l.inScale)};
        Vec3 r = cube(l.film, 65, enc);
        if (l.hasPrint) r = cube(l.print, 65, {r[0] * l.printGain * (2 - p.density[0]), r[1] * l.printGain * (2 - p.density[1]), r[2] * l.printGain * (2 - p.density[2])});
        p3 = xform(p.ppToP3, {ppDecode(r[0]), ppDecode(r[1]), ppDecode(r[2])});
    }
    for (int c = 0; c < 3; c++) out[c] = float(std::min(std::max(p3[c], 0.0), 1.0));
}

uint64_t fnv(const void *data, size_t n, uint64_t h = 1469598103934665603ull) {
    const uint8_t *p = static_cast<const uint8_t *>(data);
    for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ull;
    return h;
}

// ---------------------------------------------------------------- scene front stage (scene.bin)
struct SceneLens {
    std::string name;
    float focal = 0, t1 = 0, t2 = 0;
    Mat3 fm1{}, fm2{};
    int hue = 0, sat = 0;                 // one value division
    std::vector<float> hs1, hs2;          // HueSatMap 1 / 2, [hue][sat][3]
};
std::vector<SceneLens> sceneLenses;

bool loadScene(const std::string &path, std::string *error) {
    FILE *file = std::fopen(path.c_str(), "rb");
    if (!file) {
        if (error) *error = "missing " + path;
        return false;
    }
    std::vector<uint8_t> blob;
    uint8_t chunk[65536];
    size_t got;
    while ((got = std::fread(chunk, 1, sizeof(chunk), file)) > 0) blob.insert(blob.end(), chunk, chunk + got);
    std::fclose(file);
    size_t at = 8;
    uint32_t version = 0, count = 0;
    bool ok = blob.size() > 16 && std::memcmp(blob.data(), "MCSCENE1", 8) == 0 && readValue(blob, at, version) &&
              version == 1 && readValue(blob, at, count) && count >= 1 && count <= 16;
    std::vector<SceneLens> lenses;
    for (uint32_t i = 0; ok && i < count; i++) {
        SceneLens l;
        uint32_t length = 0, hue = 0, sat = 0, val = 0;
        ok = readValue(blob, at, length) && length > 0 && length <= 32 && at + length <= blob.size();
        if (ok) {
            l.name.assign(reinterpret_cast<const char *>(blob.data() + at), length);
            at += length;
        }
        ok = ok && readValue(blob, at, l.focal) && readValue(blob, at, l.t1) && readValue(blob, at, l.t2) &&
             readMat(blob, at, l.fm1) && readMat(blob, at, l.fm2) && readValue(blob, at, hue) && readValue(blob, at, sat) &&
             readValue(blob, at, val) && val == 1 && hue >= 2 && hue <= 360 && sat >= 2 && sat <= 64 && l.focal > 0 &&
             l.t1 > 0 && l.t2 > 0 && l.t1 != l.t2;
        l.hue = int(hue);
        l.sat = int(sat);
        ok = ok && readFloats(blob, at, size_t(hue) * sat * 3, l.hs1) && readFloats(blob, at, size_t(hue) * sat * 3, l.hs2);
        lenses.push_back(std::move(l));
    }
    if (!ok || at != blob.size()) {
        if (error) *error = "malformed scene data (" + std::to_string(blob.size()) + " bytes)";
        return false;
    }
    sceneLenses = std::move(lenses);
    return true;
}

// Post-CCM linear RGB -> scene-linear ProPhoto D50 for one frame: inverse CCM, the lens' ForwardMatrix and
// HueSatMap, both interpolated at the frame CCT (Adobe Standard profile; tools/mastercolor/scene_front.py).
struct FrontStage {
    Mat3 toProPhoto{};
    std::vector<float> table;
    int hue = 0, sat = 0;
};

bool makeFrontStage(const std::string &lens, const std::array<float, 9> &ccmF, int cct, FrontStage &fs) {
    const SceneLens *l = nullptr;
    for (const SceneLens &candidate : sceneLenses)
        if (candidate.name == lens) l = &candidate;
    if (!l || cct < 1500 || cct > 20000) return false;
    Mat3 ccm;
    std::copy(ccmF.begin(), ccmF.end(), ccm.begin());
    for (double v : ccm) if (!std::isfinite(v)) return false;
    double det = ccm[0]*(ccm[4]*ccm[8]-ccm[5]*ccm[7])-ccm[1]*(ccm[3]*ccm[8]-ccm[5]*ccm[6])+ccm[2]*(ccm[3]*ccm[7]-ccm[4]*ccm[6]);
    if (std::abs(det) < 1e-9) return false;
    double w = std::clamp((1.0 / cct - 1.0 / l->t1) / (1.0 / l->t2 - 1.0 / l->t1), 0.0, 1.0);
    Mat3 fm;
    for (int i = 0; i < 9; i++) fm[i] = l->fm1[i] * (1 - w) + l->fm2[i] * w;
    fs.toProPhoto = mul(mul(inv(kProPhotoToXyz), fm), inv(ccm));
    fs.table.resize(l->hs1.size());
    for (size_t i = 0; i < fs.table.size(); i++) fs.table[i] = float(l->hs1[i] * (1 - w) + l->hs2[i] * w);
    fs.hue = l->hue;
    fs.sat = l->sat;
    return true;
}

Vec3 frontStage(const FrontStage &fs, const Vec3 &linear) {
    Vec3 pp = xform(fs.toProPhoto, linear);
    for (double &v : pp) v = std::max(v, 0.0);
    double hsv[3];
    dcpRgbToHsv(pp, hsv);
    const double lookup[3] = {hsv[0], hsv[1], 0.0};
    Vec3 mod = dcpSampleDims(1, fs.hue, fs.sat, fs.table, lookup);
    hsv[0] = glslMod(hsv[0] + mod[0] * 6.0 / 360.0, 6.0);
    hsv[1] = std::min(std::max(hsv[1] * mod[1], 0.0), 1.0);
    hsv[2] = std::max(hsv[2] * mod[2], 0.0);
    return dcpHsvToRgb(hsv);
}

}  // namespace

bool sceneLensFor(double equivalentFocal, std::string &lens) {
    const SceneLens *best = nullptr;
    double bestError = 1e9;
    for (const SceneLens &l : sceneLenses) {
        double error = std::fabs(std::log(equivalentFocal / l.focal));
        if (error < bestError) bestError = error, best = &l;
    }
    if (!best || !(bestError <= std::log(1.25))) return false;
    lens = best->name;
    return true;
}

std::string Key::name() const {
    uint64_t h = fnv(ccm.data(), sizeof(float) * 9);
    h = fnv(lens.data(), lens.size(), h);
    for (float v : param) if (std::isfinite(v)) h = fnv(&v, sizeof(v), h);
    if (look != "hncs") h = fnv(look.data(), look.size(), h);
    if (exposureEv != 0) h = fnv(&exposureEv, sizeof(exposureEv), h);
    if (blended()) {
        const float w[2] = {toneWeight, colourWeight};
        h = fnv(w, sizeof(w), h);
    }
    if (density != std::array<float, 3>{1, 1, 1}) h = fnv(density.data(), sizeof(float) * 3, h);
    char buf[64];
    const char *tag = path == Path::Main ? (luxBlend ? "mb" : "m") : path == Path::Thumbnail ? "t" : "p";
    std::snprintf(buf, sizeof(buf), "%s%05d_%016llx", tag, cct, static_cast<unsigned long long>(h));
    return buf;
}

bool loadEngine(const std::string &path, std::string *error) {
    std::lock_guard<std::mutex> lock(engineMutex);
    if (engineOk) return true;
    FILE *file = std::fopen(path.c_str(), "rb");
    if (!file) {
        if (error) *error = "missing " + path;
        return false;
    }
    std::vector<uint8_t> blob;
    uint8_t chunk[65536];
    size_t got;
    while ((got = std::fread(chunk, 1, sizeof(chunk), file)) > 0) blob.insert(blob.end(), chunk, chunk + got);
    std::fclose(file);
    EngineData d;
    size_t at = 8;
    uint32_t version = 0, count = 0;
    bool ok = blob.size() > 8 && std::memcmp(blob.data(), "HNCSENG1", 8) == 0 && readValue(blob, at, version) &&
              version == 4 && readValue(blob, at, d.k) && readValue(blob, at, d.greyScene) &&
              readValue(blob, at, d.gw) && readValue(blob, at, d.gh) && readValue(blob, at, d.cbStart) &&
              readValue(blob, at, d.crStart) && readValue(blob, at, d.divFactor) &&
              readValue(blob, at, d.matrixMax) && readValue(blob, at, d.tableMax) && readValue(blob, at, count);
    for (uint32_t i = 0; ok && i < count; i++) {
        Anchor a;
        ok = readValue(blob, at, a.temperature) && readFloats(blob, at, 9, a.values);
        d.matrices.push_back(std::move(a));
    }
    ok = ok && readValue(blob, at, count);
    for (uint32_t i = 0; ok && i < count; i++) {
        Anchor a;
        ok = readValue(blob, at, a.temperature) && readFloats(blob, at, size_t(d.gw) * d.gh * 2, a.values);
        d.tables.push_back(std::move(a));
    }
    ok = ok && readMat(blob, at, d.cm) && at + 65536 * 2 <= blob.size();
    if (ok) {
        d.film.resize(65536);
        for (int i = 0; i < 65536; i++) {
            uint16_t v;
            std::memcpy(&v, blob.data() + at + i * 2, 2);
            d.film[i] = v / 65535.0f;
        }
        at += 65536 * 2;
        ok = readFloats(blob, at, 1024, d.toneCurve) && readFloats(blob, at, 65536, d.builtin) &&
             readFloats(blob, at, 65536, d.proproc) &&
             readValue(blob, at, d.greyCode) && readValue(blob, at, d.cap) &&
             readFloats(blob, at, size_t(kLutSize) * kLutSize * kLutSize * 3, d.luxInverse) && at == blob.size() && d.k > 0 &&
             d.matrices.size() >= 2 && !d.tables.empty() && d.gw >= 2 && d.gh >= 2;
    }
    if (!ok) {
        if (error) *error = "malformed engine data (" + std::to_string(blob.size()) + " bytes)";
        return false;
    }
    size_t slash = path.rfind('/');
    std::string dir = slash == std::string::npos ? std::string(".") : path.substr(0, slash);
    if (!loadScene(dir + "/scene.bin", error)) return false;
    engineData = std::move(d);
    engineOk = true;
    engineDir = dir;
    return true;
}

bool engineReady() {
    std::lock_guard<std::mutex> lock(engineMutex);
    return engineOk;
}

// Find X7 Ultra: the shipped master LMT (looks/x7u.lmt, 64^3 fp32 planar [3][B][G][R]) is served as is.
// The table is X7U ODT_Photo . LMTLut0 (all four C16 LMTs are identical) pushed through the exact inverse of
// the X9U HDRT master model (tools/mastercolor/x7u_lmt.py); it does not depend on the frame, so key.exposureEv is ignored.
static bool loadRawLmt(const std::string &path, std::vector<float> &lut) {
    constexpr size_t kFloats = size_t(3) * kLutSize * kLutSize * kLutSize;
    FILE *file = std::fopen(path.c_str(), "rb");
    if (!file) return false;
    lut.resize(kFloats);
    bool ok = std::fread(lut.data(), sizeof(float), kFloats, file) == kFloats && std::fgetc(file) == EOF;
    std::fclose(file);
    for (size_t i = 0; ok && i < kFloats; i += 4099) ok = std::isfinite(lut[i]);
    return ok;
}

// Find X8 Ultra: its stock master LMTs (looks/x8u/LMTLut0..3, PKJ110 17.0.0.104 /odm/etc/camera/basictone/lmt, verbatim)
// laid onto this phone's six slots, so the stock selector keeps choosing by scene level and CCT parameter per frame.
// X8U has this phone's LMT input coding (identical hybridraw built-in gamma) and ODT_Photo, so its tables
// share the code space of the stock ones. Its TriggerBIN: two lux entries (0-195 / 550-10000, blended between,
// as here) of two CCT-parameter nodes (<= 50, >= 600, linear between): LMTLut0/1 and LMTLut2/3.
// Here each lux entry has three nodes (<= 50, 250-500, >= 700): the outer ones take X8U's nodes, the
// middle one their mix at weight 0.591, the value that minimises the largest weight error against X8U's
// ramp over the CCT parameter (0.23 at 250 and 500).
static bool x8uSlots(std::vector<std::vector<float>> &tables) {
    constexpr double kMiddle = 0.591;
    std::vector<std::vector<float>> x8(4);
    for (int i = 0; i < 4; i++)
        if (!loadRawLmt(engineDir + "/looks/x8u/LMTLut" + std::to_string(i), x8[i])) return false;
    tables.assign(kStockTables, {});
    for (int entry = 0; entry < 2; entry++) {
        const std::vector<float> &cool = x8[2 * entry], &warm = x8[2 * entry + 1];
        tables[3 * entry] = cool;
        tables[3 * entry + 2] = warm;
        std::vector<float> &mid = tables[3 * entry + 1];
        mid.resize(cool.size());
        for (size_t i = 0; i < mid.size(); i++) mid[i] = float((1 - kMiddle) * cool[i] + kMiddle * warm[i]);
    }
    return true;
}

bool lookTables(const Key &key, std::vector<std::vector<float>> &tables, int threads) {
    if (!engineReady()) return false;
    if (key.look == "x8u") return x8uSlots(tables);
    tables.assign(1, {});
    return bake(key, tables[0], threads);
}

bool bake(const Key &key, std::vector<float> &lut, int threads) {
    if (!engineReady()) return false;
    if (key.look == "x7u") return loadRawLmt(engineDir + "/looks/x7u.lmt", lut);
    const EngineData &d = engineData;
    std::vector<float> ipe;
    const bool hncsLook = key.look == "hncs" || key.look.rfind("hncs_", 0) == 0;
    std::shared_ptr<const LookData> look;
    if (key.look != "hncs" && !(look = loadLook(key.look))) return false;
    // HNCS: D65 P3 scene linear with its own exposure. Lumix / film / basic: ProPhoto D50, 18 % grey = 0.18.
    FrontStage front;
    if (!makeFrontStage(key.lens, key.ccm, key.cct, front)) return false;
    const Mat3 ppToP3Scene = mul(mul(inv(kP3ToXyz), cat(kD50, kD65)), kProPhotoToXyz);
    auto sceneOf = [&](const Vec3 &linear) {
        Vec3 pp = frontStage(front, linear);
        return hncsLook ? xform(ppToP3Scene, pp) : pp;
    };
    Vec3 greyLin = decode(d, key, ipe.data(), {d.greyCode, d.greyCode, d.greyCode});
    Vec3 greyScene = sceneOf(greyLin);
    const Vec3 &luma = hncsLook ? kP3Luma : Vec3{kProPhotoToXyz[3], kProPhotoToXyz[4], kProPhotoToXyz[5]};
    double greyY = greyScene[0] * luma[0] + greyScene[1] * luma[1] + greyScene[2] * luma[2];
    if (!(greyY > 0)) return false;
    double scale = (hncsLook ? d.greyScene / greyY * d.k : 0.18 / greyY) * std::exp2(double(key.exposureEv));
    Plan plan;
    LookPlan lookPlan;
    if (hncsLook) {
        makePlan(d, key.cct, plan);
        if (look) {
            if (look->kind != 9) return false;
            plan.film = look->film.data();
            auto table = interpolate(look->hncsTables, std::floor(std::clamp(double(key.cct), 2000.0, double(d.tableMax))));
            plan.table.assign(table.begin(), table.end());
        }
    } else {
        lookPlan.l = look.get();
        lookPlan.density = key.density;
        lookPlan.outputClip = look->clip;
        lookPlan.srgbToP3 = mul(inv(kP3ToXyz), kSrgbToXyz);
        lookPlan.ppToP3 = mul(mul(inv(kP3ToXyz), cat(kD50, kD65)), kProPhotoToXyz);
        lookPlan.ppToBt2020 = mul(mul(inv(kBt2020ToXyz), cat(kD50, kD65)), kProPhotoToXyz);
        lookPlan.bt2020ToP3 = mul(inv(kP3ToXyz), kBt2020ToXyz);
        // Look parameters: the key's value (clamped to a sane range) or the look file's default.
        auto param = [&](int i, float fallback, float lo, float hi) { return std::min(std::max(key.value(i, fallback), lo), hi); };
        if (look->kind == 12 && look->basicType == 2) lookPlan.gamma = param(0, look->basicGamma, 1.0f, 4.0f);
        else if (look->kind == 12) lookPlan.gamma = look->basicGamma;
        if (look->kind == 12 && look->basicType == 3) lookPlan.standardGain = std::exp2(double(look->basicGainEv));
        if (look->kind == 3) {
            lookPlan.sigmoid.contrast = param(0, look->sigmoid.contrast, 0.5f, 5.0f);
            lookPlan.sigmoid.hue = param(1, look->sigmoid.hue, 0.0f, 1.0f);
        }
        if (look->kind == 4) {
            lookPlan.agx.black = param(0, look->agx.black, -20.0f, -0.5f);
            lookPlan.agx.white = param(1, look->agx.white, 0.5f, 20.0f);
            lookPlan.agx.toe = param(2, look->agx.toe, 0.1f, 10.0f);
            lookPlan.agx.shoulder = param(3, look->agx.shoulder, 0.1f, 10.0f);
        }
        if (look->kind == 5)
            lookPlan.filmic = dt::filmicUniforms(param(0, look->filmicBlack, -16.0f, -1.0f), param(1, look->filmicWhite, 0.5f, 12.0f));
        if (look->kind == 10) lookPlan.toS9 = prophotoToS9(*look, key.cct);
        if (look->kind == 11) lookPlan.toS9 = mul(mul(inv(kSrgbToXyz), cat(kD50, kD65)), kProPhotoToXyz);
        if (look->kind == 7) {
            lookPlan.toS9 = prophotoToS9(*look, key.cct);  // EOS R5 ColorMatrix pair
            lookPlan.camScale = std::exp2(double(look->engineEv));
        }
        if (look->kind == 1) {
            lookPlan.toS9 = prophotoToS9(*look, key.cct);
            lookPlan.camScale = look->grey / 0.18 * look->gain;
            lookPlan.highWeight = lumixHighWeight(key.cct);

        }
    }
    constexpr int n = kLutSize;
    lut.assign(size_t(3) * n * n * n, 0.0f);
    // Decoded linear value of a lattice node: per channel unless the lux blend couples them.
    std::array<Vec3, n> axis;
    for (int i = 0; i < n; i++) {
        double code = i / double(n - 1);
        axis[i] = decode(d, key, ipe.data(), {code, code, code});
    }
    const bool coupled = key.path == Path::Main && key.luxBlend;
    auto lattice = [&](int r, int g, int b) -> Vec3 {
        if (coupled) return decode(d, key, ipe.data(), {r / double(n - 1), g / double(n - 1), b / double(n - 1)});
        return {axis[r][0], axis[g][1], axis[b][2]};
    };
    std::atomic<int> next{0};
    auto worker = [&]() {
        for (int b; (b = next.fetch_add(1)) < n;) {
            for (int g = 0; g < n; g++) {
                for (int r = 0; r < n; r++) {
                    Vec3 scene = sceneOf(lattice(r, g, b));
                    float display[3], out[3];
                    if (hncsLook) {
                        float s[3] = {float(scene[0] * scale), float(scene[1] * scale), float(scene[2] * scale)};
                        render(plan, s, display);
                    } else {
                        renderLook(lookPlan, {scene[0] * scale, scene[1] * scale, scene[2] * scale}, display);
                    }
                    invertOutput(d, display, out);
                    size_t index = (size_t(b) * n + g) * n + r;
                    for (int c = 0; c < 3; c++) lut[size_t(c) * n * n * n + index] = out[c];
                }
            }
        }
    };
    threads = std::max(1, std::min(threads, 8));
    std::vector<std::thread> pool;
    for (int i = 0; i < threads; i++) pool.emplace_back(worker);
    for (auto &t : pool) t.join();
    return true;
}

namespace {

double hlgInverse(double h) {
    h = std::min(std::max(h, 0.0), 1.0);
    return h <= 0.5 ? h * h / 3.0 : (std::exp((h - kC) / kA) + kB) / 12.0;
}

// Non-decreasing curve through the neutral axis nodes: output as a function of the scene luma of the code.
struct NeutralCurve {
    std::vector<double> x, y;
    double at(double l) const {
        if (l <= x.front()) return y.front();
        if (l >= x.back()) return y.back();
        size_t hi = size_t(std::upper_bound(x.begin(), x.end(), l) - x.begin());
        size_t lo = hi - 1;
        double span = x[hi] - x[lo];
        double f = span > 0 ? (l - x[lo]) / span : 0.0;
        return y[lo] + f * (y[hi] - y[lo]);
    }
};

bool readTable(const std::string &path, std::vector<float> &out) {
    FILE *file = std::fopen(path.c_str(), "rb");
    if (!file) return false;
    constexpr size_t count = size_t(3) * kLutSize * kLutSize * kLutSize;
    out.resize(count);
    bool ok = std::fread(out.data(), sizeof(float), count, file) == count;
    std::fclose(file);
    return ok;
}

}  // namespace

bool blendWithStock(const Key &key, const std::vector<std::vector<float>> &looks, const std::string &stockDir,
                    std::vector<std::vector<float>> &tables, int threads) {
    constexpr int n = kLutSize;
    constexpr size_t nodes = size_t(n) * n * n;
    constexpr double kFloor = 1e-5;
    if (!engineReady() || (looks.size() != 1 && looks.size() != size_t(kStockTables))) return false;
    for (const auto &look : looks)
        if (look.size() != 3 * nodes) return false;
    const double wt = std::min(std::max(double(key.toneWeight), 0.0), 1.0);
    const double wc = std::min(std::max(double(key.colourWeight), 0.0), 1.0);
    tables.clear();
    if (wt >= 1 && wc >= 1) {
        tables = looks;
        return true;
    }
    std::vector<std::vector<float>> stock(kStockTables);
    for (int i = 0; i < kStockTables; i++)
        if (!readTable(stockDir + "/LMTLut" + std::to_string(i), stock[i])) return false;
    if (wt <= 0 && wc <= 0) {
        tables = std::move(stock);
        return true;
    }
    const EngineData &d = engineData;
    std::vector<float> ipe;
    // Scene luma of every node's input code (through the same decode as the look bake), and the look's
    // linear-light output.
    std::vector<double> luma(nodes);
    for (int b = 0; b < n; b++)
        for (int g = 0; g < n; g++)
            for (int r = 0; r < n; r++) {
                size_t index = (size_t(b) * n + g) * n + r;
                Vec3 lin = decode(d, key, ipe.data(), {r / double(n - 1), g / double(n - 1), b / double(n - 1)});
                luma[index] = kW601[0] * lin[0] + kW601[1] * lin[1] + kW601[2] * lin[2];
            }
    auto neutral = [&](const float *e) {
        NeutralCurve curve;
        double top = 0, lastX = -1;
        for (int i = 0; i < n; i++) {
            size_t index = (size_t(i) * n + i) * n + i;
            double x = std::max(luma[index], lastX);
            top = std::max(top, (double(e[index]) + e[nodes + index] + e[2 * nodes + index]) / 3.0);
            curve.x.push_back(x);
            curve.y.push_back(top);
            lastX = x;
        }
        return curve;
    };
    std::vector<float> eLook(3 * nodes), toneLookAt(nodes);
    auto prepareLook = [&](const std::vector<float> &look) {
        for (size_t i = 0; i < 3 * nodes; i++) eLook[i] = float(hlgInverse(look[i]));
        const NeutralCurve toneLook = neutral(eLook.data());
        for (size_t i = 0; i < nodes; i++) toneLookAt[i] = float(std::max(toneLook.at(luma[i]), kFloor));
    };
    if (looks.size() == 1) prepareLook(looks[0]);

    tables.assign(kStockTables, std::vector<float>(3 * nodes));
    threads = std::max(1, std::min(threads, 8));
    for (int t = 0; t < kStockTables; t++) {
        if (looks.size() > 1) prepareLook(looks[t]);
        std::vector<float> eStock(3 * nodes);
        for (size_t i = 0; i < 3 * nodes; i++) eStock[i] = float(hlgInverse(stock[t][i]));
        const NeutralCurve toneStock = neutral(eStock.data());
        std::atomic<int> next{0};
        auto worker = [&]() {
            for (int b; (b = next.fetch_add(1)) < n;) {
                for (size_t i = size_t(b) * n * n; i < size_t(b + 1) * n * n; i++) {
                    double ts = std::max(toneStock.at(luma[i]), kFloor), tl = toneLookAt[i];
                    double tone = std::exp((1 - wt) * std::log(ts) + wt * std::log(tl));
                    for (int c = 0; c < 3; c++) {
                        double cs = std::max(eStock[c * nodes + i] / ts, kFloor);
                        double cl = std::max(eLook[c * nodes + i] / tl, kFloor);
                        double e = tone * std::exp((1 - wc) * std::log(cs) + wc * std::log(cl));
                        tables[t][c * nodes + i] = float(std::min(std::max(hlgOetf(std::min(e, 1.0)), 0.0), 1.0));
                    }
                }
            }
        };
        std::vector<std::thread> pool;
        for (int i = 0; i < threads; i++) pool.emplace_back(worker);
        for (auto &th : pool) th.join();
    }
    return true;
}

bool readKeyFile(const std::string &path, Key &key) {
    FILE *file = std::fopen(path.c_str(), "rb");
    if (!file) return false;
    char magic[8];
    int32_t p = 0, cct = 0, lux = 0;
    uint32_t count = 0;
    // MCOLKEY8: common key, the scene front stage lens, the four look parameters (NaN = default).
    uint32_t length=0;
    bool ok=std::fread(magic,1,8,file)==8 && std::memcmp(magic,"MCOLKEY8",8)==0 &&
            std::fread(&p,4,1,file)==1 && std::fread(&cct,4,1,file)==1 &&
            std::fread(key.ccm.data(),4,9,file)==9 && std::fread(&lux,4,1,file)==1 &&
            std::fread(&count,4,1,file)==1 && count==0 &&
            std::fread(&length,4,1,file)==1 && length>0 && length<=64;
    if (ok) {
        key.look.assign(length,'\0');
        ok=std::fread(key.look.data(),1,length,file)==length &&
           std::fread(&key.exposureEv,4,1,file)==1 && std::isfinite(key.exposureEv) &&
           std::fread(&key.toneWeight,4,1,file)==1 && std::fread(&key.colourWeight,4,1,file)==1 &&
           key.toneWeight>=0 && key.toneWeight<=1 && key.colourWeight>=0 && key.colourWeight<=1 &&
           std::fread(key.density.data(),4,3,file)==3;
        for (float value : key.density) ok=ok && std::isfinite(value) && value>=.5f && value<=1.5f;
    }
    if (ok) {
        ok=std::fread(&length,4,1,file)==1 && length>0 && length<=32;
        if (ok) {
            key.lens.assign(length,'\0');
            ok=std::fread(key.lens.data(),1,length,file)==length;
        }
        ok=ok && std::fread(key.param.data(),4,4,file)==4 && std::fgetc(file)==EOF;
        for (float value : key.param) ok=ok && !std::isinf(value);
    }
    std::fclose(file);
    if (!ok || p < 0 || p > 2) return false;
    key.path = static_cast<Path>(p);
    key.cct = cct;
    key.luxBlend = lux != 0;
    return true;
}

}  // namespace mastercolor
