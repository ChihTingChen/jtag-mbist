#!/usr/bin/env python3
"""Convert an SVF file into a cycle-based ATE vector file.

Handles the subset gen_svf.py produces (and most simple hand-written
SVF): TRST, ENDIR/ENDDR IDLE, STATE RESET/IDLE, SIR, SDR, RUNTEST n TCK.

Output .vec, one TCK per line, three chars:   <tms><tdi><tdo>
  tdo = 0/1 strobe expected value on rising TCK, X = don't care.
Output .map.json: where every compared scan sits in the vector, used by
parse_faillog.py to turn failing cycles back into register bits.
"""

import argparse
import json
import os
import re
import sys


class SvfError(Exception):
    pass


def statements(text):
    """Yield (statement, last_label) with comments stripped."""
    label = None
    buf = []
    for raw in text.splitlines():
        line = raw.strip()
        m = re.match(r"(!|//)\s*@label\s+(.*)", line)
        if m:
            label = m.group(2).strip()
            continue
        line = re.split(r"!|//", line)[0].strip()
        if not line:
            continue
        buf.append(line)
        joined = " ".join(buf)
        while ";" in joined:
            stmt, joined = joined.split(";", 1)
            if stmt.strip():
                yield stmt.strip(), label
                label = None
        buf = [joined] if joined.strip() else []
    if buf and " ".join(buf).strip():
        raise SvfError("missing ';' at end of file")


def hex_bits(h, n):
    """SVF hex string -> list of n bits, LSB (shifted first) at index 0."""
    v = int(h, 16)
    if v >> n:
        raise SvfError("value %s wider than %d bits" % (h, n))
    return [(v >> i) & 1 for i in range(n)]


def parse_scan(tokens):
    n = int(tokens[1])
    fields = {}
    for key, val in re.findall(r"(TDI|TDO|MASK|SMASK)\s*\(\s*([0-9A-Fa-f]+)\s*\)",
                               " ".join(tokens[2:])):
        fields[key.upper()] = val
    if "TDI" not in fields:
        raise SvfError("%s without TDI" % tokens[0])
    tdi = hex_bits(fields["TDI"], n)
    tdo, mask = None, None
    if "TDO" in fields:
        tdo = hex_bits(fields["TDO"], n)
        mask = hex_bits(fields["MASK"], n) if "MASK" in fields else [1] * n
    return n, tdi, tdo, mask, fields


class Vec:
    def __init__(self):
        self.rows = []
        self.state = "RESET"
        self.scans = []

    def clk(self, tms, tdi=0, exp="X"):
        self.rows.append("%d%d%s" % (tms, tdi, exp))

    def goto_idle(self):
        if self.state == "RESET":
            self.clk(0)
        self.state = "IDLE"

    def reset(self):
        for _ in range(5):
            self.clk(1)
        self.state = "RESET"

    def scan(self, kind, n, tdi, tdo, mask, label, fields):
        self.goto_idle()
        self.clk(1)                       # Select-DR
        if kind == "SIR":
            self.clk(1)                   # Select-IR
        self.clk(0)                       # Capture
        self.clk(0)                       # -> Shift
        first = len(self.rows)
        for i in range(n):
            e = "X"
            if tdo is not None and mask[i]:
                e = str(tdo[i])
            self.clk(1 if i == n - 1 else 0, tdi[i], e)
        self.clk(1)                       # Update
        self.clk(0)                       # Idle
        if tdo is not None:
            self.scans.append(dict(label=label or kind.lower(), kind=kind, len=n,
                                   first_cycle=first, tdi=fields["TDI"],
                                   tdo=fields["TDO"], mask=fields.get("MASK")))


def convert(text):
    v = Vec()
    for stmt, label in statements(text):
        tok = stmt.split()
        cmd = tok[0].upper()
        if cmd == "TRST":
            continue                      # TB holds trst_n high after power-up
        elif cmd in ("ENDIR", "ENDDR"):
            if tok[1].upper() != "IDLE":
                raise SvfError("only %s IDLE supported" % cmd)
        elif cmd == "STATE":
            for st in tok[1:]:
                st = st.upper()
                if st == "RESET":
                    v.reset()
                elif st == "IDLE":
                    v.goto_idle()
                else:
                    raise SvfError("STATE %s not supported" % st)
        elif cmd in ("SIR", "SDR"):
            n, tdi, tdo, mask, fields = parse_scan(tok)
            v.scan(cmd, n, tdi, tdo, mask, label, fields)
        elif cmd == "RUNTEST":
            if len(tok) < 3 or tok[2].upper() != "TCK":
                raise SvfError("only 'RUNTEST n TCK' supported")
            v.goto_idle()
            for _ in range(int(tok[1])):
                v.clk(0)
        elif cmd in ("HIR", "HDR", "TIR", "TDR"):
            if int(tok[1]) != 0:
                raise SvfError("%s with non-zero length not supported" % cmd)
        else:
            raise SvfError("unsupported SVF command: %s" % cmd)
    return v


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("svf")
    ap.add_argument("-o", "--out", help="output .vec (default: next to the svf)")
    args = ap.parse_args()

    out = args.out or re.sub(r"\.svf$", "", args.svf) + ".vec"
    with open(args.svf) as f:
        text = f.read()
    try:
        v = convert(text)
    except SvfError as e:
        sys.exit("svf2vec: %s" % e)

    strobes = sum(1 for r in v.rows if r[2] != "X")
    with open(out, "w", newline="\n") as f:
        f.write("# from %s: %d cycles, %d strobes\n" % (os.path.basename(args.svf), len(v.rows), strobes))
        f.write("# tms tdi exp_tdo\n")
        f.write("\n".join(v.rows) + "\n")
    with open(out + ".map.json", "w", newline="\n") as f:
        json.dump(dict(cycles=len(v.rows), scans=v.scans), f, indent=1)
    print("wrote %s: %d cycles, %d strobes, %d compared scans"
          % (out, len(v.rows), strobes, len(v.scans)))


if __name__ == "__main__":
    main()
