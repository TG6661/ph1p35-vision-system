transcript on
onerror {quit -force -code 1}
set out current
set h ../user_source/hdl_source
set lib $out/cl_work
if {![file exists $lib]} {vlib $lib}

vlog -sv -work $lib $h/integration/final1_post.v $out/ref_color_select.v $out/tb_style_cl.sv
vsim -voptargs=+acc -wlf $out/cl.wlf -lib $lib tb_style_cl
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_style_cl/test_passed]!=1} {quit -force -code 1}
puts "STYLE_CL_ALL_PASS"
quit -force -code 0
