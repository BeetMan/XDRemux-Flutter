"""Small AArch64 ELF analysis helper (capstone + lief + pyelftools).

  python a64.py LIB xref  <regex>        functions referencing strings matching regex
  python a64.py LIB func  <addr|name>    annotated disassembly of the function containing addr
  python a64.py LIB calls <addr>         functions that BL to addr
  python a64.py LIB funcs                list function ranges (from .eh_frame)
"""
import bisect
import re
import sys

import capstone
import lief
import numpy as np
from elftools.elf.elffile import ELFFile


class Lib:
    def __init__(self, path):
        self.path = path
        self.raw = open(path, "rb").read()
        self.b = lief.parse(path)
        self.segs = [(s.virtual_address, s.file_offset, s.physical_size) for s in self.b.segments
                     if s.type == lief.ELF.Segment.TYPE.LOAD]
        text = self.b.get_section(".text")
        self.text_va, self.text_off, self.text_sz = text.virtual_address, text.file_offset, text.size
        self.names = {}
        for s in self.b.symbols:
            if s.value and s.name:
                self.names.setdefault(s.value, s.name)
        plt = self.b.get_section(".plt")
        self.plt = (plt.virtual_address, plt.virtual_address + plt.size) if plt else (0, 0)
        self.got_names = {}
        for r in self.b.pltgot_relocations:
            if r.has_symbol:
                self.got_names[r.address] = r.symbol.name
        for r in self.b.dynamic_relocations:
            if r.has_symbol and r.symbol.name:
                self.got_names.setdefault(r.address, r.symbol.name)
        self._funcs = None
        self.cs = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
        self.cs.detail = False

    # -- memory -------------------------------------------------------------
    def off(self, va):
        for v, o, n in self.segs:
            if v <= va < v + n:
                return o + va - v
        return None

    def read(self, va, n):
        o = self.off(va)
        return None if o is None else self.raw[o:o + n]

    def cstr(self, va, maxn=200):
        d = self.read(va, maxn)
        if not d:
            return None
        d = d.split(b"\0")[0]
        if len(d) >= 3 and all(32 <= c < 127 or c in (9, 10) for c in d):
            return d.decode()
        return None

    # -- functions ----------------------------------------------------------
    def funcs(self):
        if self._funcs is None:
            # .eh_frame_hdr binary-search table (sdata4|datarel), then each FDE's
            # pc_begin (sdata4|pcrel) / pc_range (sdata4) for the extent.
            fs = []
            hdr = self.b.get_section(".eh_frame_hdr")
            if hdr:
                base = hdr.virtual_address
                d = self.read(base, hdr.size)
                cnt = int.from_bytes(d[8:12], "little")
                tab = np.frombuffer(d, np.int32, cnt * 2, 12).reshape(-1, 2)
                for loc, fde in tab:
                    fva = base + int(fde)
                    rng = int.from_bytes(self.read(fva + 12, 4), "little")
                    fs.append((base + int(loc), rng))
            fs.sort()
            self._funcs = fs
            self._starts = [a for a, _ in fs]
        return self._funcs

    def func_of(self, va):
        self.funcs()
        i = bisect.bisect_right(self._starts, va) - 1
        if i >= 0 and self._funcs[i][0] <= va < sum(self._funcs[i]):
            return self._funcs[i]
        return None

    def plt_name(self, va):
        """Resolve a PLT stub target to its symbol name."""
        if not (self.plt[0] <= va < self.plt[1]):
            return None
        code = self.read(va, 16)
        ins = list(self.cs.disasm(code, va))
        if len(ins) >= 2 and ins[0].mnemonic == "adrp":
            page = int(ins[0].op_str.split("#")[1], 16)
            m = re.search(r"#(0x[0-9a-f]+)\]", ins[1].op_str)
            if m:
                return self.got_names.get(page + int(m.group(1), 16))
        return None

    def name(self, va):
        return self.names.get(va) or self.plt_name(va)

    # -- vectorised scans over .text ------------------------------------------
    def words(self):
        w = np.frombuffer(self.raw, np.uint32, self.text_sz // 4, self.text_off)
        pc = self.text_va + 4 * np.arange(len(w), dtype=np.int64)
        return w, pc

    def adrp_targets(self):
        """Yield (pc, target) for ADRP followed (within 4 ins) by ADD/LDR on same reg."""
        w, pc = self.words()
        isadrp = (w & 0x9F000000) == 0x90000000
        idx = np.nonzero(isadrp)[0]
        a = w[idx].astype(np.int64)
        immlo = (a >> 29) & 3
        immhi = (a >> 5) & 0x7FFFF
        imm = (immhi << 2) | immlo
        imm = np.where(imm & (1 << 20), imm - (1 << 21), imm)
        page = (pc[idx] & ~0xFFF) + (imm << 12)
        rd = a & 31
        res = []
        for k in range(1, 5):
            j = idx + k
            ok = j < len(w)
            jj = np.where(ok, j, 0)
            n = w[jj].astype(np.int64)
            rn = (n >> 5) & 31
            is_add = ((n & 0xFF800000) == 0x91000000) & (rn == rd)
            add_imm = ((n >> 10) & 0xFFF) << np.where((n >> 22) & 1, 12, 0)
            is_ldr = ((n & 0xFFC00000) == 0xF9400000) & (rn == rd)
            ldr_imm = ((n >> 10) & 0xFFF) * 8
            is_ldrs = ((n & 0xFFC00000) == 0xBD400000) & (rn == rd)  # ldr s
            ldrs_imm = ((n >> 10) & 0xFFF) * 4
            is_ldrq = ((n & 0xFFC00000) == 0x3DC00000) & (rn == rd)  # ldr q
            ldrq_imm = ((n >> 10) & 0xFFF) * 16
            for m, im in ((is_add, add_imm), (is_ldr, ldr_imm), (is_ldrs, ldrs_imm), (is_ldrq, ldrq_imm)):
                sel = ok & m
                res.append(np.stack([pc[j[sel]], page[sel] + im[sel]], 1))
        return np.concatenate(res)

    def bl_targets(self):
        w, pc = self.words()
        sel = (w & 0xFC000000) == 0x94000000
        a = w[sel].astype(np.int64) & 0x3FFFFFF
        a = np.where(a & (1 << 25), a - (1 << 26), a)
        return pc[sel], pc[sel] + a * 4

    # -- disassembly ----------------------------------------------------------
    def disasm(self, start, size):
        code = self.read(start, size)
        regs = {}
        out = []
        for ins in self.cs.disasm(code, start):
            note = ""
            ops = ins.op_str
            if ins.mnemonic == "adrp":
                regs[ops.split(",")[0]] = int(ops.split("#")[1], 16)
            elif ins.mnemonic in ("add", "ldr", "ldrb", "ldrh", "ldrsw", "str") and "#" in ops:
                parts = [p.strip() for p in ops.replace("[", "").replace("]", "").split(",")]
                if len(parts) >= 3 and parts[1] in regs:
                    try:
                        tgt = regs[parts[1]] + int(parts[2].lstrip("#"), 16 if "0x" in parts[2] else 10)
                    except ValueError:
                        tgt = None
                    if tgt is not None:
                        s = self.cstr(tgt) if ins.mnemonic == "add" else None
                        if s:
                            note = f'  ; "{s[:120]}"'
                        else:
                            nm = self.got_names.get(tgt) or self.names.get(tgt)
                            note = f"  ; ={tgt:#x}" + (f" <{nm}>" if nm else "")
                            if ins.mnemonic == "ldr" and parts[0].startswith(("s", "d", "q")):
                                d = self.read(tgt, 8)
                                if d:
                                    if parts[0].startswith("s"):
                                        note += f" f32={np.frombuffer(d[:4], np.float32)[0]:g}"
                                    elif parts[0].startswith("d"):
                                        note += f" f64={np.frombuffer(d, np.float64)[0]:g}"
            elif ins.mnemonic in ("bl", "b") and ops.startswith("#"):
                t = int(ops[1:], 16)
                nm = self.name(t)
                if nm:
                    note = f"  ; <{nm}>"
            elif ins.mnemonic in ("fmov",) and "#" in ops:
                pass
            out.append(f"{ins.address:08x}  {ins.mnemonic:8s} {ops}{note}")
        return out


def parse_addr(lib, s):
    if re.match(r"^(0x)?[0-9a-fA-F]+$", s):
        return int(s, 16)
    for a, n in lib.names.items():
        if n == s:
            return a
    raise SystemExit("unknown symbol " + s)


def main():
    lib = Lib(sys.argv[1])
    cmd = sys.argv[2]
    if cmd == "xref":
        pat = re.compile(sys.argv[3])
        hits = {}
        for pc, t in lib.adrp_targets():
            s = lib.cstr(int(t))
            if s and pat.search(s):
                f = lib.func_of(int(pc))
                hits.setdefault(f[0] if f else 0, []).append((int(pc), s))
        for f, lst in sorted(hits.items()):
            print(f"func {f:#x}:")
            for pc, s in lst:
                print(f"   {pc:#x}  {s[:140]!r}")
    elif cmd == "func":
        a = parse_addr(lib, sys.argv[3])
        f = lib.func_of(a) or (a, int(sys.argv[4], 16) if len(sys.argv) > 4 else 0x400)
        print(f"; function {f[0]:#x} size {f[1]:#x} {lib.names.get(f[0], '')}")
        print("\n".join(lib.disasm(f[0], f[1])))
    elif cmd == "calls":
        a = parse_addr(lib, sys.argv[3])
        src, dst = lib.bl_targets()
        for pc in src[dst == a]:
            f = lib.func_of(int(pc))
            print(f"{int(pc):#x} in func {f[0] if f else 0:#x}")
    elif cmd == "funcs":
        for a, n in lib.funcs():
            print(f"{a:#x} {n:#x} {lib.names.get(a, '')}")


if __name__ == "__main__":
    main()
