transcript on
onerror {quit -force -code 1}
set out current
set h ../user_source/hdl_source
set lib $out/regs_work
if {![file exists $lib]} {vlib $lib}

vlog -sv -work $lib $h/integration/final1_regs.v $out/final1_regs_reference.v $out/tb_joint_regs.sv
vsim -voptargs=+acc -wlf $out/regs.wlf -lib $lib tb_joint_regs
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_joint_regs/test_passed]!=1} {quit -force -code 1}
puts "STYLE_REGS_ALL_PASS"
quit -force -code 0
