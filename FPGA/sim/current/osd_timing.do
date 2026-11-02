transcript on
onerror {quit -force -code 1}
set out current
set h ../user_source/hdl_source
set lib $out/osd_timing_work
if {![file exists $lib]} {vlib $lib}
vlog -sv -work $lib $h/isp/target_result_cdc.v $h/anlogic_logo_rom.v $h/camera_settings_osd.v $out/camera_settings_osd_timing_reference.v $out/tb_osd_timing.sv
vsim -voptargs=+acc -wlf $out/osd_timing.wlf -lib $lib tb_osd_timing
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_osd_timing/test_passed]!=1} {quit -force -code 1}
puts "OSD_TIMING_ALL_PASS"
quit -force -code 0
