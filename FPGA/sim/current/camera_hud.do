transcript on
onerror {quit -force -code 1}
set out current
set lib $out/camera_hud_work
if {![file exists $lib]} {vlib $lib}
set h ../user_source/hdl_source
vlog -sv -work $lib $h/mcu_reset_sync.v $h/isp/target_result_cdc.v $h/i2c/uii2c.v $h/mcu_bringup.v $h/ahb_ctrl_regs.v $h/anlogic_logo_rom.v $h/camera_settings_osd.v $out/tb_camera_hud_current.sv
vsim -voptargs=+acc -wlf $out/camera_hud.wlf -lib $lib tb_mcu_camera_hud
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_mcu_camera_hud/test_passed]!=1} {quit -force -code 1}
puts "GIMBAL_AHB_HUD_CDC_ALL_PASS"
quit -force -code 0
