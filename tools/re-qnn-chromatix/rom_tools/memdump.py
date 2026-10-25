"""Read .mem dumps written by emu/chromatix and summarise their chunks.

  python memdump.py file.mem            chunk list with float/int heuristics
  python memdump.py file.mem ADDR [fmt] hexdump / float view of one chunk
"""
import struct
import sys

import numpy as np


def load(path):
    d = open(path, "rb").read()
    out, o = [], 0
    while o + 12 <= len(d):
        a, n = struct.unpack_from("<QI", d, o)
        out.append((a, d[o + 12:o + 12 + n]))
        o += 12 + n
    return out


def ptrs(buf):
    u = np.frombuffer(buf[: len(buf) // 8 * 8], "<u8")
    return [(i * 8, int(v)) for i, v in enumerate(u) if (int(v) >> 48) == 0xB400]


def summary(buf):
    f = np.frombuffer(buf[: len(buf) // 4 * 4], "<f4")
    fin = np.isfinite(f) & (np.abs(f) < 1e6) & ((np.abs(f) > 1e-6) | (f == 0))
    mono = np.mean(np.diff(f[fin]) >= 0) if fin.sum() > 4 else 0
    return f"floatlike={fin.mean():.2f} mono={mono:.2f} ptrs={len(ptrs(buf))}"


if __name__ == "__main__":
    ch = load(sys.argv[1])
    if len(sys.argv) == 2:
        for i, (a, b) in enumerate(ch):
            print(f"{i:3d} {a:#x} len={len(b):6d} {summary(b)}")
    else:
        idx = int(sys.argv[2])
        a, b = ch[idx]
        fmt = sys.argv[3] if len(sys.argv) > 3 else "f"
        np.set_printoptions(linewidth=160, precision=5, suppress=True, threshold=100000)
        if fmt == "f":
            print(np.frombuffer(b[: len(b) // 4 * 4], "<f4"))
        elif fmt == "i":
            print(np.frombuffer(b[: len(b) // 4 * 4], "<i4"))
        else:
            for o in range(0, len(b), 16):
                print(f"{o:05x} {b[o:o + 16].hex(' ')}")
