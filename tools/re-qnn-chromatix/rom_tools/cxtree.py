"""Walk a chromatix module dump (.mem) as a trigger tree.

Region arrays are chunks made of 0x30-byte records:
  +0x00 u32 trigger type   +0x08 f32 start  +0x0c f32 end
  +0x18 ptr child          (child = nested region array or leaf data)
Prints the tree; leaves are summarised (or returned by `tree()`).
"""
import struct
import sys

import numpy as np

from memdump import load


class Mem:
    def __init__(self, path):
        self.chunks = load(path)
        self.by = {a: b for a, b in self.chunks}

    def get(self, p):
        return self.by.get(p)


def is_region_array(b):
    """0x30-byte records: +0 type, +8/+0xc start/end, +0x10/+0x18 child count/ptr,
    +0x20/+0x28 data count/ptr (exactly one of the two pointers is set)."""
    if len(b) == 0 or len(b) % 0x30:
        return False
    for o in range(0, len(b), 0x30):
        t = struct.unpack_from("<I", b, o)[0]
        s, e = struct.unpack_from("<ff", b, o + 8)
        pc = struct.unpack_from("<Q", b, o + 0x18)[0]
        pd = struct.unpack_from("<Q", b, o + 0x28)[0]
        ok_ptr = ((pc >> 48) == 0xB400) != ((pd >> 48) == 0xB400)
        if t > 64 or not (np.isfinite(s) and np.isfinite(e)) or s > e or not ok_ptr:
            return False
    return True


def tree(m, p, depth=0, path=()):
    """Yield (path, leaf_bytes) where path = ((type, start, end), ...)."""
    b = m.get(p)
    if b is None:
        return
    if is_region_array(b):
        for o in range(0, len(b), 0x30):
            t = struct.unpack_from("<I", b, o)[0]
            s, e = struct.unpack_from("<ff", b, o + 8)
            c = struct.unpack_from("<Q", b, o + 0x18)[0]
            if (c >> 48) != 0xB400:
                c = struct.unpack_from("<Q", b, o + 0x28)[0]
            yield from tree(m, c, depth + 1, path + ((t, s, e),))
    else:
        yield path, p, b


def roots(m):
    """Pointers held by the module struct (node chunk after 0x68)."""
    a, b = m.chunks[0]
    out = []
    for o in range(0x68, len(b) - 7, 8):
        v = struct.unpack_from("<Q", b, o)[0]
        if (v >> 48) == 0xB400 and v in m.by:
            out.append((o, v))
    return out


if __name__ == "__main__":
    m = Mem(sys.argv[1])
    for o, r in roots(m):
        print(f"root @+{o:#x}")
        for path, p, b in tree(m, r):
            f = np.frombuffer(b[: len(b) // 4 * 4], "<f4")
            desc = " / ".join(f"t{t}[{s:g},{e:g}]" for t, s, e in path)
            print(f"   {desc:60s} leaf {len(b):5d}B  f[:6]={np.round(f[:6], 4)}")
