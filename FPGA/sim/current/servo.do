transcript on
onerror {quit -force -code 1}
set out current
set lib $out/servo_work
if {![file exists $lib]} {vlib $lib}
vlog -sv -work $lib ../user_source/hdl_source/ahb_ctrl_regs.v $out/tb_servo.sv
foreach div {2 150} {
 vsim -voptargs=+acc -wlf $out/servo_$div.wlf -gDIV=$div -lib $lib tb_servo
 onfinish stop
 run -all
 if {[examine -radix unsigned sim:/tb_servo/test_passed]!=1} {quit -force -code 1}
 quit -sim
}
puts "SERVO_TIMING_ALL_PASS"
quit -force -code 0
