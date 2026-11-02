transcript on
onerror {quit -force -code 1}
set out current
set h ../user_source/hdl_source
set lib $out/negative_serial_work
if {![file exists $lib]} {vlib $lib}
vlog -sv -work $lib $out/isp_line_ram_model.v $h/integration/final1_post.v $out/tb_negative_serial.sv
vsim -voptargs=+acc -wlf $out/negative_serial.wlf -lib $lib tb_negative_serial
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_negative_serial/test_passed]!=1} {quit -force -code 1}
puts "NEGATIVE_UNIT_ALL_PASS"
quit -force -code 0
