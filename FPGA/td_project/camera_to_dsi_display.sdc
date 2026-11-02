# OOPFPGA FINAL-only with bounded parameter/menu CDC.
# DDR publication handshakes, valid metadata and reader recovery bounds remain.
create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
create_clock -name {mipi_rx_ck_pad} -period 2.415 -waveform {0.000 1.208} [get_nets {IO_rx_clk_pad_p}]

# Match the generated MCU IP's AHB_DIV=2 using the full instantiated path.
# TD needs this property to derive the MCU AHB clock AND hard-IP interface
# timing relationships. An independent create_clock on ahb_clk overrides that
# model and produces incorrect core<->AHB setup/hold checks.
set_ip_property AHB_DIV 2 [get_cells {u_mcu_bringup/u_core/MCU_a3eb6603d49b_Inst/PH1P_PHY_MCU_Inst}]
derive_clocks

# Core=300 MHz, timer=100 MHz, derived AHB=150 MHz, buffered APB=50 MHz.
# Only independent asynchronous inputs to first-stage synchronizers are cut.
# The meta->sync paths and all AHB register logic remain timed at 150 MHz.
set_false_path -to [get_regs -hier {u_mcu_bringup/u_regs/button_meta*}]
set_false_path -to [get_regs -hier {u_mcu_bringup/u_regs/status_meta*}]
# Reset assertion is asynchronous; each domain releases through its own chain.
set_false_path -from [get_ports {I_rst_n}] -to [get_regs -hier {u_mcu_bringup/u_core_reset/release_pipe*}]
set_false_path -from [get_ports {I_rst_n}] -to [get_regs -hier {u_mcu_bringup/u_apb_reset/release_pipe*}]
set_false_path -from [get_ports {I_rst_n}] -to [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}]

rename_clock -name {pll_clk_100m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI_PIXEL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]
rename_clock -name {HDMI_SERIAL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}]

rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]


set_clock_groups -asynchronous \
    -group [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] \
    -group [get_clocks {sys_clk_50m pll_clk_100m pll_clk_24m HDMI_PIXEL_CLK HDMI_SERIAL_CLK}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]


set_max_delay -datapath_only -from [get_regs {u_video_in/u_cdc/request}] -to [get_regs -hier {u_video_in/u_cdc/req_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_video_in/u_cdc/ack}] -to [get_regs -hier {u_video_in/u_cdc/ack_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs -hier {u_video_out/g_frame_id$u_metadata/published*}] -to [get_regs -hier {u_video_out/g_frame_id$u_metadata/received*}] 20.0
set_max_delay -datapath_only -from [get_regs {u_video_out/g_frame_id$u_metadata/u_cdc/request}] -to [get_regs -hier {u_video_out/g_frame_id$u_metadata/u_cdc/req_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_video_out/g_frame_id$u_metadata/u_cdc/ack}] -to [get_regs -hier {u_video_out/g_frame_id$u_metadata/u_cdc/ack_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_video_in/source_bad}] -to [get_regs -hier {u_video_in/bad_sync[0]}] 10.0

set_max_delay -datapath_only -from [get_regs {u_video_out/pixel_fault}] -to [get_regs -hier {u_video_out/fault_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_video_out/overflow_frame}] -to [get_regs -hier {u_video_out/overflow_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_video_out/S_fifo_rst}] -to [get_regs -hier {u_video_out/fifo_reset_sync[0]}] 10.0




set_max_delay -datapath_only -from [get_regs {u_color_capture/u_cdc/request}] -to [get_regs -hier {u_color_capture/u_cdc/req_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_color_capture/u_cdc/ack}] -to [get_regs -hier {u_color_capture/u_cdc/ack_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_color_capture/source_bad}] -to [get_regs -hier {u_color_capture/bad_sync[0]}] 10.0

# Restored parameter and HUD coherent held-bus transfers.
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_services/hud_command*}] -to [get_regs -hier {u_camera_settings/staged*}] 20.0
set_max_delay -datapath_only -from [get_regs {u_camera_settings/u_cdc/request}] -to [get_regs -hier {u_camera_settings/u_cdc/req_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_camera_settings/u_cdc/ack}] -to [get_regs -hier {u_camera_settings/u_cdc/ack_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs -hier {u_filter_config/published*}] -to [get_regs -hier {u_filter_config/received*}] 20.0
set_max_delay -datapath_only -from [get_regs {u_filter_config/u_cdc/request}] -to [get_regs -hier {u_filter_config/u_cdc/req_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_filter_config/u_cdc/ack}] -to [get_regs -hier {u_filter_config/u_cdc/ack_sync[0]}] 10.0

# MCU threshold bundled-data transfers. Payload is held until acknowledgement.
# AHB-generated reset is asynchronous at these four CDC instances. Only their
# reset synchronizer chains receive it directly (SYNC_RELEASE=1). Exempt that
# raw reset input; local reset release -> handshake/payload flops stays timed.
# Do NOT cut the MCU/AHB clocks or all threshold registers as a group.
set_false_path -from [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_command/sr* u_mcu_bringup/u_thresholds/u_command/dr*}]
set_false_path -from [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_frame/sr* u_mcu_bringup/u_thresholds/u_frame/dr*}]
set_false_path -from [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_selected_status/u_cdc/sr* u_mcu_bringup/u_thresholds/u_selected_status/u_cdc/dr*}]
set_false_path -from [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_active_status/u_cdc/sr* u_mcu_bringup/u_thresholds/u_active_status/u_cdc/dr*}]
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_regs/O_command*}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/mcu_value*}] 20.0
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_regs/O_command*}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/owner}] 20.0
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_regs/O_command*}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/published*}] 20.0
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_regs/O_command*}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/response*}] 20.0
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_regs/O_command*}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/last_sent*}] 20.0
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_thresholds/published*}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/staged*}] 20.0
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_thresholds/response*}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/completed*}] 20.0
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_thresholds/u_selected_status/published*}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_selected_status/received*}] 20.0
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_thresholds/u_active_status/published*}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_active_status/received*}] 20.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_thresholds/u_command/request}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_command/req_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_thresholds/u_command/ack}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_command/ack_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_thresholds/u_frame/request}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_frame/req_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_thresholds/u_frame/ack}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_frame/ack_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_thresholds/u_selected_status/u_cdc/request}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_selected_status/u_cdc/req_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_thresholds/u_selected_status/u_cdc/ack}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_selected_status/u_cdc/ack_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_thresholds/u_active_status/u_cdc/request}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_active_status/u_cdc/req_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_thresholds/u_active_status/u_cdc/ack}] -to [get_regs -hier {u_mcu_bringup/u_thresholds/u_active_status/u_cdc/ack_sync[0]}] 10.0

# MCU menu snapshot: same local reset-release policy as the threshold bridge.
set_false_path -from [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}] -to [get_regs -hier {u_mcu_bringup/u_menu/u_cdc/sr* u_mcu_bringup/u_menu/u_cdc/dr*}]
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_regs/O_menu_command*}] -to [get_regs -hier {u_mcu_bringup/u_menu/settings*}] 20.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_menu/u_cdc/request}] -to [get_regs -hier {u_mcu_bringup/u_menu/u_cdc/req_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_menu/u_cdc/ack}] -to [get_regs -hier {u_mcu_bringup/u_menu/u_cdc/ack_sync[0]}] 10.0

# v4 target mailbox. Each bus is held until its own acknowledged release.
# Record payloads now cross through independent-clock ERAM ports, with immutable
# ownership until ACK. Metadata still uses held buses and rx_guard. RAM output
# paths are timed in their destination clocks; do not false-path those reads.
set_false_path -from [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}] -to [get_regs -hier {u_mcu_bringup/u_targets/u_raw_cdc/sr* u_mcu_bringup/u_targets/u_raw_cdc/dr* u_mcu_bringup/u_targets/u_result_cdc/sr* u_mcu_bringup/u_targets/u_result_cdc/dr*}]
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_targets/published*}] -to [get_regs -hier {u_mcu_bringup/u_targets/rx_sequence* u_mcu_bringup/u_targets/rx_frame* u_mcu_bringup/u_targets/rx_count* u_mcu_bringup/u_targets/rx_total* u_mcu_bringup/u_targets/rx_error* u_mcu_bringup/u_targets/rx_dropped*}] 20.0
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_targets/tx_count* u_mcu_bringup/u_targets/tx_error* u_mcu_bringup/u_targets/tx_frame*}] -to [get_regs -hier {u_mcu_bringup/u_targets/m_count* u_mcu_bringup/u_targets/m_error* u_mcu_bringup/u_targets/m_frame* u_mcu_bringup/u_targets/state*}] 20.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_targets/u_raw_cdc/request}] -to [get_regs -hier {u_mcu_bringup/u_targets/u_raw_cdc/req_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_targets/u_raw_cdc/ack}] -to [get_regs -hier {u_mcu_bringup/u_targets/u_raw_cdc/ack_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_targets/u_result_cdc/request}] -to [get_regs -hier {u_mcu_bringup/u_targets/u_result_cdc/req_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_targets/u_result_cdc/ack}] -to [get_regs -hier {u_mcu_bringup/u_targets/u_result_cdc/ack_sync[0]}] 10.0
# Cancel partial output banks when the target bridge resets. Only synchronizer
# entry flops see the incoming detector-domain reset; local release stays timed.
set_false_path -from [get_regs -hier {u_mcu_bringup/u_targets/u_result_cdc/dr*}] -to [get_regs -hier {u_red_targets/u_results/u_cdc/sr* u_red_targets/u_results/u_cdc/dr*}]
set_false_path -from [get_regs {u_mcu_bringup/u_targets/alive_flag}] -to [get_regs -hier {u_red_targets/alive_sync[0]}]

# v5 camera command/result and MCU-produced HUD payloads. Held until ack.
set_false_path -from [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}] -to [get_regs -hier {u_mcu_bringup/u_services/u_camera_cdc/sr* u_mcu_bringup/u_services/u_camera_cdc/dr* u_camera_settings/u_cdc/sr* u_camera_settings/u_cdc/dr*}]
set_false_path -to [get_regs -hier {u_mcu_bringup/u_services/ready_sync[0]}]
set_false_path -to [get_regs -hier {u_camera_settings/status_meta*}]
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_services/command*}] -to [get_regs -hier {u_mcu_bringup/u_services/wr_data* u_mcu_bringup/u_services/mode u_mcu_bringup/u_services/camera_state* u_mcu_bringup/u_services/state* u_mcu_bringup/u_services/req u_mcu_bringup/u_services/accept u_mcu_bringup/u_services/response*}] 20.0
set_max_delay -datapath_only -from [get_regs -hier {u_mcu_bringup/u_services/response*}] -to [get_regs -hier {u_mcu_bringup/u_services/read_data* u_mcu_bringup/u_services/last_nack u_mcu_bringup/u_services/sticky_nack}] 20.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_services/u_camera_cdc/request}] -to [get_regs -hier {u_mcu_bringup/u_services/u_camera_cdc/req_sync[0]}] 10.0
set_max_delay -datapath_only -from [get_regs {u_mcu_bringup/u_services/u_camera_cdc/ack}] -to [get_regs -hier {u_mcu_bringup/u_services/u_camera_cdc/ack_sync[0]}] 10.0

# Stage9: runtime common reset asserts asynchronously; only local release
# chains see AHB reset. Local release -> state/data/RAM controls remains timed.
# Bundled buses remain held until the returning ACK. Bound data and first-stage
# crossing routes to 10 ns; exclude only their meaningless inter-clock hold
# checks. Second synchronizer stages and all destination consumers stay timed.
# Do not add the MCU clock to global asynchronous groups.
set_false_path -from [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}] -to [get_regs -hier {u_final1/u_camera_reset/release_pipe* u_final1/u_ddr_reset/release_pipe* u_final1/u_ahb_reset/release_pipe* u_final1/u_pixel_reset/release_pipe* u_final1/u_cfg/u_src_reset/release_pipe* u_final1/u_cfg/u_dst_reset/release_pipe* u_final1/u_results/u_src_reset/release_pipe* u_final1/u_results/u_dst_reset/release_pipe* u_final1/u_gains/u_src_reset/release_pipe* u_final1/u_gains/u_dst_reset/release_pipe* u_final1/u_ui/u_src_reset/release_pipe* u_final1/u_ui/u_dst_reset/release_pipe* u_final1/u_gain_complete/u_src_reset/release_pipe* u_final1/u_gain_complete/u_dst_reset/release_pipe* u_final1/u_applied/u_src_reset/release_pipe* u_final1/u_applied/u_dst_reset/release_pipe* u_final1/u_camera_config/u_src_reset/release_pipe* u_final1/u_camera_config/u_dst_reset/release_pipe* u_final1/u_awb_stats/u_src_reset/release_pipe* u_final1/u_awb_stats/u_dst_reset/release_pipe* u_final1/u_motion_stats/u_src_reset/release_pipe* u_final1/u_motion_stats/u_dst_reset/release_pipe* u_final1/u_camera_diag/u_src_reset/release_pipe* u_final1/u_camera_diag/u_dst_reset/release_pipe* u_final1/u_post_diag/u_src_reset/release_pipe* u_final1/u_post_diag/u_dst_reset/release_pipe* u_final1/u_profile/u_src_reset/release_pipe* u_final1/u_profile/u_dst_reset/release_pipe* u_final1/u_motion_controls/u_dwell/u_src_reset/release_pipe* u_final1/u_motion_controls/u_dwell/u_dst_reset/release_pipe* u_final1/u_motion_controls/u_display/u_src_reset/release_pipe* u_final1/u_motion_controls/u_display/u_dst_reset/release_pipe* u_final1/u_capture/u_cdc/sr* u_final1/u_capture/u_cdc/dr*}]
set_false_path -from [get_ports {I_rst_n}] -to [get_regs -hier {u_final1/u_camera_reset/release_pipe* u_final1/u_ddr_reset/release_pipe* u_final1/u_ahb_reset/release_pipe* u_final1/u_pixel_reset/release_pipe* u_final1/u_cfg/u_src_reset/release_pipe* u_final1/u_cfg/u_dst_reset/release_pipe* u_final1/u_results/u_src_reset/release_pipe* u_final1/u_results/u_dst_reset/release_pipe* u_final1/u_gains/u_src_reset/release_pipe* u_final1/u_gains/u_dst_reset/release_pipe* u_final1/u_ui/u_src_reset/release_pipe* u_final1/u_ui/u_dst_reset/release_pipe* u_final1/u_gain_complete/u_src_reset/release_pipe* u_final1/u_gain_complete/u_dst_reset/release_pipe* u_final1/u_applied/u_src_reset/release_pipe* u_final1/u_applied/u_dst_reset/release_pipe* u_final1/u_camera_config/u_src_reset/release_pipe* u_final1/u_camera_config/u_dst_reset/release_pipe* u_final1/u_awb_stats/u_src_reset/release_pipe* u_final1/u_awb_stats/u_dst_reset/release_pipe* u_final1/u_motion_stats/u_src_reset/release_pipe* u_final1/u_motion_stats/u_dst_reset/release_pipe* u_final1/u_camera_diag/u_src_reset/release_pipe* u_final1/u_camera_diag/u_dst_reset/release_pipe* u_final1/u_post_diag/u_src_reset/release_pipe* u_final1/u_post_diag/u_dst_reset/release_pipe* u_final1/u_profile/u_src_reset/release_pipe* u_final1/u_profile/u_dst_reset/release_pipe* u_final1/u_motion_controls/u_dwell/u_src_reset/release_pipe* u_final1/u_motion_controls/u_dwell/u_dst_reset/release_pipe* u_final1/u_motion_controls/u_display/u_src_reset/release_pipe* u_final1/u_motion_controls/u_display/u_dst_reset/release_pipe* u_final1/u_capture/u_cdc/sr* u_final1/u_capture/u_cdc/dr*}]

# u_cfg
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_regs/cfg_data*}] -to [get_regs -hier {u_final1/u_cfg/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_regs/cfg_data*}] -to [get_regs -hier {u_final1/u_cfg/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_cfg/request}] -to [get_regs -hier {u_final1/u_cfg/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_cfg/request}] -to [get_regs -hier {u_final1/u_cfg/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_cfg/ack}] -to [get_regs -hier {u_final1/u_cfg/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_cfg/ack}] -to [get_regs -hier {u_final1/u_cfg/ack_sync[0]}]

# u_results
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_regs/result_data*}] -to [get_regs -hier {u_final1/u_results/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_regs/result_data*}] -to [get_regs -hier {u_final1/u_results/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_results/request}] -to [get_regs -hier {u_final1/u_results/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_results/request}] -to [get_regs -hier {u_final1/u_results/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_results/ack}] -to [get_regs -hier {u_final1/u_results/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_results/ack}] -to [get_regs -hier {u_final1/u_results/ack_sync[0]}]

# u_gains
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_regs/gain_data*}] -to [get_regs -hier {u_final1/u_gains/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_regs/gain_data*}] -to [get_regs -hier {u_final1/u_gains/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_gains/request}] -to [get_regs -hier {u_final1/u_gains/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_gains/request}] -to [get_regs -hier {u_final1/u_gains/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_gains/ack}] -to [get_regs -hier {u_final1/u_gains/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_gains/ack}] -to [get_regs -hier {u_final1/u_gains/ack_sync[0]}]

# u_ui
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_ui/g_internal*held*}] -to [get_regs -hier {u_final1/u_ui/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_ui/g_internal*held*}] -to [get_regs -hier {u_final1/u_ui/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_ui/request}] -to [get_regs -hier {u_final1/u_ui/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_ui/request}] -to [get_regs -hier {u_final1/u_ui/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_ui/ack}] -to [get_regs -hier {u_final1/u_ui/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_ui/ack}] -to [get_regs -hier {u_final1/u_ui/ack_sync[0]}]

# u_gain_complete
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_gain_complete/g_internal*held*}] -to [get_regs -hier {u_final1/u_gain_complete/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_gain_complete/g_internal*held*}] -to [get_regs -hier {u_final1/u_gain_complete/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_gain_complete/request}] -to [get_regs -hier {u_final1/u_gain_complete/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_gain_complete/request}] -to [get_regs -hier {u_final1/u_gain_complete/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_gain_complete/ack}] -to [get_regs -hier {u_final1/u_gain_complete/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_gain_complete/ack}] -to [get_regs -hier {u_final1/u_gain_complete/ack_sync[0]}]

# u_applied
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_applied/g_internal*held*}] -to [get_regs -hier {u_final1/u_applied/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_applied/g_internal*held*}] -to [get_regs -hier {u_final1/u_applied/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_applied/request}] -to [get_regs -hier {u_final1/u_applied/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_applied/request}] -to [get_regs -hier {u_final1/u_applied/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_applied/ack}] -to [get_regs -hier {u_final1/u_applied/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_applied/ack}] -to [get_regs -hier {u_final1/u_applied/ack_sync[0]}]

# u_camera_config
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_camera_config/g_internal*held*}] -to [get_regs -hier {u_final1/u_camera_config/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_camera_config/g_internal*held*}] -to [get_regs -hier {u_final1/u_camera_config/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_camera_config/request}] -to [get_regs -hier {u_final1/u_camera_config/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_camera_config/request}] -to [get_regs -hier {u_final1/u_camera_config/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_camera_config/ack}] -to [get_regs -hier {u_final1/u_camera_config/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_camera_config/ack}] -to [get_regs -hier {u_final1/u_camera_config/ack_sync[0]}]

# u_awb_stats
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_awb_stats/g_internal*held*}] -to [get_regs -hier {u_final1/u_awb_stats/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_awb_stats/g_internal*held*}] -to [get_regs -hier {u_final1/u_awb_stats/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_awb_stats/request}] -to [get_regs -hier {u_final1/u_awb_stats/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_awb_stats/request}] -to [get_regs -hier {u_final1/u_awb_stats/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_awb_stats/ack}] -to [get_regs -hier {u_final1/u_awb_stats/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_awb_stats/ack}] -to [get_regs -hier {u_final1/u_awb_stats/ack_sync[0]}]

# u_motion_stats
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_motion_stats/g_internal*held*}] -to [get_regs -hier {u_final1/u_motion_stats/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_motion_stats/g_internal*held*}] -to [get_regs -hier {u_final1/u_motion_stats/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_motion_stats/request}] -to [get_regs -hier {u_final1/u_motion_stats/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_motion_stats/request}] -to [get_regs -hier {u_final1/u_motion_stats/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_motion_stats/ack}] -to [get_regs -hier {u_final1/u_motion_stats/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_motion_stats/ack}] -to [get_regs -hier {u_final1/u_motion_stats/ack_sync[0]}]

# u_camera_diag
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_camera_diag/g_internal*held*}] -to [get_regs -hier {u_final1/u_camera_diag/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_camera_diag/g_internal*held*}] -to [get_regs -hier {u_final1/u_camera_diag/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_camera_diag/request}] -to [get_regs -hier {u_final1/u_camera_diag/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_camera_diag/request}] -to [get_regs -hier {u_final1/u_camera_diag/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_camera_diag/ack}] -to [get_regs -hier {u_final1/u_camera_diag/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_camera_diag/ack}] -to [get_regs -hier {u_final1/u_camera_diag/ack_sync[0]}]

# u_post_diag
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_post_diag/g_internal*held*}] -to [get_regs -hier {u_final1/u_post_diag/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_post_diag/g_internal*held*}] -to [get_regs -hier {u_final1/u_post_diag/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_post_diag/request}] -to [get_regs -hier {u_final1/u_post_diag/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_post_diag/request}] -to [get_regs -hier {u_final1/u_post_diag/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_post_diag/ack}] -to [get_regs -hier {u_final1/u_post_diag/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_post_diag/ack}] -to [get_regs -hier {u_final1/u_post_diag/ack_sync[0]}]

# u_profile
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_profile/g_internal*held*}] -to [get_regs -hier {u_final1/u_profile/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_profile/g_internal*held*}] -to [get_regs -hier {u_final1/u_profile/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_profile/request}] -to [get_regs -hier {u_final1/u_profile/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_profile/request}] -to [get_regs -hier {u_final1/u_profile/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_profile/ack}] -to [get_regs -hier {u_final1/u_profile/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_profile/ack}] -to [get_regs -hier {u_final1/u_profile/ack_sync[0]}]

# u_motion_controls/u_dwell
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_motion_controls/u_dwell/g_internal*held*}] -to [get_regs -hier {u_final1/u_motion_controls/u_dwell/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_motion_controls/u_dwell/g_internal*held*}] -to [get_regs -hier {u_final1/u_motion_controls/u_dwell/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_motion_controls/u_dwell/request}] -to [get_regs -hier {u_final1/u_motion_controls/u_dwell/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_motion_controls/u_dwell/request}] -to [get_regs -hier {u_final1/u_motion_controls/u_dwell/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_motion_controls/u_dwell/ack}] -to [get_regs -hier {u_final1/u_motion_controls/u_dwell/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_motion_controls/u_dwell/ack}] -to [get_regs -hier {u_final1/u_motion_controls/u_dwell/ack_sync[0]}]

# u_motion_controls/u_display
set_max_delay -datapath_only -from [get_regs -hier {u_final1/u_motion_controls/u_display/g_internal*held*}] -to [get_regs -hier {u_final1/u_motion_controls/u_display/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_final1/u_motion_controls/u_display/g_internal*held*}] -to [get_regs -hier {u_final1/u_motion_controls/u_display/received*}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_motion_controls/u_display/request}] -to [get_regs -hier {u_final1/u_motion_controls/u_display/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_motion_controls/u_display/request}] -to [get_regs -hier {u_final1/u_motion_controls/u_display/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_motion_controls/u_display/ack}] -to [get_regs -hier {u_final1/u_motion_controls/u_display/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_motion_controls/u_display/ack}] -to [get_regs -hier {u_final1/u_motion_controls/u_display/ack_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_motion_controls/bg_request}] -to [get_regs -hier {u_final1/u_motion_controls/bg_req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_motion_controls/bg_request}] -to [get_regs -hier {u_final1/u_motion_controls/bg_req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_motion_controls/bg_ack}] -to [get_regs -hier {u_final1/u_motion_controls/bg_ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_motion_controls/bg_ack}] -to [get_regs -hier {u_final1/u_motion_controls/bg_ack_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/camera_ack}] -to [get_regs -hier {u_final1/cam_ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/camera_ack}] -to [get_regs -hier {u_final1/cam_ack_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_capture/source_bad}] -to [get_regs -hier {u_final1/u_capture/bad_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_capture/source_bad}] -to [get_regs -hier {u_final1/u_capture/bad_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_capture/u_cdc/request}] -to [get_regs -hier {u_final1/u_capture/u_cdc/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_capture/u_cdc/request}] -to [get_regs -hier {u_final1/u_capture/u_cdc/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs {u_final1/u_capture/u_cdc/ack}] -to [get_regs -hier {u_final1/u_capture/u_cdc/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs {u_final1/u_capture/u_cdc/ack}] -to [get_regs -hier {u_final1/u_capture/u_cdc/ack_sync[0]}]

# Independent level flags into first-stage synchronizers only.
set_false_path -to [get_regs -hier {u_final1/fault_meta*}]
set_false_path -to [get_regs -hier {u_final1/capture_ready_sync[0]}]
set_false_path -to [get_regs -hier {u_final1/red_ready_sync[0]}]

# Stage10: incoming asynchronous reset to the capture FIFO's local release chains.
# Both stages have asynchronous reset pins. Restrict each exception by source,
# so rst0 -> rst1 D timing and rst1 -> FIFO consumer recovery remain timed.
# The frame flush is synchronous to clkw, asynchronous to clkr; only its read
# side reset entry needs an additional exception (clock groups already cut it).
set_false_path -from [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}] -to [get_regs -hier {u_final1/u_capture/U_w128_d512_fifo/soft_fifo_al_4057d6b76aa6_Inst/asy_w_rst0}]
set_false_path -from [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}] -to [get_regs -hier {u_final1/u_capture/U_w128_d512_fifo/soft_fifo_al_4057d6b76aa6_Inst/asy_w_rst1}]
set_false_path -from [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}] -to [get_regs -hier {u_final1/u_capture/U_w128_d512_fifo/soft_fifo_al_4057d6b76aa6_Inst/asy_r_rst0}]
set_false_path -from [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}] -to [get_regs -hier {u_final1/u_capture/U_w128_d512_fifo/soft_fifo_al_4057d6b76aa6_Inst/asy_r_rst1}]
set_false_path -from [get_regs -hier {u_final1/u_capture/flush*}] -to [get_regs -hier {u_final1/u_capture/U_w128_d512_fifo/soft_fifo_al_4057d6b76aa6_Inst/asy_r_rst0}]
set_false_path -from [get_regs -hier {u_final1/u_capture/flush*}] -to [get_regs -hier {u_final1/u_capture/U_w128_d512_fifo/soft_fifo_al_4057d6b76aa6_Inst/asy_r_rst1}]

# Latency HUD CDC/reset repair (2026-10-26).
# F_latency_reset_n combines PLL lock and MCU AHB reset. Only the raw
# asynchronous entry into the eleven local release chains is exempted.
# Restrict BOTH source and destination: release stages and local consumers
# retain setup/hold and recovery/removal checks. No MCU clock group is cut.
set_false_path -from [get_regs -hier {u_mcu_bringup/u_ahb_reset/release_pipe*}] -to [get_regs -hier {u_latency/u_cr/release_pipe* u_latency/u_mr/release_pipe* u_latency/u_pr/release_pipe* u_latency/u_capture/u_src_reset/release_pipe* u_latency/u_capture/u_dst_reset/release_pipe* u_latency/u_display/u_src_reset/release_pipe* u_latency/u_display/u_dst_reset/release_pipe* u_latency/u_hud/u_src_reset/release_pipe* u_latency/u_hud/u_dst_reset/release_pipe* u_latency_epoch/u_dr/release_pipe* u_latency_epoch/u_pr/release_pipe*}]
set_false_path -from [get_ports {I_rst_n}] -to [get_regs -hier {u_latency/u_cr/release_pipe* u_latency/u_mr/release_pipe* u_latency/u_pr/release_pipe* u_latency/u_capture/u_src_reset/release_pipe* u_latency/u_capture/u_dst_reset/release_pipe* u_latency/u_display/u_src_reset/release_pipe* u_latency/u_display/u_dst_reset/release_pipe* u_latency/u_hud/u_src_reset/release_pipe* u_latency/u_hud/u_dst_reset/release_pipe* u_latency_epoch/u_dr/release_pipe* u_latency_epoch/u_pr/release_pipe*}]

# Each mailbox holds its payload until ACK. Bound only the bundled bus
# and request/ack into FIRST synchronizer stages to 10 ns, following the
# runtime mailbox convention. TD gives set_clock_groups higher priority, so
# capture/epoch and reader DDR crossings still need the independent CDC
# delay audit in sim/latency_sdc_fix_20261026 (see README.md). Those bounds
# are not router-enforced while the legacy asynchronous groups remain.
# Exempt inter-clock hold on those same paths;
# synchronizer stage 0 -> stage 1 and destination logic stay normally timed.

# u_capture
set_max_delay -datapath_only -from [get_regs -hier {u_latency/u_capture/g_internal*held*}] -to [get_regs -hier {u_latency/u_capture/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_latency/u_capture/g_internal*held*}] -to [get_regs -hier {u_latency/u_capture/received*}]
set_max_delay -datapath_only -from [get_regs -hier {u_latency/u_capture/request}] -to [get_regs -hier {u_latency/u_capture/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs -hier {u_latency/u_capture/request}] -to [get_regs -hier {u_latency/u_capture/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs -hier {u_latency/u_capture/ack}] -to [get_regs -hier {u_latency/u_capture/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs -hier {u_latency/u_capture/ack}] -to [get_regs -hier {u_latency/u_capture/ack_sync[0]}]

# u_display
set_max_delay -datapath_only -from [get_regs -hier {u_latency/u_display/g_internal*held*}] -to [get_regs -hier {u_latency/u_display/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_latency/u_display/g_internal*held*}] -to [get_regs -hier {u_latency/u_display/received*}]
set_max_delay -datapath_only -from [get_regs -hier {u_latency/u_display/request}] -to [get_regs -hier {u_latency/u_display/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs -hier {u_latency/u_display/request}] -to [get_regs -hier {u_latency/u_display/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs -hier {u_latency/u_display/ack}] -to [get_regs -hier {u_latency/u_display/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs -hier {u_latency/u_display/ack}] -to [get_regs -hier {u_latency/u_display/ack_sync[0]}]

# u_hud (EXTERNAL_HOLD: packet is held by formatter)
set_max_delay -datapath_only -from [get_regs -hier {u_latency/packet*}] -to [get_regs -hier {u_latency/u_hud/received*}] 10.0
set_false_path -hold -from [get_regs -hier {u_latency/packet*}] -to [get_regs -hier {u_latency/u_hud/received*}]
set_max_delay -datapath_only -from [get_regs -hier {u_latency/u_hud/request}] -to [get_regs -hier {u_latency/u_hud/req_sync[0]}] 10.0
set_false_path -hold -from [get_regs -hier {u_latency/u_hud/request}] -to [get_regs -hier {u_latency/u_hud/req_sync[0]}]
set_max_delay -datapath_only -from [get_regs -hier {u_latency/u_hud/ack}] -to [get_regs -hier {u_latency/u_hud/ack_sync[0]}] 10.0
set_false_path -hold -from [get_regs -hier {u_latency/u_hud/ack}] -to [get_regs -hier {u_latency/u_hud/ack_sync[0]}]

# Sticky overrun flags and epoch publication enter only the first stage.
# published -> reader read_id_valid is same-DDR-clock and remains timed.
set_max_delay -datapath_only -from [get_regs -hier {u_latency/cap_overrun}] -to [get_regs -hier {u_latency/over_meta[1]}] 10.0
set_false_path -hold -from [get_regs -hier {u_latency/cap_overrun}] -to [get_regs -hier {u_latency/over_meta[1]}]
set_max_delay -datapath_only -from [get_regs -hier {u_latency/disp_overrun}] -to [get_regs -hier {u_latency/over_meta[0]}] 10.0
set_false_path -hold -from [get_regs -hier {u_latency/disp_overrun}] -to [get_regs -hier {u_latency/over_meta[0]}]
set_max_delay -datapath_only -from [get_regs -hier {u_latency_epoch/published}] -to [get_regs -hier {u_latency_epoch/fresh_sync[0]}] 10.0
set_false_path -hold -from [get_regs -hier {u_latency_epoch/published}] -to [get_regs -hier {u_latency_epoch/fresh_sync[0]}]
