# Functional integration only. Never starts TD or changes implementation settings.
transcript on
onerror {quit -force -code 1}
set out current
set lib $out/runtime_work
if {![file exists $lib]} {vlib $lib}
set h ../user_source/hdl_source
set d $h/isp/demosaic_4x_2_0
if {![info exists TD_SIM_DIR]} {set TD_SIM_DIR E:/TD/sim_release/ph1p}
foreach f {ph1p_phy_gsr.v ph1p_phy_dspsiou_v2.v ph1p_phy_dsptadd.v} {vlog -work $lib $TD_SIM_DIR/$f}
vlog -sv -work $lib $out/isp_line_ram_model.v
set sources [list $out/bram_models.v $out/view_fifo_model.sv $h/isp/raw10_same_phase_filter.v \
 $h/isp/target_result_cdc.v $h/isp/view_mode_cdc.v $h/isp/target_result_buffer.v $h/isp/target_osd_font.v \
 $h/mcu_bringup.v $h/ahb_ctrl_regs.v $h/video_in.v $h/signal_delay.v $h/isp/data128_96/data128_96.v \
 $d/demosaic.v $d/raw_matrix_3x3_buffer.v $d/mipi_to_raw_converter.v $d/zhenghe.v \
 $d/line_buffer_demosaic.v $d/bilinear_interpolation.v]
foreach f [glob $h/integration/*.v] {if {[file tail $f] ne "isp_line_ram.v"} {lappend sources $f}}
lappend sources $out/tb_final1_runtime.sv
foreach f $sources {vlog -sv -work $lib +incdir+. $f}
if {![info exists RUNTIME_ARGS]} {set RUNTIME_ARGS {}}
eval vsim -voptargs=+acc -wlf $out/runtime.wlf $RUNTIME_ARGS -lib $lib tb_final1_runtime PH1P_PHY_GSR
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_final1_runtime/test_passed] != 1} {quit -force -code 1}
puts "MOTION_RUNTIME_REGRESSION_PASS"
quit -force -code 0
