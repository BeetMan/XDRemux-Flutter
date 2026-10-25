"""Compare two module dumps by leaf contents (ignoring pointers). Prints SAME or #leaves differing."""
import sys
import numpy as np
from cxtree import Mem, roots, tree


def leaves(p):
    m = Mem(p)
    return [(path, b) for o, r in roots(m) for path, _, b in tree(m, r)]


a, b = leaves(sys.argv[1]), leaves(sys.argv[2])
if len(a) != len(b):
    print(f"DIFF structure {len(a)} vs {len(b)} leaves"); sys.exit()
n = sum(1 for (pa, x), (pb, y) in zip(a, b) if x != y or pa != pb)
print("SAME" if n == 0 else f"DIFF {n}/{len(a)} leaves")
