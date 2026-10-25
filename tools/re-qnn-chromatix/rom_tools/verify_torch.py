"""Cross-check TorchBackend against the exact QNN x86 HTP simulator on one real input per model."""
import glob
import sys

import cv2
import numpy as np

sys.path.insert(0, ".")
from m9 import frontend, styletrans  # noqa: E402
from m9.qnn_backend import QnnSimBackend  # noqa: E402
from m9.torch_backend import TorchBackend  # noqa: E402

models = sys.argv[1:] or ["colorfix", "low"]
dng = sorted(glob.glob("samples/*.dng"))[0]
rgb = frontend.b2y(dng, half=True).rgb
x8 = np.clip(rgb * 255 + .5, 0, 255).astype(np.uint8)
if x8.shape[0] > x8.shape[1]:
    x8 = np.rot90(x8, -1).copy()
small = cv2.resize(x8, (1024, 768), interpolation=cv2.INTER_AREA)
pad = cv2.copyMakeBorder(small, 48, 48, 48, 48, cv2.BORDER_REFLECT)
inp = {"low": np.concatenate([pad, np.zeros(pad.shape[:2] + (1,), np.uint8)], -1),
       "high": np.concatenate([pad, np.zeros(pad.shape[:2] + (1,), np.uint8)], -1)}
t = np.zeros((544, 544, 6), np.uint8)
t[:, :, :3] = cv2.resize(x8, (544, 544))[:, :, ::-1]   # stand-in "styled"
t[:, :, 3:] = cv2.resize(x8, (544, 544))
inp["colorfix"] = t
tb, qb = TorchBackend.create(), QnnSimBackend.create()
for m in models:
    a = tb.run(m, inp[m][None].astype(np.float32))[0]
    b = qb.run(m, inp[m][None].astype(np.float32))[0]
    d = np.abs(a - b)
    print(f"{m}: mean|d|={d.mean():.3f} p99={np.percentile(d, 99):.1f} max={d.max():.0f} "
          f"corr={np.corrcoef(a.ravel(), b.ravel())[0, 1]:.5f}", flush=True)
    cv2.imwrite(f"out/verify_{m}.png", np.concatenate([a, b, np.clip(d * 8, 0, 255)], 1)[:, :, ::-1].astype(np.uint8))
