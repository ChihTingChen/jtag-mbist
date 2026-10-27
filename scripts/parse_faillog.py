#!/usr/bin/env python3
"""Failure processing for the MBIST production pattern.

Takes the ATE fail log (failing cycles) and the scan map from svf2vec.py,
works out which scan and which register bit each failing cycle is,
rebuilds what the device actually shifted out, and bins the die:

  BIN 1  pass
  BIN 3  JTAG / IDCODE / IR capture wrong   (TAP or scan path problem)
  BIN 4  MBIST did not finish                (done=0 at status read)
  BIN 5  MBIST memory fail, with the first failing address
"""

import argparse
import json
import sys


def load_fails(path):
    fails = []
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            cyc, exp, got = line.split()
            fails.append((int(cyc), int(exp), int(got)))
    return fails


def find_scan(scans, cyc):
    for s in scans:
        if s["first_cycle"] <= cyc < s["first_cycle"] + s["len"]:
            return s
    return None


def analyse(scan_map, fails):
    """Returns (bin, list of message lines, diag dict)."""
    scans = scan_map["scans"]
    by_scan = {}
    stray = []
    for cyc, exp, got in fails:
        s = find_scan(scans, cyc)
        if s is None:
            stray.append(cyc)
            continue
        by_scan.setdefault(s["label"], (s, []))[1].append(cyc - s["first_cycle"])

    msgs = []
    if stray:
        msgs.append("failing cycles outside any scan: %s" % stray[:10])
    if not fails:
        return 1, ["all strobes passed"], {}

    worst = 1
    diag = {}
    for label, (s, bits) in by_scan.items():
        exp = int(s["tdo"], 16)
        mask = int(s["mask"], 16) if s.get("mask") else (1 << s["len"]) - 1
        flip = sum(1 << b for b in bits)
        actual = (exp ^ flip) & mask
        width = (s["len"] + 3) // 4
        msgs.append("%-22s exp %0*X got %0*X  (bits %s)"
                    % (label, width, exp, width, actual, sorted(bits)))

        if label.startswith("mbist_status"):
            done = (actual >> 3) & 1
            fail = (actual >> 4) & 1
            addr = (actual >> 5) & 0x3FF
            if not done:
                msgs.append("  -> MBIST still running at status read (RUNTEST too short / slow clock?)")
                worst = max(worst, 4)
            elif fail:
                msgs.append("  -> memory fail, first failing address %d (0x%03X)" % (addr, addr))
                diag.setdefault("fail_addr", addr)
                worst = max(worst, 5)
            else:
                msgs.append("  -> status bits wrong but done=1 fail=0, check control readback")
                worst = max(worst, 3)
        else:
            worst = max(worst, 3)
    return worst, msgs, diag


BIN_NAME = {1: "PASS", 3: "JTAG", 4: "MBIST_TIMEOUT", 5: "MBIST_FAIL"}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("faillog")
    ap.add_argument("map", help=".vec.map.json from svf2vec.py")
    args = ap.parse_args()

    with open(args.map) as f:
        scan_map = json.load(f)
    b, msgs, _ = analyse(scan_map, load_fails(args.faillog))
    print("\n".join(msgs))
    print("BIN %d (%s)" % (b, BIN_NAME[b]))
    sys.exit(0 if b == 1 else b)


if __name__ == "__main__":
    main()
