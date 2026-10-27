# JTAG-controlled Memory BIST

A small but complete DFT block written in Verilog: an IEEE 1149.1 TAP with a
custom `MBIST_CTRL` instruction that starts a March C- memory BIST running
at speed on the system clock. The test result comes back through the same
four JTAG pins. Everything is verified from the pins with self-checking
testbenches, and there are two extra flows on top:

* a **fault simulation campaign** (SAF / TF / CFid / CFin, inter- and
  intra-word) that reports March C- coverage for each fault class and data background
* a **tester flow**: production SVF -> cycle-based vectors -> ATE-style
  replay on good and defective "dies" -> fail datalog -> binning and
  failing-address diagnosis

The RTL is synthesizable Verilog-2001 (no `initial`, no delays, lint clean)
so it can go through Genus/Innovus later.

```
               TCK domain                     :               sys_clk domain
                                              :
  tck,tms,trst_n ──► tap_ctrl                 :
                        │ state flags         :
                        ▼                     :
  tdi ─────────────► jtag_regs ──► tdo,tdo_en :
                     IR, BYPASS,              :
                     IDCODE, TDO mux          :
                        │ sel_mbist  ▲ so     :
                        ▼            │        :
                     mbist_tdr ──────┘        :
                        start_tck ────────────:──► 2FF ──► start edge ─┐
                        algo_sel_tck ─────────:──► 2FF ────────────────┤
                                              :                        ▼
                        done_tck  ◄── 2FF ◄───:──────────────────── mbist_ctrl ◄──► SRAM
                        fail_tck  ◄── 2FF ◄───:──────────────────── (March C-)     (TB model)
                        fail_addr ◄───────────:──── no sync, used only
                                              :     while done_tck = 1
                                              :
                                              :  sys_rst_n ──► rst_sync (async assert,
                                              :                sync deassert)
```

The SRAM is not part of the top level. The testbench instantiates a behavioral
model with fault injection; for PnR it would be replaced by a macro or a flop array.

## Directory layout

```
rtl/        tap_ctrl, jtag_regs, mbist_tdr, sync_2ff, rst_sync, mbist_ctrl, jtag_mbist_top
tb/         sram_model.sv      behavioral SRAM, fault injection tasks
            jtag_tasks.svh     tester-side JTAG driver (reset / shift_ir / shift_dr / mbist_*)
            tb_common.svh      [PASS]/[FAIL] bookkeeping
            tb_tap.sv          M1  TAP unit test
            tb_mbist.sv        M2  MBIST unit test (no JTAG)
            tb_top.sv          M3/M4 system test, JTAG pins only
            tb_campaign.sv     fault campaign runner
            tb_ate.sv          vector replay "ATE"
scripts/    fault_campaign.py  gen_svf.py  svf2vec.py  parse_faillog.py  ate_flow.py  simrun.py
sim/        Makefile, wave.do  (generated files go to sim/out/)
```

## Instructions and registers

| Instruction | IR     | Data register          |
|-------------|--------|------------------------|
| IDCODE      | `0001` | 32-bit, `0x1BEEF001`   |
| MBIST_CTRL  | `1000` | 16-bit MBIST TDR       |
| BYPASS      | `1111` | 1-bit                  |
| (others)    | -      | BYPASS                 |

IDCODE is the active instruction after Test-Logic-Reset. Capture-IR loads
`0001`. TDI/TMS are sampled on rising TCK. TDO and the update stages (Update-IR,
Update-DR) act on falling TCK as in 1149.1, and `tdo_en` is high only in
Shift-IR/Shift-DR.

MBIST TDR:

| Bit   | Field      | Dir | Notes                                              |
|-------|------------|-----|----------------------------------------------------|
| 0     | start      | W   | level; the MBIST starts on a 0->1 edge             |
| 2:1   | algo_sel   | W   | `00` solid 00/FF, `01` checkerboard 55/AA, `1x` reserved |
| 3     | done       | R   |                                                    |
| 4     | fail       | R   | at least one miscompare                            |
| 14:5  | fail_addr  | R   | first failing address, reads 0 while done=0        |
| 15    | -          | R   | 0                                                  |

Capture-DR loads the status together with the control bits currently in effect.
Every DR scan ends in Update-DR, so a "read" also rewrites bits [2:0]. The
test program therefore has to shift the current control value back in (the TB
keeps a shadow copy for that).

## March C-

`{⇕(w0); ⇑(r0,w1); ⇑(r1,w0); ⇓(r0,w1); ⇓(r1,w0); ⇕(r0)}`, 10N operations.
One operation runs per sys_clk. Reads are pipelined: a read issued in cycle t
is compared in cycle t+1 while the next operation is already on the bus.
A full run of 1024 words takes **10N + 4 = 10244 cycles**: one each for the
start edge detect, ARM, read latency, and "done after fail is final".

What each read element catches (a = aggressor address, v = victim):

| Element      | Detects                                                                 |
|--------------|-------------------------------------------------------------------------|
| M1 ⇑(r0,w1)  | SAF1; TF↓ from M0's w0; CFid<↑;1>, CFin<↑> with a < v                   |
| M2 ⇑(r1,w0)  | SAF0; TF↑ from M1's w1; CFid<↑;0>, CFin<↑> with a > v; CFid<↓;0>, CFin<↓> with a < v |
| M3 ⇓(r0,w1)  | TF↓ from M2's w0; CFid<↓;1>, CFin<↓> with a > v; CFid<↑;1>, CFin<↑> with a > v |
| M4 ⇓(r1,w0)  | TF↑ from M3's w1; CFid<↑;0> with a < v; CFid<↓;0>, CFin<↓> with a > v   |
| M5 ⇕(r0)     | CFid<↓;1>, CFin<↓> with a < v (caused by M4's writes)                   |

Both address orders are needed. As a check I forced M3/M4 to count up,
and `tb_mbist` immediately missed a CFid with victim < aggressor.

The data background changes which bits inside a word transition together.
Solid 00/FF moves every bit the same way, so an intra-word coupling fault
whose victim is being written to the forced value at the same moment is
masked. Checkerboard covers the opposite-parity bit pairs. The campaign below
puts numbers on this.

## CDC

TCK and sys_clk are treated as fully asynchronous (sim uses 100 ns vs 10 ns
and vs 13 ns, with a random phase).

| Signal        | Direction | How                                                       |
|---------------|-----------|-----------------------------------------------------------|
| start_tck     | TCK→sys   | 2FF, rising-edge detect in sys domain                     |
| algo_sel_tck  | TCK→sys   | 2FF, sampled one sys cycle after the start edge           |
| done, fail    | sys→TCK   | 2FF each                                                  |
| fail_addr     | sys→TCK   | no synchronizer, qualified by `done_tck`                  |
| sys_rst_n     | -         | `rst_sync`: asynchronous assert, synchronous deassert     |

**Why fail_addr needs no synchronizer.** A 2FF on each bit of a 10-bit
bus would not help: different bits can resolve on different TCK edges and
the capture would mix old and new address. Instead the bus is only used
while it cannot change. fail_addr only moves while the BIST is running and is
frozen once `done` is set. `done` reaches the TCK domain through a 2FF, so
when `done_tck` = 1 the bus has been stable for at least two TCK edges and
the TDR capture flops see a clean value. While `done_tck` = 0 the TDR
captures 0 instead. This is the same idea as holding data steady until a
synchronized handshake says it is valid. In STA it becomes a
`set_max_delay`/false path from `fail_addr` into the TDR capture flops.

Three more problems turned up while writing this, and each one is covered
in the design or the tests:

1. **done must be the last thing to change.** If the final r0 mismatches,
   `fail` and `done` would rise on the same sys_clk edge, and the two 2FFs
   could resolve one TCK apart. For that TCK a capture would read
   done=1, fail=0, a false pass. `mbist_ctrl` therefore raises done
   one cycle after fail/fail_addr are final.
2. **Stale done after a restart.** After a new start, `done_tck` still shows
   1 for up to two TCKs while the sys side has already cleared it. A poll
   right after the start write (with no IR scan in between) can read the
   previous run's result. At TCK 100 ns the scan overhead alone hides this,
   but with TCK at 10 ns and no idle the TB really did read a false pass
   (fail_addr 0 instead of 461). `mbist_write` now idles 4 TCKs after the
   write, the equivalent of `RUNTEST` in an SVF.
3. **algo_sel and start in the same scan.** In silicon the two synchronizers
   can deliver the bits a cycle apart. The controller samples algo_sel one
   cycle after it sees the start edge. Writing algo_sel first and start in a
   second scan (which is what the TB and the SVF do) removes the issue completely.

Mutation checks that were run against the tests: removing the `done_tck`
gate on fail_addr is caught by the mid-run poll test; removing the
post-write idle is caught at TCK = 10 ns; breaking the March direction is
caught by the CF tests.

## Running

ModelSim/Questa is the default. Icarus, VCS and Xcelium are selected with `SIM=`.

```
cd sim
make all                # tb_tap, tb_mbist, tb_top at sys_clk 10 ns and 13 ns
make top SYS_PERIODS=7  # any other period
make campaign           # fault campaign + coverage check
make ate                # SVF -> vectors -> 9 dies -> bins
make regress            # all of the above
make wave               # ModelSim GUI with wave.do (gtkwave + VCD for SIM=iverilog)
make all SIM=iverilog
```

The Python scripts use only the standard library (Python 3.8+) and can also
be called directly, e.g. `python scripts/fault_campaign.py -n 100 --addr-w 10`.

## Results

ModelSim Intel FPGA Starter 2020.1:

| Bench                 | Tests | Result |
|-----------------------|-------|--------|
| tb_tap                | 5     | PASS   |
| tb_mbist              | 7     | PASS (10244 cycles = 10N + 4) |
| tb_top, sys_clk 10 ns | 6     | PASS   |
| tb_top, sys_clk 13 ns | 6     | PASS   |

tb_top covers: IDCODE, TDR readback, no-fault runs with both backgrounds,
every fault model (including address 0 and N-1 and both CF directions)
read out over JTAG, back-to-back runs (a second `start=1` without a 0 in
between must not restart), and polling mid-run. In the mid-run test, 45 of 49 polls landed while
the raw fail_addr was already set, and every one of them read 0.

### Fault campaign (`make campaign`, 256 words, 60 faults per class, both backgrounds)

| fault class        |  n | solid 00/FF | chkbd 55/AA | either bg |
|--------------------|----|-------------|-------------|-----------|
| SAF0 / SAF1        | 60 / 60 | 100% | 100% | 100% |
| TF <up/0>, <dn/1>  | 60 / 60 | 100% | 100% | 100% |
| CFid <up;0> <up;1> <dn;0> <dn;1> (inter-word) | 4 x 60 | 100% | 100% | 100% |
| CFin <up>, <dn> (inter-word) | 2 x 60 | 100% | 100% | 100% |
| intra CFid <up;0>  | 60 | 100.0% | 33.3% | 100.0% |
| intra CFid <up;1>  | 60 |   0.0% | 63.3% |  63.8% |
| intra CFid <dn;0>  | 60 |   0.0% | 56.7% |  56.7% |
| intra CFid <dn;1>  | 60 | 100.0% | 46.7% | 100.0% |
| intra CFin <up>, <dn> | 2 x 60 | 100% | 100% | 100% |
| **total**          | 960 | 87.5% | 87.5% | 95.1% |

Every detected fault was diagnosed to the correct word (840/840 per background).

Single-cell and inter-word faults are fully covered, as the theory predicts.
Within a word, CFid <↑;1> and <↓;0> are masked whenever the victim bit is
written the forced value at the same moment the aggressor bit flips. Solid
backgrounds always do that, and checkerboard does it for same-parity bit pairs
(3 of the 7 partner bits), which leaves about 57% after both backgrounds. Full
intra-word coverage of an 8-bit word needs log2(8)+1 = 4 backgrounds (00, 55,
33, 0F). That is the natural use of the reserved `algo_sel` codes.

### Tester flow (`make ate`)

`gen_svf.py` writes the production pattern: IDCODE check, MBIST_CTRL,
and for each background `start 0 -> 1, RUNTEST, status compare`. RUNTEST is sized for the
slowest sys_clk corner (13 ns) with 25% margin, which gives 1670 TCK.
`svf2vec.py` turns it into 3524 cycles / 68 strobes, plus a map from cycles to scan bits.
`tb_ate.sv` replays the vectors pin by pin and logs failing strobes.
`parse_faillog.py` rebuilds the shifted-out value of each failing scan and bins the die.

| die   |  sys | injected defect               | bin             | fail addr |
|-------|------|-------------------------------|-----------------|-----------|
| die01 | 10ns | -                             | 1 PASS          | -         |
| die02 | 13ns | -                             | 1 PASS          | -         |
| die03 | 10ns | SA1 @461 bit 3                | 5 MBIST_FAIL    | 461       |
| die04 | 13ns | SA0 @1023 bit 0               | 5 MBIST_FAIL    | 1023      |
| die05 | 10ns | TF-up @0 bit 7                | 5 MBIST_FAIL    | 0         |
| die06 | 13ns | TF-dn @300 bit 2              | 5 MBIST_FAIL    | 300       |
| die07 | 10ns | CFid aggr 900 -> victim 12    | 5 MBIST_FAIL    | 12        |
| die08 | 10ns | CFid aggr 12 -> victim 900    | 5 MBIST_FAIL    | 900       |
| die09 | 40ns | - (clock far below the corner)| 4 MBIST_TIMEOUT | -         |

The two good dies also validate the pattern: it has to pass on fault-free
silicon at both corners before a fail means anything. die09 shows why
RUNTEST sizing matters. Example datalog for die03 and what the parser makes of it:

```
mbist_status algo=0    exp 0009 got 39B9  (bits [4, 5, 7, 8, 11, 12, 13])
  -> memory fail, first failing address 461 (0x1CD)
BIN 5 (MBIST_FAIL)
```

## Next steps

* Boundary scan cells with EXTEST and SAMPLE/PRELOAD
* March B / March SS, and more data backgrounds (see campaign above)
* BISR: map the failing row to a spare
* IEEE 1687 (IJTAG): SIB network in front of several MBIST instances
* Genus + Innovus on ASAP7: area overhead, TCK-domain timing, CDC constraints
