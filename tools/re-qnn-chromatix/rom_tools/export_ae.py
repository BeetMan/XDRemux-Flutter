"""Export the M9 (feature0=Legend) AE tables from mi_tuning to m9/assets/ae_m9.json.

Keys used (see FINDINGS.md):
  AEC_Metering   (mode 1, any scenario, Legend)  - every sensor mode links here for Legend
  AEC_Stylization(mode 37, Legend)                - Legend style scale (modes 37/42)
  AEC_LumaCalculation (default), AEC_DrcConfig (default) - not overridden for Legend
"""
import json
import sys

from mituning import AEC_NAMES, load_pool, module_table

P = sys.argv[1]
pool = load_pool("../re/miaec/aec.pb")
L = (1, -1, 7, -1, -1, -1, -1)
D = (-1,) * 7
pick = {
    "metering": (536, L), "stylization": (550, (37, -1, 7, -1, -1, -1, -1)),
    "luma": (534, D), "drc": (524, D), "whiteblack": (552, L),
    "metering_normal": (536, D),
}
out = {}
for name, (mod, key) in pick.items():
    out[name] = module_table(P, mod, pool)[key]
    print(name, AEC_NAMES[mod], key, len(out[name]))
json.dump(out, open(sys.argv[2], "w"), separators=(",", ":"))
