transcript on
onerror {quit -force -code 1}
set out current
set h ../user_source/hdl_source
set lib $out/gg_work
if {![file exists $lib]} {vlib $lib}

vlog -sv -work $lib $h/integration/green_gain96.v $out/ref_green_gain96.v $out/old_green_gain96.v $out/tb_style_gg.sv
vsim -voptargs=+acc -wlf $out/gg.wlf -lib $lib tb_style_gg
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_style_gg/test_passed]!=1} {quit -force -code 1}
puts "STYLE_GG_ALL_PASS"
quit -force -code 0
