"""Pack OffLineM9 .npz weights into compact lossless .m9w binary format for xdremux-core.

Each conv layer is stored as (scale_f64[cout], bias_f32[cout], lo_f32, hi_f32, q_int8[cout,cin,kh,kw]),
which reconstructs the exact IEEE-754 float32 weights W = (q * scale).astype(float32) with 0.0 bit error.
"""
from __future__ import annotations

import os
import shutil
import struct
import sys
import numpy as np


def pack_npz(npz_path: str, out_path: str) -> None:
    z = np.load(npz_path)
    layers = sorted({k.split("/")[0] for k in z.files if k.endswith("/W")})
    up1 = float(z["tail_up1_conv_transpose/gain"][0]) if "tail_up1_conv_transpose/gain" in z.files else 1.0
    up2 = float(z["tail_up2_conv_transpose/gain"][0]) if "tail_up2_conv_transpose/gain" in z.files else 1.0

    buf = bytearray()
    buf.extend(b"M9WT")
    buf.extend(struct.pack("<IffI", 1, up1, up2, len(layers)))

    for l in layers:
        W = z[l + "/W"].astype(np.float32)
        b = np.ascontiguousarray(z[l + "/b"], dtype="<f4")
        q = np.ascontiguousarray(z[l + "/q"], dtype=np.int8)
        F = z[l + "/F"].astype(np.float64)
        s_out = float(z[l + "/s_out"])
        zp_out = float(z[l + "/zp_out"])
        s_in = float(z[l + "/s_in"])

        cout, cin, kh, kw = W.shape
        assert q.shape == (cout, cin, kh, kw), f"shape mismatch on {l}: {q.shape} vs {W.shape}"
        assert b.shape == (cout,), f"bias shape mismatch on {l}: {b.shape}"

        Fr = np.tile(F, max(1, cout // len(F)))[:cout]
        sc64 = np.ascontiguousarray(Fr * s_out / s_in, dtype="<f8")
        W_rec = (q.astype(np.float64) * sc64[:, None, None, None]).astype(np.float32)
        max_diff = float(np.abs(W - W_rec).max())
        assert max_diff == 0.0, f"{l}: non-zero reconstruction diff {max_diff}"

        lo = float((0.0 - zp_out) * s_out)
        hi = float((65535.0 - zp_out) * s_out)
        name_bytes = l.encode("utf-8")
        buf.extend(struct.pack("<H", len(name_bytes)))
        buf.extend(name_bytes)
        buf.extend(struct.pack("<HHBBff", cout, cin, kh, kw, lo, hi))
        buf.extend(sc64.tobytes())
        buf.extend(b.tobytes())
        buf.extend(q.tobytes())

    with open(out_path, "wb") as f:
        f.write(buf)
    print(f"Packed {os.path.basename(out_path)}: {len(layers)} layers, {len(buf) / 1e6:.2f} MB")


def main() -> None:
    src_root = sys.argv[1]
    dst_dir = sys.argv[2]
    os.makedirs(dst_dir, exist_ok=True)
    for name in ("low", "high", "colorfix"):
        pack_npz(
            os.path.join(src_root, "re", "weights", f"{name}.npz"),
            os.path.join(dst_dir, f"{name}.m9w"),
        )
    assets_src = os.path.join(src_root, "m9", "assets")
    for fn in (
        "ae_m9.json",
        "ae_tele.json",
        "ipe_tables.json",
        "leica_filter_param_m9_preview.bin",
        "leica_filter_param_m9_snapshot.bin",
        "display_p3.icc",
        "styletrans_params.json",
    ):
        shutil.copy2(os.path.join(assets_src, fn), os.path.join(dst_dir, fn))
        print(f"Copied {fn}")


if __name__ == "__main__":
    main()
