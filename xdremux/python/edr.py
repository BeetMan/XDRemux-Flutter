"""EDR curve model for LHDR metadata."""

import math
import struct


def _f32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", float(value)))[0]


def _fmaf(a: float, b: float, c: float) -> float:
    if hasattr(math, "fma"):
        return _f32(math.fma(_f32(a), _f32(b), _f32(c)))
    return _f32(_f32(a) * _f32(b) + _f32(c))


def _float32_early_lhdr_scale(f: list[float]) -> float:
    version = _f32(f[0])
    if version < _f32(2.0):
        return 1.0

    precomputed = _f32(f[33])
    if precomputed >= _f32(1.0):
        return float(precomputed)

    raw_gain = _f32(f[32])
    if raw_gain <= _f32(0.0):
        return 1.0

    face_strength = _f32(f[24])
    highlight = _f32(f[29])

    edr = _f32(math.exp2(_fmaf(raw_gain, -0.11749999970197678, -6.828999996185303)))
    edr = _f32(_f32(780.2999877929688) / _f32(edr + _f32(1.0)))
    edr = _f32(edr + _f32(-772.2999877929688))

    face_adjusted = edr
    if face_strength > _f32(0.0):
        factor = face_strength if face_strength < _f32(1.0) else _f32(_f32(1.0) / face_strength)
        face_adjusted = _fmaf(_f32(edr - _f32(1.0)), factor, 1.0)

    sqrt_term = _f32(abs(_f32(math.sqrt(face_adjusted))) - _f32(1.0))
    if highlight >= _f32(200.0):
        high_highlight = _fmaf(sqrt_term, 1.340000033378601, 1.0)
        mid_factor = _fmaf(highlight, -0.020500000566244125, 7.900000095367432)
        mid_highlight = _fmaf(sqrt_term, mid_factor, 1.0)
        highlight_adjusted = high_highlight if highlight >= _f32(320.0) else mid_highlight
    else:
        highlight_adjusted = _fmaf(sqrt_term, 3.799999952316284, 1.0)

    if _f32(f[34]) == _f32(1.401298464324817e-45):
        cfg_term = _f32(abs(_f32(math.sqrt(highlight_adjusted))) - _f32(1.0))
        return float(_fmaf(cfg_term, 1.2999999523162842, 1.0))

    if face_strength > _f32(0.0):
        face_term = _f32(abs(_f32(math.sqrt(highlight_adjusted))) - _f32(1.0))
        adjusted = _fmaf(face_term, 1.850000023841858, 1.0)
        if highlight <= _f32(320.0):
            return float(adjusted)
        return float(_fmaf(_f32(adjusted - _f32(1.0)), 0.800000011920929, 1.0))

    if highlight <= _f32(320.0):
        return float(highlight_adjusted)
    return float(_fmaf(_f32(highlight_adjusted - _f32(1.0)), 0.800000011920929, 1.0))


def edr_scale_calculator(f: list[float]) -> float:
    """Compute EDR scale from 36-float LHDR metadata.

    Two empirical models based on device generation and scene detection:

    SIGMOID PATH (f[23] <= 0.99 or f[0] < 3.0):
        sigmoid(f32) -> dynamic range correction -> sqrt adjustment -> clamp

    MAIN PATH (f[23] > 0.99 and f[0] >= 3.0):
        3-segment linear mapping -> clamp
    """
    if f[0] < 3.0:
        return _float32_early_lhdr_scale(f)

    if f[0] < 2.0:
        return 1.0
    if f[33] >= 1.0:
        return float(f[33])
    if f[32] <= 0.0:
        return 1.0

    f23 = f[23]
    f24 = f[24]
    f29 = max(f[29], 1.0)
    f32 = f[32]
    cfg = int(f[34]) == 1

    if f23 <= 0.99 or f[0] < 3.0:
        # ---- SIGMOID PATH ----
        exp_arg = f32 * (-0.1175) + (-6.829)
        edr = 780.3 / (math.exp2(exp_arg) + 1.0) - 772.3

        if f24 > 0.0:
            factor = f24 if f24 < 1.0 else 1.0 / f24
            edr = (edr - 1.0) * factor + 1.0

        if f29 >= 200.0:
            s4 = abs(math.sqrt(abs(edr))) - 1.0
            if f29 >= 320.0:
                edr = s4 * 1.34 + 1.0
            else:
                edr = s4 * (f29 * (-0.0205) + 7.9) + 1.0
        else:
            s4 = abs(math.sqrt(abs(edr))) - 1.0
            edr = s4 * 3.8 + 1.0

        if cfg:
            edr = (abs(math.sqrt(abs(edr))) - 1.0) * 1.3 + 1.0
        elif f24 > 0.0:
            adj = (abs(math.sqrt(abs(edr))) - 1.0) * 1.85 + 1.0
            edr = adj if f29 <= 320.0 else (adj - 1.0) * 0.8 + 1.0
        else:
            edr = edr if f29 <= 320.0 else (edr - 1.0) * 0.8 + 1.0

        return min(max(edr, 1.0), 7.9)

    # ---- MAIN PATH ----
    norm_gain = (f32 * 1023.0) / 65535.0
    scaled = math.log2(norm_gain * 63.0 + 1.0) / f29 * 100.0

    if f29 <= 210.0:
        edr = scaled * 0.3456 + 1.824
    elif f29 > 340.0:
        edr = scaled * 0.1046 + 1.878
    else:
        edr = scaled * 0.5883 + 1.401

    return min(max(edr, 1.0), 7.9)
