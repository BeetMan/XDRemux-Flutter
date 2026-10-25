"""Content signature of .mem dumps: sha1 of all non-pointer 8-byte words, chunk-order independent."""
import glob, hashlib, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from memdump import load

def sig(path):
    parts = []
    for a, b in load(path):
        u = np.frombuffer(b[: len(b) // 8 * 8], "<u8").copy()
        u[(u >> 48) == 0xB400] = 0
        u[(u >> 40) == 0x40] = 0          # untagged heap / lib pointers
        parts.append(hashlib.sha1(u.tobytes()).hexdigest())
    return hashlib.sha1("".join(sorted(parts)).encode()).hexdigest()[:10]

if __name__ == "__main__":
    root = sys.argv[1]
    rows = {}
    for f in sorted(glob.glob(os.path.join(root, "*", "*.mem"))):
        spec = os.path.basename(os.path.dirname(f)); mod = os.path.basename(f).split("@")[0]
        rows.setdefault(mod, {})[spec] = sig(f)
    for mod, d in rows.items():
        print(mod)
        for spec, s in d.items(): print(f"   {spec:24s} {s}")
