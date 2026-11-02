transcript on
onerror {quit -force -code 1}
set lib current/actual_manifest_work
if {![file exists $lib]} {vlib $lib}
vlog -work $lib {../user_source/hdl_source/isp/raw10_same_phase_filter.v}
vlog -work $lib {../user_source/hdl_source/isp/connected_components_rle_4.v}
vlog -work $lib {../user_source/hdl_source/isp/target_result_cdc.v}
vlog -work $lib {../user_source/hdl_source/isp/target_result_buffer.v}
vlog -work $lib {../user_source/hdl_source/isp/target_osd_font.v}
vlog -work $lib {../user_source/hdl_source/isp/target_mask_frame_buffer.v}
vlog -work $lib {../user_source/hdl_source/isp/target_first_eight.v}
vlog -work $lib {../user_source/hdl_source/isp/target_track_osd.v}
vlog -work $lib {../user_source/hdl_source/isp/view_mode_cdc.v}
vlog -work $lib {../user_source/hdl_source/isp/red_target_video.v}
vlog -work $lib {../user_source/hdl_source/isp/binary_morph_bram_4.v}
vlog -work $lib {../user_source/hdl_source/isp/binary_open_bram_4.v}
vlog -work $lib {../user_source/hdl_source/isp/color_segment_96.v}
vlog -work $lib {../user_source/hdl_source/design_top_wrapper.v}
vlog -work $lib {../user_source/hdl_source/video_in.v}
vlog -work $lib {../user_source/hdl_source/video_out.v}
vlog -work $lib {../user_source/hdl_source/mc_to_user_interface.v}
vlog -work $lib {../user_source/hdl_source/signal_delay.v}
vlog -work $lib {../user_source/hdl_source/awb.v}
vlog -work $lib {../user_source/hdl_source/ph1p35_ddr/ph1p35_324_ddr_wrapper.v}
vlog -work $lib {../user_source/hdl_source/isp/csi_unpacket_2lane.v}
vlog -work $lib {../user_source/hdl_source/isp/axis_gamma_rgb96.v}
vlog -work $lib {../user_source/hdl_source/isp/isp_top.v}
vlog -work $lib {../user_source/hdl_source/isp/raw10_unpacket_2lane.v}
vlog -work $lib {../user_source/hdl_source/isp/uial2axis.v}
vlog -work $lib {../user_source/hdl_source/isp/demosaic_4x_2_0/bilinear_interpolation.v}
vlog -work $lib {../user_source/hdl_source/isp/demosaic_4x_2_0/demosaic.v}
vlog -work $lib {../user_source/hdl_source/isp/demosaic_4x_2_0/line_buffer_demosaic.v}
vlog -work $lib {../user_source/hdl_source/isp/demosaic_4x_2_0/mipi_to_raw_converter.v}
vlog -work $lib {../user_source/hdl_source/isp/demosaic_4x_2_0/raw_matrix_3x3_buffer.v}
vlog -work $lib {../user_source/hdl_source/isp/demosaic_4x_2_0/zhenghe.v}
vlog -work $lib {../user_source/hdl_source/isp/data128_96/data128_96.v}
vlog -work $lib {../user_source/hdl_source/isp/data96_128/data96_128.v}
vlog -work $lib {../user_source/hdl_source/i2c/uii2c.v}
vlog -work $lib {../user_source/hdl_source/hdmi_tx.v}
vlog -work $lib {../user_source/hdl_source/hdmi_1_4b_transmitter_core_wrapper.enc.v}
vlog -work $lib {../user_source/hdl_source/hdmi_phy_warpper.v}
vlog -work $lib {../user_source/hdl_source/lane_lvds_10_1.v}
vlog -work $lib {../user_source/hdl_source/vtc/uivtc.v}
vlog -work $lib {../user_source/hdl_source/hdmi_mixer.v}
vlog -work $lib {../user_source/hdl_source/I2S_receiver.v}
vlog -work $lib {../user_source/hdl_source/audio_arc_calculate.v}
vlog -work $lib {../user_source/hdl_source/key_remove_shakes.v}
vlog -work $lib {../user_source/hdl_source/uics520_cfg/sc520_powerup.v}
vlog -sv -work $lib {../user_source/hdl_source/mipi_dphy_rx/mipi_dphy_rx_ph1p_mipiio_wrapper.sv}
vlog -work $lib {../user_source/hdl_source/mipi_dphy_rx/ph1p_mipiio_rx_wrapper.v}
vlog -work $lib {../user_source/hdl_source/mipi_dphy_rx/byte_aligner.enc.v}
vlog -sv -work $lib {../user_source/hdl_source/mipi_dphy_rx/byte_aligner_wrapper.enc.sv}
vlog -work $lib {../user_source/hdl_source/mipi_dphy_rx/channel_aligner.enc.v}
vlog -sv -work $lib {../user_source/hdl_source/mipi_dphy_rx/channel_aligner_wrapper.enc.sv}
vlog -work $lib {../user_source/hdl_source/mipi_dphy_rx/hs_detect.enc.v}
vlog -work $lib {../user_source/hdl_source/isp/rgb_frame_replay.v}
vlog -work $lib {../user_source/hdl_source/anlogic_logo_rom.v}
vlog -work $lib {../user_source/hdl_source/camera_settings_osd.v}
vlog -work $lib {../user_source/hdl_source/mcu_reset_sync.v}
vlog -work $lib {../user_source/hdl_source/ahb_ctrl_regs.v}
vlog -work $lib {../user_source/hdl_source/mcu_bringup.v}
vlog -work $lib {../user_source/hdl_source/mcu_threshold_ctrl.v}
vlog -work $lib {../user_source/hdl_source/integration/awb_mcu96.v}
vlog -work $lib {../user_source/hdl_source/integration/cartoon_96.v}
vlog -work $lib {../user_source/hdl_source/integration/final1_ddr_arbiter.v}
vlog -work $lib {../user_source/hdl_source/integration/final1_line_replay.v}
vlog -work $lib {../user_source/hdl_source/integration/final1_mailbox.v}
vlog -work $lib {../user_source/hdl_source/integration/final1_motion_osd.v}
vlog -work $lib {../user_source/hdl_source/integration/final1_pack.v}
vlog -work $lib {../user_source/hdl_source/integration/final1_post.v}
vlog -work $lib {../user_source/hdl_source/integration/final1_raw_front.v}
vlog -work $lib {../user_source/hdl_source/integration/final1_regs.v}
vlog -work $lib {../user_source/hdl_source/integration/final1_runtime.v}
vlog -work $lib {../user_source/hdl_source/integration/green_gain96.v}
vlog -work $lib {../user_source/hdl_source/integration/hatch_sketch_96.v}
vlog -work $lib {../user_source/hdl_source/integration/isp_line_ram.v}
vlog -work $lib {../user_source/hdl_source/integration/isp_stream_primitives.v}
vlog -work $lib {../user_source/hdl_source/integration/motion_detect_8x8.v}
vlog -work $lib {../user_source/hdl_source/integration/pixel_art_96.v}
vlog -work $lib {../user_source/hdl_source/integration/rgb_edge_smooth_4px.v}
puts "AHB_READMUX_ACTUAL_MANIFEST_COMPILE_PASS files=76"
quit -force -code 0
