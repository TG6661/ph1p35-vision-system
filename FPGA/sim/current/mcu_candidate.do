transcript on
onerror {quit -force -code 1}
set out current
set lib $out/mcu_candidate_work
if {![file exists $lib]} {vlib $lib}
vlog -sv -work $lib ../user_source/hdl_source/mcu_reset_sync.v ../user_source/hdl_source/ahb_ctrl_regs.v $out/tb_servo_ahb.sv
vsim -voptargs=+acc -wlf $out/mcu_candidate.wlf -lib $lib tb_mcu_ahb
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_mcu_ahb/test_passed]!=1} {quit -force -code 1}
puts "AHB_READMUX_MCU_CANDIDATE_PASS"
quit -force -code 0
