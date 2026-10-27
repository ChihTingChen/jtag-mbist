#!/usr/bin/env python3
"""Write the production JTAG pattern (SVF) for the MBIST block.

Test flow:
  1. reset, check IDCODE
  2. MBIST_CTRL: algo 00, start 0 -> 1, RUNTEST, check status
  3. same with checkerboard (algo 01)

RUNTEST is sized from the slowest sys_clk the part is tested at, with
some margin. Scans get a "! @label" comment so svf2vec.py / the fail
log parser know which scan a failing cycle belongs to.
"""

import argparse
import math

IDCODE = 0x1BEEF001
IR_MBIST = 0x8


def runtest_tck(words, sys_period_ns, tck_period_ns, margin):
    # 10N ops + start edge/arm/flush/done + 2FF each way
    sys_cycles = 10 * words + 4 + 4
    t = sys_cycles * sys_period_ns
    return int(math.ceil(t / tck_period_ns * margin)) + 4


def status_word(done, fail, addr, algo, start):
    return (addr << 5) | (fail << 4) | (done << 3) | (algo << 1) | start


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-o", "--out", default="sim/out/mbist_prod.svf")
    ap.add_argument("--words", type=int, default=1024)
    ap.add_argument("--sys-period", type=float, default=13.0,
                    help="slowest sys_clk period to cover, ns")
    ap.add_argument("--tck-period", type=float, default=100.0)
    ap.add_argument("--margin", type=float, default=1.25)
    args = ap.parse_args()

    wait = runtest_tck(args.words, args.sys_period, args.tck_period, args.margin)

    s = []
    s.append("! mbist_prod.svf -- JTAG MBIST production test")
    s.append("! %d words, RUNTEST %d TCK covers sys_clk >= %.1f ns at TCK %.0f ns (x%.2f)"
             % (args.words, wait, args.sys_period, args.tck_period, args.margin))
    s.append("TRST OFF;")
    s.append("ENDIR IDLE;")
    s.append("ENDDR IDLE;")
    s.append("STATE RESET;")
    s.append("STATE IDLE;")
    s.append("")
    s.append("! @label idcode")
    s.append("SDR 32 TDI (00000000) TDO (%08X) MASK (FFFFFFFF);" % IDCODE)
    s.append("")
    s.append("! @label ir_mbist")
    s.append("SIR 4 TDI (%X) TDO (1) MASK (F);" % IR_MBIST)

    for algo in (0, 1):
        ctl0 = status_word(0, 0, 0, algo, 0)
        ctl1 = status_word(0, 0, 0, algo, 1)
        s.append("")
        s.append("! ---- March C-, algo %d%d ----" % (algo >> 1, algo & 1))
        s.append("SDR 16 TDI (%04X);" % ctl0)
        s.append("SDR 16 TDI (%04X);" % ctl1)
        s.append("RUNTEST %d TCK;" % wait)
        s.append("! @label mbist_status algo=%d" % algo)
        s.append("SDR 16 TDI (%04X) TDO (%04X) MASK (FFFF);"
                 % (ctl1, status_word(1, 0, 0, algo, 1)))

    s.append("")
    s.append("STATE RESET;")

    with open(args.out, "w", newline="\n") as f:
        f.write("\n".join(s) + "\n")
    print("wrote %s (RUNTEST %d TCK)" % (args.out, wait))


if __name__ == "__main__":
    main()
