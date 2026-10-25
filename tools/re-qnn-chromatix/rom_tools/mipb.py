"""Generic decoder for Xiaomi mi_tuning *.bin (sequence of u32-length-prefixed protobuf messages).

  python mipb.py FILE              list top-level records (index, offset, len, summary)
  python mipb.py FILE IDX [depth]  dump one record as a field tree
"""
import struct
import sys


def varint(b, i):
    r = s = 0
    while True:
        c = b[i]; i += 1
        r |= (c & 0x7f) << s; s += 7
        if c < 0x80:
            return r, i


def parse(b):
    """Return list of (field, wiretype, value) or None if b is not a valid message."""
    out, i = [], 0
    try:
        while i < len(b):
            k, i = varint(b, i)
            f, wt = k >> 3, k & 7
            if f == 0:
                return None
            if wt == 0:
                v, i = varint(b, i)
            elif wt == 1:
                v = b[i:i + 8]; i += 8
            elif wt == 2:
                n, i = varint(b, i); v = b[i:i + n]; i += n
                if i > len(b):
                    return None
            elif wt == 5:
                v = b[i:i + 4]; i += 4
            else:
                return None
            out.append((f, wt, v))
    except IndexError:
        return None
    return out if i == len(b) else None


def records(data, o=4):
    """File = u32 header count, then u32-length-prefixed messages."""
    while o + 4 <= len(data):
        n = struct.unpack_from("<I", data, o)[0]
        if n == 0 or o + 4 + n > len(data):
            break
        yield o, data[o + 4:o + 4 + n]
        o += 4 + n


def fmt(v, wt):
    if wt == 0:
        return str(v if v < 1 << 63 else v - (1 << 64))
    if wt == 5:
        return f"f{struct.unpack('<f', v)[0]:g}"
    if wt == 1:
        return f"d{struct.unpack('<d', v)[0]:g}"
    return None


def packed_floats(v):
    if len(v) % 4 == 0 and len(v) >= 8:
        f = struct.unpack(f"<{len(v)//4}f", v)
        if all(abs(x) < 1e7 and (x == 0 or abs(x) > 1e-7) for x in f):
            return f
    return None


def dump(b, depth=0, maxd=20, out=print):
    msg = parse(b)
    for f, wt, v in msg:
        pad = "  " * depth
        s = fmt(v, wt)
        if s is not None:
            out(f"{pad}{f}: {s}")
            continue
        sub = parse(v) if v else None
        txt = None
        if v and all(32 <= c < 127 for c in v):
            txt = v.decode()
        if txt is not None and (sub is None or len(v) < 40):
            out(f"{pad}{f}: '{txt}'")
        elif sub is not None and depth < maxd:
            out(f"{pad}{f} {{")
            dump(v, depth + 1, maxd, out)
            out(f"{pad}}}")
        else:
            pf = packed_floats(v)
            out(f"{pad}{f}: " + (f"floats[{len(pf)}] {[round(x, 4) for x in pf[:64]]}" if pf else f"bytes[{len(v)}] {v[:32].hex()}"))


if __name__ == "__main__":
    data = open(sys.argv[1], "rb").read()
    recs = list(records(data))
    if len(sys.argv) == 2:
        for k, (o, b) in enumerate(recs):
            m = parse(b)
            strs = []
            if m:
                for f, wt, v in m:
                    if wt == 2 and v and all(32 <= c < 127 for c in v) and len(v) < 40:
                        strs.append(v.decode())
            print(f"{k:5d} @{o:#x} len={len(b):7d} ok={m is not None} {' '.join(strs[:8])}")
        print("end", hex(sum(4 + len(b) for _, b in recs)), "file", hex(len(data)))
    else:
        dump(recs[int(sys.argv[2])][1], maxd=int(sys.argv[3]) if len(sys.argv) > 3 else 20)
