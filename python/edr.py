"""edrScaleCalculator — empirical EDR curve model.

Verified against real-device probe data and edited JPG oracles.
"""

import math


def edr_scale_calculator(f: list[float]) -> float:
    """Compute EDR scale from 36-float LHDR metadata.

    Two empirical models based on device generation and scene detection:

    SIGMOID PATH (f[23] <= 0.99 or f[0] < 3.0):
        sigmoid(f32) -> dynamic range correction -> sqrt adjustment -> clamp

    MAIN PATH (f[23] > 0.99 and f[0] >= 3.0):
        3-segment linear mapping -> clamp
    """
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
