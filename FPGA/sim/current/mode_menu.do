transcript on
onerror {quit -force -code 1}
set out current
set h ../user_source/hdl_source
set lib $out/mode_menu_work
if {![file exists $lib]} {vlib $lib}
vlog -sv -work $lib $h/isp/target_result_cdc.v $h/anlogic_logo_rom.v $h/camera_settings_osd.v $out/camera_settings_osd_reference.v $out/tb_mode_menu.sv
vsim -voptargs=+acc -wlf $out/mode_menu.wlf -lib $lib tb_mode_menu
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_mode_menu/test_passed]!=1} {quit -force -code 1}
puts "MODE_MENU_ALL_PASS"
quit -force -code 0
