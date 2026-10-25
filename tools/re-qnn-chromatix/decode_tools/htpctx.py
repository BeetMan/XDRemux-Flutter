"""Exploration helpers for decrypted QNN HTP context binaries (.minn payloads).

The HTP blob serialises an object stream; each object starts with
  u32 id   (0x1303xxxx)
  u32 kind (class << 28 | op_type_index)   op_type_index -> "Co" name table
followed by kind-specific u32 fields.
"""
import re
import struct
import sys

import numpy as np

KEY = b"legend" + b"d" * 10


def decrypt_minn(path: str) -> bytes:
    d = open(path, "rb").read()
    assert d[:4] == b"NNiM"
    body = np.frombuffer(d, np.uint8, offset=0x1E)
    k = np.resize(np.frombuffer(KEY, np.uint8), len(body))
    return (body ^ k).tobytes()


def name_table(x: bytes, tag: int):
    off = x.find(struct.pack("<I", tag))
    _, n, _, _ = struct.unpack_from("<4I", x, off)
    names = x[off + 16:off + 16 + 4096].split(b"\0")
    return [s.decode(errors="replace") for s in names[:min(n, 64)]]


def records(x: bytes, lo=0x10000, hi=None):
    """Split the object stream at aligned id/kind headers."""
    hi = hi or len(x)
    u = np.frombuffer(x[: len(x) // 4 * 4], "<u4")
    i0, i1 = lo // 4, hi // 4
    w = u[i0:i1]
    is_id = ((w >> 16) & 0x7FFF) == 0x1303   # bit31 = flagged record
    nxt = np.roll(w, -1)
    kind_ok = ((nxt >> 28) <= 7) & ((nxt & 0x0FFFFF00) == 0) & ((nxt & 0xFF) < 32)
    starts = np.nonzero(is_id & kind_ok)[0] + i0
    out = []
    for a, b in zip(starts, list(starts[1:]) + [i1]):
        out.append((int(a) * 4, int(u[a]), int(u[a + 1]), u[a + 2:b].copy()))
    return out


def node_names(x: bytes) -> dict:
    """flatbuffer-ish name table near the start: [u32 id][u32 4][u32 len][str\0]."""
    out = {}
    for m in re.finditer(rb"[A-Za-z_][A-Za-z0-9_]{2,}\x00", x[:0x10000]):
        s = m.start()
        nid, four, ln = struct.unpack_from("<3I", x, s - 12)
        if four == 4 and ln == m.end() - 1 - s:
            out[nid] = m.group()[:-1].decode()
    return out


def _rank(flags: int) -> int:
    return sum(1 for k in range(4) if (flags >> (4 * k)) & 0xF)


class ConstParser:
    """Decode Const records: node, ctype, quant (offset, scale), shape, data offset."""

    def __init__(self, fmt=None):
        self.objs = {}
        fmt = fmt or ["fB", "s4", "ni", "FB", "cB", "CB", "fi", "CH", "Fi", "cH", "xwb", "Xwb", "xpb", "Xpb", "xsb", "Xsb"]
        self.fmt = fmt
        self.qtypes = {i for i, n in enumerate(fmt) if n in ("xwb", "xpb", "xsb", "cH", "cB")}

    def _shape(self, f, i):
        v = int(f[i])
        if v & 0x80000000:
            oid = v & 0x7FFFFFFF
            assert f[i + 1] == 0xCCCC0001, hex(f[i + 1])
            flags = int(f[i + 2])
            r = _rank(flags)
            nibs = [(flags >> (4 * k)) & 0xF for k in range(4) if (flags >> (4 * k)) & 0xF]
            dims = [int(d) & 0xFFFF if (nb & 3) == 1 else int(d) for d, nb in zip(f[i + 3:i + 3 + r], nibs)]
            self.objs[oid] = ("shape", flags, dims)
            return dims, i + 3 + r
        o = self.objs[v]
        if o[0] != "shape":
            raise KeyError(v)
        return o[2], i + 1

    def _quant(self, f, i):
        v = int(f[i])
        if v & 0x80000000:
            oid = v & 0x7FFFFFFF
            zp = int(np.int32(f[i + 1]))
            sc = float(np.frombuffer(np.uint32(f[i + 2]).tobytes(), np.float32)[0])
            self.objs[oid] = ("quant", zp, sc)
            return (zp, sc), i + 3
        o = self.objs[v]
        return (o[1], o[2]), i + 1

    def parse(self, f):
        node, h, ctype = int(f[0]), int(f[1]), int(f[2])
        i = 3
        q = None
        try:
            if ctype in self.qtypes:
                q, i = self._quant(f, i)
            dims, i = self._shape(f, i)
            data = int(f[i]) if i < len(f) else None
        except (KeyError, IndexError, AssertionError):
            return None
        return dict(node=node, ctype=ctype, fmt=self.fmt[ctype] if ctype < len(self.fmt) else "?", quant=q, dims=dims, off=data, extra=[int(v) for v in f[i + 1:]])


def consts(x: bytes):
    p = ConstParser(name_table(x, 0x74438BBC))
    out = []
    const = 0x10000000 | name_table(x, 0x6F4390BC).index("Const")
    for off, rid, kind, f in records(x, 0x10000, 0x560000):
        if kind == const:
            c = p.parse(f)
            if c:
                c["rec"] = off
                c["id"] = rid
                out.append(c)
    return out


if __name__ == "__main__":
    x = decrypt_minn(sys.argv[1])
    ops = name_table(x, 0x6F4390BC)
    recs = records(x, 0x10000, 0x560000)
    import collections
    c = collections.Counter(k for _, _, k, _ in recs)
    for k, n in c.most_common():
        t = k & 0xFF
        print(f"{k:#010x} {n:6d} {ops[t] if t < len(ops) else '?'}")
