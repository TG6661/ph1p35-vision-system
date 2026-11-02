transcript on
onerror {quit -force -code 1}
set out current
set h ../user_source/hdl_source
set lib $out/stats_work
if {![file exists $lib]} {vlib $lib}
vlog -sv -work $lib $h/integration/awb_mcu96.v $out/awb_mcu96_reference.v $out/tb_exposure_stats.sv
vsim -voptargs=+acc -wlf $out/stats.wlf -lib $lib tb_exposure_stats
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_exposure_stats/test_passed]!=1} {quit -force -code 1}
puts "EXPOSURE_STATS_ALL_PASS"
quit -force -code 0
