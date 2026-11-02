transcript on
onerror {quit -force -code 1}
set lib current/target_timing_work
if {![file exists $lib]} {vlib $lib}
vlog -sv -work $lib ../user_source/hdl_source/isp/target_result_cdc.v ../user_source/hdl_source/mcu_bringup.v current/mcu_target_bridge_timing_reference.v current/tb_target_timing.sv
vsim -voptargs=+acc -wlf current/target_timing.wlf -lib $lib tb_target_timing
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_target_timing/test_passed]!=1} {quit -force -code 1}
puts "TARGET_TIMING_ALL_PASS"
quit -force -code 0
