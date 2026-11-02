transcript on
onerror {quit -force -code 1}
set out current
set h ../user_source/hdl_source
set lib $out/crt_work
if {![file exists $lib]} {vlib $lib}

vlog -sv -work $lib $out/isp_line_ram_model.v $h/integration/isp_stream_primitives.v $h/integration/cartoon_96.v $out/ref_primitives.v $out/ref_cartoon_aligned.v $out/tb_style_crt.sv
vsim -voptargs=+acc -wlf $out/crt.wlf -lib $lib tb_style_crt
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_style_crt/test_passed]!=1} {quit -force -code 1}
puts "STYLE_CRT_ALL_PASS"
quit -force -code 0
