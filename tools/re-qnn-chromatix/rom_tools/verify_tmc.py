"""Compare m9.tmc against the original TMC202 code run under qemu (emu/tmc).
  python tools/verify_tmc.py"""
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from m9 import tmc, tuning  # noqa: E402

ROOT = "F:/OffLineM9-pipeline"
worst = 0.0
CASES = [tuple(map(float, a.split(","))) for a in sys.argv[1:]] or [(l, d) for l in (150, 200, 300, 380, 450) for d in (1.0, 1.15, 1.6, 2.5, 4.5)]
for lux, drc in CASES:
    if True:
        pass
        leaf = tuning.lookup("m9", "tmc202_sw_v2", drc=drc, gain=1.0, lux=lux).astype(np.float32)
        h = np.zeros(1024, np.uint32); h[200] = 1000
        hdr = np.array([drc, 1.0, lux, lux], np.float32)
        open(f"{ROOT}/re/tmc_in.bin", "wb").write(hdr.tobytes() + leaf.tobytes() + h.tobytes())
        subprocess.run(["wsl", "-d", "Ubuntu-24.04", "-u", "root", "bash", "/mnt/f/OffLineM9-pipeline/tools/qrun_ns.sh",
                        "/mnt/f/OffLineM9-pipeline/emu/tmc", "/wide_i.bin", "0=0,1=1,2=1,3=7",
                        "/mnt/f/OffLineM9-pipeline/re/tmc_in.bin", "/mnt/f/OffLineM9-pipeline/re/tmc_out.bin"],
                       capture_output=True, env={**os.environ, "MSYS_NO_PATHCONV": "1"})
        st = np.frombuffer(open(f"{ROOT}/re/tmc_out.bin", "rb").read()[:0x2000], "<f4")
        Xo, Yo, Co = st[8:15], st[15:22], st[0x32:0x32 + 15]
        X, Y = tmc.anchor_knees(leaf, drc)
        d, c2, c3 = tmc.hermite_coeffs(X, Y)
        C = np.stack([d[1:6], c2[1:6], c3[1:6]], 1).ravel()
        err = max(np.abs(X - Xo).max(), np.abs(Y - Yo).max(), np.abs(C - Co).max() / max(1, np.abs(Co).max()))
        worst = max(worst, err)
        print(f"lux {lux:4.0f} drc {drc:4.2f}  maxerr {err:.2e}  X {np.round(Xo,4)} Y {np.round(Yo,4)}")
print("WORST", worst)
