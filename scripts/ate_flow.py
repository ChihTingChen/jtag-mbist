#!/usr/bin/env python3
"""End-to-end tester flow for the JTAG MBIST block.

  gen_svf.py  ->  mbist_prod.svf
  svf2vec.py  ->  mbist_prod.vec + scan map
  tb_ate      ->  replay vectors on good / defective "dies", fail datalog
  parse_faillog -> bin + first failing address per die

The good dies at both sys_clk corners double as pattern validation: the
pattern has to pass on fault-free silicon before it means anything.
Every die result is checked against the defect we injected.
"""

import json
import os
import subprocess
import sys

import parse_faillog
import simrun

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = simrun.OUT_DIR

# name, sys_clk ns, plusargs for the defect, expected bin, expected fail_addr
DIES = [
    ("die01", 10.0, {},                                           1, None),
    ("die02", 13.0, {},                                           1, None),
    ("die03", 10.0, dict(FTYPE=1, FADDR=461, FBIT=3, FVAL=1),     5, 461),
    ("die04", 13.0, dict(FTYPE=1, FADDR=1023, FBIT=0, FVAL=0),    5, 1023),
    ("die05", 10.0, dict(FTYPE=2, FADDR=0, FBIT=7),               5, 0),
    ("die06", 13.0, dict(FTYPE=3, FADDR=300, FBIT=2),             5, 300),
    ("die07", 10.0, dict(FTYPE=4, FAGGR=900, FADDR=12, FBIT=5),   5, 12),
    ("die08", 10.0, dict(FTYPE=4, FAGGR=12, FADDR=900, FBIT=5),   5, 900),
    # sys_clk far below the corner the pattern was sized for
    ("die09", 40.0, {},                                           4, None),
]

DEFECT_TXT = {0: "-", 1: "SA%(FVAL)d @%(FADDR)d.b%(FBIT)d", 2: "TF-up @%(FADDR)d.b%(FBIT)d",
              3: "TF-dn @%(FADDR)d.b%(FBIT)d", 4: "CFid aggr %(FAGGR)d -> victim %(FADDR)d.b%(FBIT)d"}


def py(script, *args):
    subprocess.run([sys.executable, os.path.join(HERE, script)] + list(args),
                   check=True, cwd=simrun.ROOT)


def main():
    os.makedirs(OUT, exist_ok=True)
    svf = os.path.join(OUT, "mbist_prod.svf")
    vec = os.path.join(OUT, "mbist_prod.vec")
    py("gen_svf.py", "-o", svf)
    py("svf2vec.py", svf, "-o", vec)

    with open(vec + ".map.json") as f:
        scan_map = json.load(f)

    files = simrun.rtl_files() + ["../tb/sram_model.sv", "../tb/tb_ate.sv"]
    rows = []
    bad = 0
    for name, period, defect, exp_bin, exp_addr in DIES:
        log = "out/%s.fail.log" % name
        plus = ["VEC=out/mbist_prod.vec", "FAILLOG=" + log, "DIE=" + name,
                "SYS_PERIOD=%g" % period]
        plus += ["%s=%d" % kv for kv in defect.items()]
        simrun.simulate("tb_ate", files, plusargs=plus)

        b, msgs, diag = parse_faillog.analyse(scan_map,
                                              parse_faillog.load_fails(os.path.join(simrun.SIM_DIR, log)))
        got_addr = diag.get("fail_addr")
        ok = (b == exp_bin) and (exp_addr is None or got_addr == exp_addr)
        bad += not ok
        rows.append((name, period, DEFECT_TXT[defect.get("FTYPE", 0)] % defect,
                     "%d %s" % (b, parse_faillog.BIN_NAME[b]),
                     "-" if got_addr is None else str(got_addr), "ok" if ok else "MISMATCH"))
        notes = sorted(set(m.strip(" ->") for m in msgs if "->" in m))
        print("%s: BIN %d %s" % (name, b, "; ".join(notes)))

    fmt = "| %-5s | %5s | %-30s | %-16s | %-9s | %-8s |"
    lines = [fmt % ("die", "sys", "injected defect", "bin", "fail addr", "check"),
             "|" + "|".join("-" * (w + 2) for w in (5, 5, 30, 16, 9, 8)) + "|"]
    for r in rows:
        lines.append(fmt % (r[0], "%gns" % r[1], r[2], r[3], r[4], r[5]))
    text = "\n".join(lines)
    print()
    print(text)
    with open(os.path.join(OUT, "ate_summary.md"), "w", newline="\n") as f:
        f.write(text + "\n")
    if bad:
        sys.exit("%d dies binned differently than expected" % bad)
    print("\nall %d dies binned and diagnosed as expected" % len(rows))


if __name__ == "__main__":
    main()
