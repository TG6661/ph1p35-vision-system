# FX5 ASCII directed functional test. No TD or implementation tools.
transcript on
onerror {quit -force -code 1}
set out current
set h ../user_source/hdl_source
set lib $out/ascii_full_work
if {![file exists $lib]} {vlib $lib}
vlog -sv -work $lib $h/integration/final1_post.v $out/isp_line_ram_model.v $out/tb_ascii_full.sv
vsim -voptargs=+acc -wlf $out/ascii_full.wlf -lib $lib tb_ascii_full
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_ascii_full/test_passed] != 1} {quit -force -code 1}
puts "ASCII_ART_ALL_PASS"
quit -force -code 0
