"""Gain map pixel reconstruction — ported from XDRemux Swift.

Reconstructs an ISO 21496-1 gain map image from the LHDR mask
and EDR scale using an empirical LUT chain model.
"""

import math
import numpy as np


def _make_lut(count: int, fn) -> np.ndarray:
    """Build a lookup table of `count` entries sampled at i/1000."""
    return np.array([fn(i / 1000.0) for i in range(count)], dtype=np.float32)


def _get_knee_point(edr: float) -> float:
    """Reinhard tone-mapping knee point from empirical EDR curve analysis."""
    inv_gamma = 1.0 / 2.2
    edr_scaled = edr * 100.0
    t = 1.0 / edr_scaled
    k = 1.0 - t

    p1 = edr ** inv_gamma
    div1 = 1.0 / p1
    x_norm = (0.98 - t) / k
    p2 = x_norm ** inv_gamma
    y = (div1 - p2 * 1.00394) / (1.0 - div1)
    p3 = y ** inv_gamma

    knee_raw = p3 * 255.0 - 254.0
    knee_adj = knee_raw / (p3 - 1.0)
    result = round(knee_adj)
    if result <= 0.0:
        result = knee_raw
    return result / 255.0


def reconstruct(mask: np.ndarray, edr_scale: float,
                edr_version: float) -> np.ndarray:
    """Reconstruct gain map pixels from LHDR mask.

    Args:
        mask: 2D numpy array (height, width), uint8, grayscale LHDR mask.
        edr_scale: EDR scale factor from edrScaleCalculator.
        edr_version: f[0] from LHDR metadata (determines knee vs log2 path).

    Returns:
        2D numpy array (height, width), uint8, ISO gain map.
    """
    height, width = mask.shape
    mask_f = mask.astype(np.float32) / 255.0

    # LUT chain (same as XDRemux Swift)
    lut0 = _make_lut(1001, lambda x: x ** 0.625)
    lut1 = _make_lut(1001, lambda x: x ** 2.2)

    gamma_factor = (1.0 / edr_scale) ** (1.0 / 2.2)
    headroom_scale = (1.0 - gamma_factor) / max(gamma_factor, 0.001)
    max_boost = max(edr_scale, 2.0) if edr_scale > 1.0 else 2.0
    log2_scale = 255.0 / math.log2(max(edr_scale, 1.01))

    lut2 = _make_lut(1001, lambda x: (x * headroom_scale + 1.0) ** 2.2)

    if edr_version >= 3.0:
        knee = 0.0
    else:
        knee = _get_knee_point(edr_scale)
    knee_range = 1.0 - knee if knee < 1.0 else 0.001

    def lut3_fn(x):
        if x <= 0.0:
            return 0.0
        return log2_scale * math.log2(min(max(x, 1.0), max_boost))
    lut3 = _make_lut(8001, lut3_fn)

    # Per-pixel reconstruction (vectorized)
    lin_gray = lut0[np.clip((mask_f * 1000.0).astype(np.int32), 0, 1000)]

    below_knee = lin_gray < knee
    t = np.where(below_knee, 0.0, (lin_gray - knee) / knee_range)
    t_idx = np.clip((t * 1000.0).astype(np.int32), 0, 1000)
    linear = lut1[t_idx]
    l2_idx = np.clip((linear * 1000.0).astype(np.int32), 0, 1000)
    boosted = np.where(below_knee, 1.0, lut2[l2_idx])

    l3_idx = np.clip((np.minimum(boosted, 8.0) * 1000.0).astype(np.int32), 0, 8000)
    gainmap = lut3[l3_idx]

    return np.clip(np.round(gainmap), 0, 255).astype(np.uint8)
