transcript on
onerror {quit -force -code 1}
set out current
set h ../user_source/hdl_source
set lib $out/negative_unit_work
if {![file exists $lib]} {vlib $lib}
vlog -sv -work $lib $h/integration/final1_post.v $out/tb_negative_unit.sv
vsim -voptargs=+acc -wlf $out/negative_unit.wlf -lib $lib tb_negative_unit
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_negative_unit/test_passed]!=1} {quit -force -code 1}
puts "NEGATIVE_UNIT_ALL_PASS"
quit -force -code 0
