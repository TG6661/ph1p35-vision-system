transcript on
onerror {quit -force -code 1}
set out current
set h ../user_source/hdl_source
set lib $out/crt_latency_work
if {![file exists $lib]} {vlib $lib}

vlog -sv -work $lib $out/isp_line_ram_model.v $out/ref_primitives.v $out/defect_cartoon.v $out/ref_cartoon_aligned.v $out/tb_crt_latency.sv
vsim -voptargs=+acc -wlf $out/crt_latency.wlf -lib $lib tb_crt_latency
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_crt_latency/test_passed]!=1} {quit -force -code 1}
puts "STYLE_CRT_LATENCY_ALL_PASS"
quit -force -code 0
