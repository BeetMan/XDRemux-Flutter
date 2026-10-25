"""Minimal `strings`: python strs.py file [minlen] [regex]"""
import re
import sys

data = open(sys.argv[1], "rb").read()
n = int(sys.argv[2]) if len(sys.argv) > 2 else 6
pat = re.compile(sys.argv[3]) if len(sys.argv) > 3 else None
for m in re.finditer(rb"[\x20-\x7e]{%d,}" % n, data):
    s = m.group().decode()
    if pat is None or pat.search(s):
        print(f"{m.start():08x} {s}")
