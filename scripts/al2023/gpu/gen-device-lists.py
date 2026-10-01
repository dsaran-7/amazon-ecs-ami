#!/usr/bin/env python3
"""Build-time: derive <branch>-supported.devices from each staged version's supported-gpus.json and
validate the reviewed pb-required.devices list (policy R3). usage: gen-device-lists.py LTS.json PB.json CONFDIR"""
import json, sys, os, re
lts_j, pb_j, conf = sys.argv[1:4]
def chips(p): return json.load(open(p))["chips"]
def ids(cs, need_open=False):
    out = set()
    for c in cs:
        if "legacybranch" in c:          # 590+ JSONs rewrite legacy entries' features to ['kernelopen'] (EKS ffc658f8)
            continue
        if need_open and "kernelopen" not in c.get("features", []):
            continue
        out.add(c["devid"].lower().replace("0x", ""))
    return out
lts = ids(chips(lts_j))                  # LTS ships open + proprietary + GRID flavors
pb = ids(chips(pb_j), need_open=True)    # PB is open-only
req = []
for line in open(os.path.join(conf, "pb-required.devices")):
    m = re.match(r"^([0-9a-fA-F]{4})\b", line)
    if m: req.append(m.group(1).lower())
bad = [(d, "not open-capable/non-legacy in PB") for d in req if d not in pb] + \
      [(d, "already supported by LTS (would not need PB)") for d in req if d in lts]
for name, s in (("lts", lts), ("pb", pb)):
    with open(os.path.join(conf, f"{name}-supported.devices"), "w") as f:
        f.write("".join(f"{d}\n" for d in sorted(s)))
print(f"lts-supported={len(lts)} pb-supported(open)={len(pb)} pb-only={len(pb - lts)} lts-only={len(lts - pb)} pb-required={req}")
print("pb-only sample:", sorted(pb - lts)[:40])
if bad:
    print("VALIDATION FAILED:", bad); sys.exit(2)
print("VALIDATION OK")
