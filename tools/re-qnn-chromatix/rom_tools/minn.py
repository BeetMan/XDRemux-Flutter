"""Decrypt Xiaomi .minn (header 'NNiM', format 1) -> QNN context binary.

  python minn.py in.minn out.bin
Layout: 0x1E-byte header, then payload XOR key b"legend" + b"d"*10 (period 16, from payload start).
"""
import sys

import numpy as np

KEY = np.frombuffer(b"legend" + b"d" * 10, np.uint8)

d = open(sys.argv[1], "rb").read()
assert d[:4] == b"NNiM", d[:4]
fmt = int.from_bytes(d[8:10], "little")
p = np.frombuffer(d[0x1E:], np.uint8)
out = p ^ np.resize(KEY, p.size)
open(sys.argv[2], "wb").write(out.tobytes())
print(sys.argv[1], "fmt", fmt, "->", len(out), "bytes; head", out[:32].tobytes().hex())
