"""Decoders for HTP tensor bodies (interface, shape, block table).

Mirrors (libQnnHtpPrepare.so):
  LayoutTensor<...>::LayoutTensor(Deserz&)   interface -> Shape<4> -> DynamicShape -> blocktable
  Tensor::deserialize_blocktable_generic
  fa::RuntimeAllocator::deserialize_blocks
Block addresses are returned as (pool, offset); pool 'T' = TCM packed base.
"""
import numpy as np


class Stream:
    def __init__(self, words, pos=0):
        self.w = words
        self.p = pos

    def next(self):
        v = int(self.w[self.p])
        self.p += 1
        return v

    def peek(self):
        return int(self.w[self.p])


def read_blocks(s: Stream, count: int):
    out = []
    cur_pool = None
    last = None
    while len(out) < count:
        w = s.next()
        if not (w & 1):
            if cur_pool is None:
                raise ValueError("relative block without pool")
            last = (cur_pool, w)
            out.append(last)
        elif not (w & 2):
            pool = (w >> 22) & 0x3FF
            off = (w << 6) & 0x0FFFFF00
            if pool:
                cur_pool = pool
                last = (pool, off)
                out.append(last)
            else:
                n = off >> 8
                if n == 0:
                    out.append(None)
                else:
                    out += [("fill", 2)] * n
                cur_pool = None
        elif not (w & 4):
            v = s.next()
            if w <= 7:
                n = v >> 16
                step = np.int16(v & 0xFFFF).item()
                for _ in range(max(n, 1)):
                    last = (last[0], last[1] + step)
                    out.append(last)
            else:
                cur_pool = w >> 3
                last = (cur_pool, v)
                out.append(last)
        elif not (w & 8):
            k = (w >> 4) & 0xF
            vals = [((w >> 8) & 0xFFF) << 11, ((w >> 20) & 0xFFF) << 11]
            ext = [s.next() for _ in range(k)]
            i = 0
            while k - i >= 3:
                w0, w1, w2 = ext[i:i + 3]
                vals += [(w0 & 0xFFF) << 11, ((w0 >> 12) & 0xFFF) << 11,
                         ((w0 >> 24) | ((w1 & 0xF) << 8)) << 11, ((w1 >> 4) & 0xFFF) << 11,
                         ((w1 >> 16) & 0xFFF) << 11, ((w1 >> 28) | ((w2 & 0xFF) << 4)) << 11,
                         ((w2 >> 8) & 0xFFF) << 11, ((w2 >> 20) & 0xFFF) << 11]
                i += 3
            rem = k - i
            if rem >= 1:
                w0 = ext[i]
                vals += [(w0 & 0xFFF) << 11, ((w0 >> 12) & 0xFFF) << 11]
            if rem == 2:
                w0, w1 = ext[i], ext[i + 1]
                vals += [((w0 >> 24) | ((w1 & 0xF) << 8)) << 11, ((w1 >> 4) & 0xFFF) << 11,
                         ((w1 >> 16) & 0xFFF) << 11]
            for v in vals:
                last = (1, v)          # packed TCM addresses are relative to pool 1
                out.append(last)
            cur_pool = 1
        else:
            raise ValueError(f"bad block encoding {w:#x}")
    return out[:count]


class BlockTables:
    def __init__(self):
        self.slots = {}

    def read(self, s: Stream):
        """Returns (blocks, link) where link = (slot, offset) or None."""
        w = s.next()
        count = (w >> 14) & 0x3FFF
        if w & 0x08002000:
            if (w & 0x3FFF) == 0x3FFF:
                s.next()
            if count == 0x3FFF:
                count = s.next()
        link = None
        if w & 0x40000000:
            v = s.next()
            if v & 0x80000000:
                slot = v & 0x7FFFFFFF
                off = s.next()
            else:
                slot, off = v >> 16, v & 0xFFFF
            link = (slot, off)
        if count:
            blocks = read_blocks(s, count)
            if link:
                self.slots[link[0]] = blocks
            return blocks, link
        if link and link[0] in self.slots:
            return self.slots[link[0]][link[1]:], link
        return None, link


def read_block_pointer(s: Stream):
    """Tensor::deserialize_block_pointer (flat tensors)."""
    w = s.next()
    if w >> 30:
        return (w & 0x0FFFFFFF, s.next())
    if w == 0:
        return None
    return (w >> 16, (w & 0xFFFF) << 6)


class Objs:
    """Interface (quant) / shape object definitions shared via ids."""

    def __init__(self):
        self.o = {}

    def interface(self, s: Stream):
        v = s.next()
        if v & 0x80000000:
            zp = np.int32(s.next()).item()
            sc = np.frombuffer(np.uint32(s.next()).tobytes(), np.float32)[0].item()
            self.o[v & 0x7FFFFFFF] = ("q", zp, sc)
            return (zp, sc)
        o = self.o.get(v)
        return (o[1], o[2]) if o and o[0] == "q" else ("ref", v)

    def shape(self, s: Stream, rank=4):
        v = s.next()
        if v & 0x80000000:
            if s.peek() == 0xCCCC0001:
                s.next()
            fl = s.next()
            dims, alloc, offs = [], [], []
            for n in range(rank):
                nib = (fl >> (4 * n)) & 0xF
                pre = s.next() if nib & 8 else None
                mode = nib & 3
                if mode == 0:
                    d, a, o = 1, 1, 0
                else:
                    w = s.next()
                    if mode == 1:
                        d, a, o = w & 0xFFFF, (w & 0xFFFF) + ((w >> 16) & 0xFF), w >> 24
                    elif mode == 2:
                        d, a, o = w & 0xFFFFFF, w & 0xFFFFFF, w >> 24
                    else:
                        d, a, o = w, w, 0
                if nib & 4:
                    a = s.next()
                if pre is not None:
                    o = pre
                dims.append(d); alloc.append(a); offs.append(o)
            self.o[v & 0x7FFFFFFF] = ("s", fl, dims, alloc, offs)
            self.last_alloc, self.last_offs = alloc, offs
            return dims
        o = self.o.get(v)
        if o and o[0] == "s":
            self.last_alloc, self.last_offs = o[3], o[4]
            return o[2]
        return ("ref", v)
