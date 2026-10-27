# JTAG + MBIST simulation
#
#   make all                 tap + mbist + top (both sys_clk periods)
#   make tap | mbist | top
#   make campaign            fault coverage campaign   (python)
#   make ate                 SVF -> vectors -> ATE replay -> binning (python)
#   make regress             all + campaign + ate
#   make wave                GUI waves of tb_top
#   make clean
#
#   SIM=modelsim (default, also Questa) | iverilog | vcs | xcelium
#   SYS_PERIODS="10 13"      sys_clk periods for 'top'

SIM         ?= modelsim
SYS_PERIODS ?= 10 13
PY          ?= python3

export SIM

RTL_DIR = ../rtl
TB_DIR  = ../tb
RTL     = $(addprefix $(RTL_DIR)/, tap_ctrl.v jtag_regs.v mbist_tdr.v sync_2ff.v \
                                   rst_sync.v mbist_ctrl.v jtag_mbist_top.v)

TAP_SRC   = $(RTL_DIR)/tap_ctrl.v $(RTL_DIR)/jtag_regs.v $(TB_DIR)/tb_tap.sv
MBIST_SRC = $(RTL_DIR)/mbist_ctrl.v $(TB_DIR)/sram_model.sv $(TB_DIR)/tb_mbist.sv
TOP_SRC   = $(RTL) $(TB_DIR)/sram_model.sv $(TB_DIR)/tb_top.sv

# $(call sim,top,sources,plusargs,logname)
ifeq ($(SIM),iverilog)
define sim
	iverilog -g2012 -I$(TB_DIR) -s $(1) -o out/$(1).vvp $(2)
	vvp -n out/$(1).vvp $(3) | tee out/$(4).log
endef
else ifeq ($(SIM),vcs)
define sim
	vcs -full64 -sverilog -q +incdir+$(TB_DIR) -top $(1) -o out/$(1).simv $(2)
	./out/$(1).simv $(3) | tee out/$(4).log
endef
else ifeq ($(SIM),xcelium)
define sim
	xrun -q -sv +incdir+$(TB_DIR) -top $(1) $(2) $(3) | tee out/$(4).log
endef
else
define sim
	@test -d work || vlib work
	vlog -quiet -sv +incdir+$(TB_DIR) $(2)
	vsim -c -quiet -do "run -all; quit -f" $(1) $(3) | tee out/$(4).log
endef
endif

# tee eats the exit code, so look at the log instead
check = @! grep -qE '\[FAIL\]|Fatal|FATAL|\*\* Error' out/$(1).log || (echo "*** $(1) FAILED"; false)

.PHONY: all tap mbist top campaign ate regress wave clean

all: tap mbist top
	@echo "=== all simulations passed ($(SIM)) ==="

out:
	@mkdir -p out

tap: | out
	$(call sim,tb_tap,$(TAP_SRC),,tb_tap)
	$(call check,tb_tap)

mbist: | out
	$(call sim,tb_mbist,$(MBIST_SRC),,tb_mbist)
	$(call check,tb_mbist)

top: $(addprefix top_,$(SYS_PERIODS))

top_%: | out
	$(call sim,tb_top,$(TOP_SRC),+SYS_PERIOD=$*,tb_top_$*)
	$(call check,tb_top_$*)

campaign: | out
	$(PY) ../scripts/fault_campaign.py --check

ate: | out
	$(PY) ../scripts/ate_flow.py

regress: all campaign ate

ifeq ($(SIM),iverilog)
wave: | out
	$(call sim,tb_top,$(TOP_SRC),+SYS_PERIOD=10 +DUMP,tb_top_wave)
	gtkwave out/tb_top.vcd &
else
wave:
	vsim -do wave.do
endif

clean:
	rm -rf work out transcript *.wlf *.vcd vsim.dbg csrc *.daidir xcelium.d xrun.*
