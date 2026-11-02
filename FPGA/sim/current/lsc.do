transcript on
onerror {quit -force -code 1}
set out current
set h ../user_source/hdl_source
set lib $out/lsc_work
if {![file exists $lib]} {vlib $lib}

vlog -sv -work $lib $h/integration/final1_raw_front.v $out/ref_raw_lsc_4px.v $out/old_lsc.v $out/tb_style_lsc.sv
vsim -voptargs=+acc -wlf $out/lsc.wlf -lib $lib tb_style_lsc
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_style_lsc/test_passed]!=1} {quit -force -code 1}
puts "STYLE_LSC_ALL_PASS"
quit -force -code 0
