"""Small wrapper so the Python flows can drive ModelSim/Questa or Icarus.

Pick the simulator with SIM=modelsim (default) or SIM=iverilog.
Everything runs inside sim/, generated files go to sim/out/.
"""

import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SIM_DIR = os.path.join(ROOT, "sim")
OUT_DIR = os.path.join(SIM_DIR, "out")

RTL = ["tap_ctrl.v", "jtag_regs.v", "mbist_tdr.v", "sync_2ff.v",
       "rst_sync.v", "mbist_ctrl.v", "jtag_mbist_top.v"]


def rtl_files():
    return ["../rtl/" + f for f in RTL]


def _run(cmd, quiet=False):
    p = subprocess.run(cmd, cwd=SIM_DIR, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True)
    if not quiet or p.returncode != 0:
        sys.stdout.write(p.stdout)
    if p.returncode != 0:
        sys.exit("command failed: " + " ".join(cmd))
    return p.stdout


def simulate(top, files, plusargs=(), defines=(), quiet=True):
    """Compile files and run top. Returns the simulator log."""
    os.makedirs(OUT_DIR, exist_ok=True)
    sim = os.environ.get("SIM", "modelsim")
    plus = ["+" + a for a in plusargs]

    if sim == "iverilog":
        exe = os.path.join("out", top + ".vvp")
        cmd = ["iverilog", "-g2012", "-I../tb", "-o", exe, "-s", top]
        cmd += ["-D" + d for d in defines] + list(files)
        _run(cmd, quiet)
        log = _run(["vvp", "-n", exe] + plus, quiet)
    else:
        if not os.path.isdir(os.path.join(SIM_DIR, "work")):
            _run(["vlib", "work"], True)
        cmd = ["vlog", "-quiet", "-sv", "+incdir+../tb"]
        cmd += ["+define+" + d for d in defines] + list(files)
        _run(cmd, quiet)
        log = _run(["vsim", "-c", "-quiet", "-do", "run -all; quit -f", top] + plus, quiet)

    if "Fatal" in log or "FATAL" in log:
        sys.stdout.write(log)
        sys.exit("simulation of %s hit $fatal" % top)
    return log
