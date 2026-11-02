# FX5 final1_post frame-atomic selection test. No TD or implementation tools.
transcript on
onerror {quit -force -code 1}
set out current
set h ../user_source/hdl_source
set lib $out/ascii_post_work
if {![file exists $lib]} {vlib $lib}
vlog -sv -work $lib $out/isp_line_ram_model.v
set sources [list $h/integration/final1_post.v $h/integration/pixel_art_96.v \
 $h/integration/hatch_sketch_96.v $h/integration/cartoon_96.v $h/integration/rgb_edge_smooth_4px.v \
 $h/integration/isp_stream_primitives.v $h/integration/final1_pack.v $h/integration/awb_mcu96.v \
 $h/integration/green_gain96.v $out/tb_ascii_post.sv]
foreach f $sources {vlog -sv -work $lib $f}
vsim -voptargs=+acc -wlf $out/ascii_post.wlf -lib $lib tb_ascii_post
onfinish stop
run -all
if {[examine -radix unsigned sim:/tb_ascii_post/test_passed] != 1} {quit -force -code 1}
puts "ASCII_POST_ALL_PASS"
quit -force -code 0
