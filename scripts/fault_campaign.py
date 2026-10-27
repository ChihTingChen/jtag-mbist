#!/usr/bin/env python3
"""March C- fault campaign.

Builds a fault list (SAF, TF, inter-word and intra-word coupling faults),
runs every fault through mbist_ctrl + sram_model under both data
backgrounds, and reports detection coverage and diagnosis accuracy
(fail_addr == the faulty / victim word).

    python scripts/fault_campaign.py                 # 30 faults per class
    python scripts/fault_campaign.py -n 100 --check  # fail if coverage drops
"""

import argparse
import os
import random
import sys
from collections import defaultdict

import simrun

DATA_W = 8
T_SA, T_TFU, T_TFD, T_CF = 1, 2, 3, 4

# (class name, type, extra) -- for CF extra = (rise, inv, val, intra_word)
CLASSES = [
    ("SAF0",              T_SA,  0),
    ("SAF1",              T_SA,  1),
    ("TF <up/0>",         T_TFU, None),
    ("TF <dn/1>",         T_TFD, None),
    ("CFid <up;0>",       T_CF,  (1, 0, 0, False)),
    ("CFid <up;1>",       T_CF,  (1, 0, 1, False)),
    ("CFid <dn;0>",       T_CF,  (0, 0, 0, False)),
    ("CFid <dn;1>",       T_CF,  (0, 0, 1, False)),
    ("CFin <up;inv>",     T_CF,  (1, 1, 0, False)),
    ("CFin <dn;inv>",     T_CF,  (0, 1, 0, False)),
    ("intra CFid <up;0>", T_CF,  (1, 0, 0, True)),
    ("intra CFid <up;1>", T_CF,  (1, 0, 1, True)),
    ("intra CFid <dn;0>", T_CF,  (0, 0, 0, True)),
    ("intra CFid <dn;1>", T_CF,  (0, 0, 1, True)),
    ("intra CFin <up>",   T_CF,  (1, 1, 0, True)),
    ("intra CFin <dn>",   T_CF,  (0, 1, 0, True)),
]

ALGOS = {0: "solid 00/FF", 1: "chkbd 55/AA"}


def build_faults(n_words, per_class, rng):
    """Returns list of dicts. Same physical fault is run with both algos."""
    faults = []
    fid = 0
    for name, typ, extra in CLASSES:
        for _ in range(per_class):
            victim = rng.randrange(n_words)
            vbit = rng.randrange(DATA_W)
            aggr, abit, rise, inv, val = 0, 0, 0, 0, 0
            if typ == T_SA:
                val = extra
            elif typ == T_CF:
                rise, inv, val, intra = extra
                if intra:
                    aggr = victim
                    abit = rng.choice([b for b in range(DATA_W) if b != vbit])
                else:
                    aggr = rng.choice([a for a in range(n_words) if a != victim])
                    abit = rng.randrange(DATA_W)
            for algo in ALGOS:
                faults.append(dict(id=fid, cls=name, type=typ, algo=algo,
                                   aggr=aggr, abit=abit, victim=victim,
                                   vbit=vbit, rise=rise, inv=inv, val=val))
                fid += 1
    return faults


def write_faults(path, faults):
    with open(path, "w", newline="\n") as f:
        f.write("# id type algo aggr abit victim vbit rise inv val\n")
        for x in faults:
            f.write("%(id)d %(type)d %(algo)d %(aggr)d %(abit)d %(victim)d "
                    "%(vbit)d %(rise)d %(inv)d %(val)d\n" % x)


def read_results(path):
    res = {}
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            fid, det, addr = (int(t) for t in line.split())
            res[fid] = (det, addr)
    return res


def pct(a, b):
    return 100.0 * a / b if b else 0.0


def report(faults, res, n_words):
    # per class: [algo] -> [n, detected, diag_ok]
    stats = defaultdict(lambda: {a: [0, 0, 0] for a in ALGOS})
    union = defaultdict(dict)       # cls -> {(victim, ...) key: detected_any}

    for x in faults:
        det, addr = res[x["id"]]
        s = stats[x["cls"]][x["algo"]]
        s[0] += 1
        s[1] += det
        s[2] += int(det and addr == x["victim"])
        key = (x["aggr"], x["abit"], x["victim"], x["vbit"])
        union[x["cls"]][key] = union[x["cls"]].get(key, 0) | det

    cols = ["fault class", "n", "solid 00/FF", "chkbd 55/AA", "either bg"]
    fmt = "| %-18s | %5s | %11s | %11s | %9s |"
    lines = ["March C- fault campaign, %d words x %d bits" % (n_words, DATA_W), "",
             fmt % tuple(cols),
             "|" + "|".join("-" * (w + 2) for w in (18, 5, 11, 11, 9)) + "|"]

    tot = {a: [0, 0, 0] for a in ALGOS}
    tot_u = [0, 0]
    for name, _, _ in CLASSES:
        s = stats[name]
        u = union[name]
        tot_u[0] += len(u)
        tot_u[1] += sum(u.values())
        for a in ALGOS:
            for i in range(3):
                tot[a][i] += s[a][i]
        lines.append(fmt % (name, s[0][0], "%.1f%%" % pct(s[0][1], s[0][0]),
                            "%.1f%%" % pct(s[1][1], s[1][0]),
                            "%.1f%%" % pct(sum(u.values()), len(u))))
    lines.append(fmt % ("TOTAL", tot[0][0], "%.1f%%" % pct(tot[0][1], tot[0][0]),
                        "%.1f%%" % pct(tot[1][1], tot[1][0]),
                        "%.1f%%" % pct(tot_u[1], tot_u[0])))
    lines.append("")
    for a in ALGOS:
        lines.append("diagnosis (%s): fail_addr correct for %d of %d detected faults"
                     % (ALGOS[a], tot[a][2], tot[a][1]))
    return lines, stats, union


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-n", "--per-class", type=int, default=30)
    ap.add_argument("--addr-w", type=int, default=8, help="log2(words), default 8")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--check", action="store_true",
                    help="exit 1 unless every single-cell / inter-word class is 100%% "
                         "covered by each background and every detected fault is "
                         "diagnosed to the right word")
    args = ap.parse_args()

    n_words = 1 << args.addr_w
    rng = random.Random(args.seed)
    faults = build_faults(n_words, args.per_class, rng)

    os.makedirs(simrun.OUT_DIR, exist_ok=True)
    flist = os.path.join(simrun.OUT_DIR, "faults.txt")
    rfile = os.path.join(simrun.OUT_DIR, "results.txt")
    write_faults(flist, faults)
    print("simulating %d fault runs (%d words)..." % (len(faults), n_words))

    files = simrun.rtl_files() + ["../tb/sram_model.sv", "../tb/tb_campaign.sv"]
    simrun.simulate("tb_campaign", files,
                    plusargs=["FAULTS=out/faults.txt", "RESULTS=out/results.txt"],
                    defines=["ADDR_W_OVR=%d" % args.addr_w])

    res = read_results(rfile)
    missing = [x["id"] for x in faults if x["id"] not in res]
    if missing:
        sys.exit("no result for %d faults" % len(missing))

    lines, stats, union = report(faults, res, n_words)
    text = "\n".join(lines)
    print(text)
    with open(os.path.join(simrun.OUT_DIR, "coverage_report.md"), "w", newline="\n") as f:
        f.write(text + "\n")

    if args.check:
        # intra-word CFs are not guaranteed with only 2 backgrounds, so
        # they are reported but not checked
        bad = [c for c in stats if not c.startswith("intra")
               and any(stats[c][a][1] != stats[c][a][0] for a in ALGOS)]
        diag_bad = sum(stats[c][a][1] - stats[c][a][2] for c in stats for a in ALGOS)
        if bad or diag_bad:
            print("CHECK FAILED: uncovered classes %s, %d misdiagnosed" % (bad, diag_bad))
            sys.exit(1)
        print("CHECK PASSED")


if __name__ == "__main__":
    main()
