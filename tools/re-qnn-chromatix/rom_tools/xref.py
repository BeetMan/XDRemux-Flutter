"""Find aarch64 code referencing a string (ADRP+ADD pairs). python tools/xref.py <lib> <substring>"""
import sys

from elftools.elf.elffile import ELFFile

lib, needle = sys.argv[1], sys.argv[2].encode()
f = open(lib, "rb")
e = ELFFile(f)
data = open(lib, "rb").read()


def off2va(o):
    for s in e.iter_segments():
        if s["p_type"] == "PT_LOAD" and s["p_offset"] <= o < s["p_offset"] + s["p_filesz"]:
            return o - s["p_offset"] + s["p_vaddr"]


targets = set()
i = data.find(needle)
while i >= 0:
    st = data.rfind(b"\0", 0, i) + 1
    targets.add(off2va(st))
    i = data.find(needle, i + 1)
print("strings at", [hex(t) for t in targets])
tx = e.get_section_by_name(".text")
base, code = tx["sh_addr"], tx.data()
n = len(code) // 4
w = memoryview(code).cast("I")
for k in range(n - 1):
    a = w[k]
    if (a & 0x9F000000) != 0x90000000:
        continue
    rd = a & 31
    imm = ((a >> 29) & 3) | (((a >> 5) & 0x7FFFF) << 2)
    if imm & (1 << 20):
        imm -= 1 << 21
    pc = base + 4 * k
    page = (pc & ~0xFFF) + (imm << 12)
    for j in range(k + 1, min(k + 6, n)):
        b = w[j]
        if (b & 0xFFC00000) == 0x91000000 and ((b >> 5) & 31) == rd:
            if page + ((b >> 10) & 0xFFF) in targets:
                print(hex(pc))
            break
