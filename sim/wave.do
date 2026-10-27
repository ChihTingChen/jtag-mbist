# wave.do -- open tb_top in the ModelSim GUI with the useful signals grouped
#   make wave            or    vsim -do wave.do
# optional: set SYS_PERIOD 13 before sourcing

if {![info exists SYS_PERIOD]} { set SYS_PERIOD 10 }

if {![file isdirectory work]} { vlib work }
vlog -quiet -sv +incdir+../tb ../rtl/*.v ../tb/sram_model.sv ../tb/tb_top.sv
vsim -voptargs=+acc tb_top +SYS_PERIOD=$SYS_PERIOD
onfinish stop

set top /tb_top/dut

add wave -group JTAG  /tb_top/trst_n /tb_top/tck /tb_top/tms /tb_top/tdi /tb_top/tdo /tb_top/tdo_en
add wave -group TAP   -radix hex $top/u_tap/state $top/u_regs/ir_shift $top/u_regs/ir_latched
add wave -group TDR   -radix hex $top/u_tdr/sr
add wave -group TDR   $top/start_tck $top/algo_sel_tck
add wave -group CDC   $top/start_sync $top/algo_sel_sync $top/done_sys $top/done_tck \
                      $top/fail_sys $top/fail_tck
add wave -group CDC   -radix unsigned $top/fail_addr_sys
add wave -group MBIST /tb_top/sys_clk $top/rst_n_sys
add wave -group MBIST -radix unsigned $top/u_mbist/st $top/u_mbist/elem $top/u_mbist/step \
                      $top/u_mbist/addr
add wave -group MBIST $top/mem_we $top/mem_re
add wave -group MBIST -radix hex $top/mem_wdata $top/mem_rdata $top/u_mbist/exp_q
add wave -group MBIST $top/u_mbist/done $top/u_mbist/fail
add wave -group MBIST -radix unsigned $top/u_mbist/fail_addr

run -all
wave zoom full
