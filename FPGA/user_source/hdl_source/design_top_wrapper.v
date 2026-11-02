/*
 * design_top_wrapper：SC520CS 摄像头采集与 HDMI 实时显示的系统顶层。
 *
 * 主视频数据通路：
 *   SC520CS -> MIPI D-PHY -> CSI-2 解包 -> RAW10 解包
 *           -> AXI4-Stream -> ISP -> DDR 帧缓存 -> HDMI 时序/混合 -> TMDS
 *
 * 本模块本身主要负责“连接和调度”：统一生成各级时钟、配置摄像头、
 * 例化各处理模块，并在摄像头、DDR、HDMI 三个时钟域之间组织数据传输。
 * 真正的像素算法位于 isp_top 等下级模块中。
 */
module design_top_wrapper (
    // 板级系统时钟与外部低有效复位
    input wire [3:0]  I_button,        // D5 up, A9 down, B9 plus, C7 minus; active low
    input wire        I_sys_clk,       // PLL 和 DDR 控制器的参考时钟
    input wire        I_rst_n,         // 外部低有效复位，仅直接送入 PLL
    input wire        I_uart0_rx,      // MCU debug UART, J1
    output wire       O_servo_pan,O_servo_tilt, // J2 C18 / D15 PWM outputs
    output wire       O_uart0_tx,      // MCU debug UART, H1
      
    // SC520CS 控制接口：I2C 配置、主时钟和硬件复位
    output wire       O_cam_scl,       // 摄像头 I2C/SCCB 时钟
    inout  wire       IO_cam_sda,       // 摄像头 I2C/SCCB 双向数据
    output wire       O_cam_24m,        // 摄像头约 23.809524 MHz 主时钟
    output wire       O_cam_rst,        // 摄像头 PWDNB/XSHUTDN，高电平工作
      

    // HDMI 显示接口
    output wire       O_screen_pwm,     // 显示屏背光/PWM，本例固定为高电平
    output wire       O_tmds_ch0_p,     // TMDS 数据通道 0
    output wire       O_tmds_ch1_p,     // TMDS 数据通道 1
    output wire       O_tmds_ch2_p,     // TMDS 数据通道 2
    output wire       O_tmds_clk_p,     // TMDS 时钟通道

    // MIPI CSI-2 D-PHY 差分输入。端口预留 4 Lane，本例只启用 Lane 0、1
    inout wire        IO_rx_clk_pad_n,
    inout wire        IO_rx_clk_pad_p,
    inout wire[3:0]   IO_rx_data_pad_n,
    inout wire[3:0]   IO_rx_data_pad_p,

    // 芯片集成 DDR 的物理接口：用于完整视频帧的循环缓存
    output wire[12:0] ddr_addr,          // 行/列地址
    output wire[ 1:0] ddr_ba,            // Bank 地址
    output wire[ 0:0] ddr_cke,           // 时钟使能
    output wire[ 0:0] ddr_odt,           // 片上终端控制
    output wire[ 0:0] ddr_cs_n,          // 片选，低有效
    output wire       ddr_ras_n,
    output wire       ddr_cas_n,
    output wire       ddr_we_n,
    output wire[ 0:0] ddr_ck_p,          // DDR 差分时钟
    output wire[ 0:0] ddr_ck_n,
    inout wire[1:0]   ddr_dm,            // 数据掩码
    inout wire[15:0]  ddr_dq,            // 16 位双向数据
    inout wire[1:0]   ddr_dqs_p,         // 数据选通信号
    inout wire[1:0]   ddr_dqs_n
);


    // ------------------------------------------------------------------------
    // 时钟与复位
    // ------------------------------------------------------------------------
    wire        	S_100m_clk;
    wire        	S_24m_clk;
	// 以下两个时钟信号在当前版本中未使用，为早期/扩展设计预留
    wire        	S_aux_50m_clk;
	wire        	S_10m_clk;
		
	wire        	S_pll_lock;
    wire        	S_rst_n;

    // ------------------------------------------------------------------------
    // 摄像头 I2C 配置与按键曝光参数
    // ------------------------------------------------------------------------


    wire 			S_cam_cfg_done;
    wire 			S_ae_cfg_done;


    // ------------------------------------------------------------------------
    // MIPI D-PHY 输出与 CSI-2 协议解包信号
    // D-PHY 每拍输出 2 Lane × 1 Byte = 16 bit；CSI 解包后为 32 bit。
    // ------------------------------------------------------------------------
	wire        	S_csi_rx_clk;  
    wire        	S_hs_rx_valid;  
    wire[15:0]  	S_hs_rx_data;   
	wire[1:0]   	S_lane_error;
	
	wire        	S_csi_frame_start;       
	wire        	S_csi_frame_end;         
	wire        	S_csi_valid;             
	wire[31:0]  	S_csi_data;  

    // RAW10 解包器每个有效周期输出 4 个 10 bit Bayer 像素，共 40 bit
	wire        	S_raw10_frame_start; 
	wire        	S_raw10_frame_end;   
	wire        	S_raw10_valid;       
	wire [39:0] 	S_raw10_data;

    // 将原生 RAW10 数据包装成类 AXI4-Stream 视频接口：
    // tuser=帧首，tlast=行末，tvalid=当前数据有效
	wire 			S_axis_tlast;  
	wire 			S_axis_tuser;  
	wire [39:0]		S_axis_tdata;  
	wire 			S_axis_tvalid; 

    // 送入 ISP 的 RAW10 流；当前 720P 模式不裁剪，直接旁路连接
	wire [39:0]		S_raw_tdata ;
	wire			S_raw_tlast ;
	wire 			S_raw_tvalid;
	wire 			S_raw_tuser ;

    // ISP 输出：每拍 128 bit，内部包含多个 RGB 像素及同步标志
	wire			S_ISP_O_tready;
	wire [127:0]	S_ISP_O_tdata ;
	wire 			S_ISP_O_tlast ;
	wire 			S_ISP_O_tuser ;
	wire 			S_ISP_O_tvalid; 
    // ------------------------------------------------------------------------
    // DDR 帧缓存相关时钟、控制和用户侧读写接口
    // video_in 负责写帧，video_out 负责按 HDMI 节奏读帧。
    // ------------------------------------------------------------------------
    wire        S_ddr_clk;
    wire        S_hdmi_pixel_clk;
    wire        S_hdmi_serial_clk;
    wire        S_hdmi_rst_n;
    wire        S_video_out_rst_n;
    // 当前版本未使用的历史中间信号，保留以便与原例程结构对应
    wire        S_vi_128b_frame_start;
    wire        S_vi_128b_valid;      
    wire[127:0] S_vi_128b_data;    
    
    wire        S_video_out_rd_busy;
    wire        S_video_in_wr_busy; 
    wire[1:0]   S_video_out_rp;     // 供显示端读取的帧缓冲区编号

    // 顶层合并后的 DDR 用户接口
    wire        S_ddr_user_wr_en;       
    wire        S_ddr_user_rd_en;       
    wire[24:0]  S_ddr_user_addr;        
    wire[127:0] S_ddr_user_wr_data;     
    wire        S_ddr_user_ready;       
    wire        S_ddr_user_rd_valid;    
    wire[127:0] S_ddr_user_rd_data;     

    // video_in 产生的写请求
    wire        S_vi_ddr_wr_en;
    wire[24:0]  S_vi_ddr_wr_addr; 
    wire[127:0] S_vi_ddr_wr_data;
    wire        S_vi_ddr_wr_ready;

    // video_out 产生的读请求
    wire        S_vo_ddr_rd_en;
    wire[24:0]  S_vo_ddr_rd_addr; 
    wire        S_vo_ddr_rd_ready;
    wire        S_vo_dbg_fifo_rst;
    wire        S_vo_dbg_ddr_rd_valid;
    wire        S_vo_dbg_fifo_rd_en;
    wire        S_vo_dbg_fifo_empty;

    // DDR 用户接口转换为存储控制器原生 app 接口后的信号
    wire        S_init_calib_complete;
    wire[24:0]  S_mc_app_addr;          
    wire[2:0]   S_mc_app_cmd;           
    wire        S_mc_app_en;            
    wire[127:0] S_mc_app_wdf_data;      
    wire        S_mc_app_wdf_end;       
    wire[15:0]  S_mc_app_wdf_mask;      
    wire        S_mc_app_wdf_wren;      
    wire[127:0] S_mc_app_rd_data;       
    wire        S_mc_app_rd_data_end;   
    wire        S_mc_app_rd_data_valid; 
    wire        S_mc_app_rdy;           
    wire        S_mc_app_wdf_rdy;       
    wire        S_mc_dbg_fifo_afull;
    wire        S_mc_dbg_app_rdy;
    wire        S_mc_dbg_wdf_rdy;
    wire        S_mc_dbg_cmd_pop;

    // ------------------------------------------------------------------------
    // 720P 视频时序、像素请求、混合器输出及 HDMI 发送数据
    // ------------------------------------------------------------------------
    wire        S_hdmi_vsync;
    wire        S_hdmi_hsync;
    wire        S_hdmi_de;
    wire        S_hdmi_user;
    wire        S_hdmi_last;
    wire        S_video_out_vsync;
    wire        S_hdmi_window_rd_en;
    wire        S_hdmi_out_vsync;
    wire        S_hdmi_out_hsync;
    wire        S_hdmi_out_de;
    wire[23:0]  S_hdmi_out_data;

    wire[23:0]  S_video_rd_data;        // DDR 读出的单像素 RGB888
    wire [95:0] S_detect_data;
    wire S_detect_valid,S_detect_user,S_detect_last;
    wire [23:0] S_target_rgb;
    wire S_target_de,S_target_hs,S_target_vs;

    // ------------------------------------------------------------------------
    // 上板调试状态寄存器
    // “*_seen”是粘滞标志：对应事件一旦出现便保持为 1，直到系统复位。
    // 事件分别在摄像头、CSI、DDR 等时钟域采集，再同步到 HDMI 像素时钟域，
    // 可供 hdmi_mixer 的 DEBUG_MODE=3 在屏幕上显示链路启动状态。
    // ------------------------------------------------------------------------
    reg         S_dbg_raw_seen;
    reg         S_dbg_isp_seen;
    reg         S_dbg_ddr_wr_seen;
    reg         S_dbg_ddr_rd_seen;
    reg         S_dbg_cam_cfg_seen;
    reg         S_dbg_hs_seen;
    reg         S_dbg_csi_seen;
    reg         S_dbg_raw10_seen;
    reg         S_dbg_isp_fs_seen;
    reg         S_dbg_isp_valid_seen;
    reg         S_dbg_ddr_req_seen;
    reg         S_dbg_ddr_ready_seen;
    reg [1:0]   S_dbg_raw_seen_sync;
    reg [1:0]   S_dbg_isp_seen_sync;
    reg [1:0]   S_dbg_ddr_wr_seen_sync;
    reg [1:0]   S_dbg_ddr_rd_seen_sync;
    reg [1:0]   S_dbg_cam_cfg_seen_sync;
    reg [1:0]   S_dbg_hs_seen_sync;
    reg [1:0]   S_dbg_csi_seen_sync;
    reg [1:0]   S_dbg_raw10_seen_sync;
    reg [1:0]   S_dbg_isp_fs_seen_sync;
    reg [1:0]   S_dbg_isp_valid_seen_sync;
    reg [1:0]   S_dbg_ddr_req_seen_sync;
    reg [1:0]   S_dbg_ddr_ready_seen_sync;
    reg         S_dbg_video_nonzero_seen;
    reg         S_dbg_rd_req_seen;
    reg         S_dbg_rd_valid_seen;
    reg         S_dbg_rd_nonzero_seen;
    reg [1:0]   S_dbg_rd_req_seen_sync;
    reg [1:0]   S_dbg_rd_valid_seen_sync;
    reg [1:0]   S_dbg_rd_nonzero_seen_sync;
    reg         S_dbg_mc_init_seen;
    reg         S_dbg_mc_app_rdy_seen;
    reg         S_dbg_mc_wdf_rdy_seen;
    reg         S_dbg_mc_cmd_pop_seen;
    reg [1:0]   S_dbg_mc_init_seen_sync;
    reg [1:0]   S_dbg_mc_app_rdy_seen_sync;
    reg [1:0]   S_dbg_mc_wdf_rdy_seen_sync;
    reg [1:0]   S_dbg_mc_cmd_pop_seen_sync;
    // 720P 输入格式诊断：1280 个 RAW10 像素占 1600 Byte，等于
    // 400 个有效的 32 bit CSI 数据字；一帧应当包含 720 条这样的有效行。
    reg         S_dbg_hs_valid_d;
    reg [10:0]  S_dbg_csi_words;
    reg [10:0]  S_dbg_good_lines;
    reg         S_dbg_frame_seen_once;
    reg         S_dbg_frame_repeat_seen;
    reg         S_dbg_width_1280_seen;
    reg         S_dbg_height_720_seen;
    reg         S_dbg_isp_frame_seen_once;
    reg         S_dbg_isp_frame_repeat_seen;
    reg [1:0]   S_dbg_frame_repeat_sync;
    reg [1:0]   S_dbg_width_1280_sync;
    reg [1:0]   S_dbg_height_720_sync;
    reg [1:0]   S_dbg_isp_frame_repeat_sync;
    wire[3:0]   S_hdmi_debug_status;
    wire        S_lane_error_any;


    // ------------------------------------------------------------------------
    // 基础输出与复位关系
    // ------------------------------------------------------------------------
    assign O_screen_pwm = 1'b1;             // 背光常亮，不进行亮度 PWM 调节
    assign S_video_out_vsync = ~S_hdmi_vsync; // video_out 所需场同步极性与 VTC 相反
	
	
    // 下级逻辑在 PLL 锁定后才解除复位，防止各时钟尚未稳定便开始工作。
    // 注意：这里没有再与外部 I_rst_n 相与；外部复位通过复位 PLL 间接生效。
    assign S_rst_n 		= S_pll_lock;
    assign S_hdmi_rst_n = S_pll_lock;

    // ------------------------------------------------------------------------
    // 各时钟域事件的粘滞采集。它们只服务于调试，不改变主视频数据。
    // ------------------------------------------------------------------------

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_raw_seen <= 1'b0;
        else if(S_raw10_frame_start | S_axis_tvalid)
            S_dbg_raw_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_seen <= 1'b0;
        else if(S_ISP_O_tuser | S_ISP_O_tvalid)
            S_dbg_isp_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_wr_seen <= 1'b0;
        else if(S_vi_ddr_wr_en)
            S_dbg_ddr_wr_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_rd_seen <= 1'b0;
        else if(S_ddr_user_rd_valid)
            S_dbg_ddr_rd_seen <= 1'b1;
    end

    always @(posedge S_24m_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_cam_cfg_seen <= 1'b0;
        else if(S_cam_cfg_done)
            S_dbg_cam_cfg_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_hs_seen <= 1'b0;
        else if(S_hs_rx_valid)
            S_dbg_hs_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_csi_seen <= 1'b0;
        else if(S_csi_frame_start | S_csi_valid)
            S_dbg_csi_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_raw10_seen <= 1'b0;
        else if(S_raw10_frame_start | S_raw10_valid)
            S_dbg_raw10_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_fs_seen <= 1'b0;
        else if(S_ISP_O_tuser)
            S_dbg_isp_fs_seen <= 1'b1;
    end

    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_isp_valid_seen <= 1'b0;
        else if(S_ISP_O_tvalid)
            S_dbg_isp_valid_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_req_seen <= 1'b0;
        else if(S_vi_ddr_wr_en)
            S_dbg_ddr_req_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_ddr_ready_seen <= 1'b0;
        else if(S_ddr_user_ready)
            S_dbg_ddr_ready_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_req_seen <= 1'b0;
        else if(S_vo_ddr_rd_en)
            S_dbg_rd_req_seen <= 1'b1;
    end

    // 在相邻 HS 高速包边界之间统计 CSI 有效数据字数量。
    // 这样无需探测 csi_unpacket_2lane 的内部网络（ChipWatcher 无法合法连接），
    // 也能从模块外部判断摄像头实际送入的每行宽度是否正确。
    always @(posedge S_csi_rx_clk or negedge S_rst_n) begin
        if(!S_rst_n) begin
            S_dbg_hs_valid_d          <= 1'b0;
            S_dbg_csi_words           <= 11'd0;
            S_dbg_good_lines          <= 11'd0;
            S_dbg_frame_seen_once     <= 1'b0;
            S_dbg_frame_repeat_seen   <= 1'b0;
            S_dbg_width_1280_seen     <= 1'b0;
            S_dbg_height_720_seen     <= 1'b0;
            S_dbg_isp_frame_seen_once <= 1'b0;
            S_dbg_isp_frame_repeat_seen <= 1'b0;
        end
        else begin
            S_dbg_hs_valid_d <= S_hs_rx_valid;

            if(!S_dbg_hs_valid_d && S_hs_rx_valid)
                S_dbg_csi_words <= 11'd0;
            else if(S_csi_valid)
                S_dbg_csi_words <= S_dbg_csi_words + 11'd1;

            // 带有效负载的长包对应一行图像；帧开始/帧结束短包没有像素负载，
            // 因此计数为 0 时不把它当作图像行。
            if(S_dbg_hs_valid_d && !S_hs_rx_valid && (S_dbg_csi_words != 0)) begin
                if(S_dbg_csi_words == 11'd400) begin
                    S_dbg_width_1280_seen <= 1'b1;
                    S_dbg_good_lines <= S_dbg_good_lines + 11'd1;
                end
            end

            if(S_csi_frame_start) begin
                if(S_dbg_frame_seen_once) begin
                    S_dbg_frame_repeat_seen <= 1'b1;
                    if(S_dbg_good_lines == 11'd720)
                        S_dbg_height_720_seen <= 1'b1;
                end
                else
                    S_dbg_frame_seen_once <= 1'b1;
                S_dbg_good_lines <= 11'd0;
            end

            if(S_ISP_O_tuser) begin
                if(S_dbg_isp_frame_seen_once)
                    S_dbg_isp_frame_repeat_seen <= 1'b1;
                else
                    S_dbg_isp_frame_seen_once <= 1'b1;
            end
        end
    end

    always @(posedge S_ddr_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_valid_seen <= 1'b0;
        else if(S_ddr_user_rd_valid)
            S_dbg_rd_valid_seen <= 1'b1;
    end

    always @(posedge S_hdmi_pixel_clk or negedge S_video_out_rst_n) begin
        if(!S_video_out_rst_n)
            S_dbg_rd_nonzero_seen <= 1'b0;
        else if(S_hdmi_window_rd_en && (S_video_rd_data != 24'd0))
            S_dbg_rd_nonzero_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_init_seen <= 1'b0;
        else if(S_init_calib_complete)
            S_dbg_mc_init_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_app_rdy_seen <= 1'b0;
        else if(S_mc_dbg_app_rdy)
            S_dbg_mc_app_rdy_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_wdf_rdy_seen <= 1'b0;
        else if(S_mc_dbg_wdf_rdy)
            S_dbg_mc_wdf_rdy_seen <= 1'b1;
    end

    always @(posedge S_ddr_clk or negedge S_rst_n) begin
        if(!S_rst_n)
            S_dbg_mc_cmd_pop_seen <= 1'b0;
        else if(S_mc_dbg_cmd_pop)
            S_dbg_mc_cmd_pop_seen <= 1'b1;
    end

    // 将来自多个异步时钟域的粘滞状态用两级触发器同步到 HDMI 像素时钟域。
    // 这些标志只会由 0 变 1，因此两级同步足以供低速屏显调试使用。
    always @(posedge S_hdmi_pixel_clk or negedge S_hdmi_rst_n) begin
        if(!S_hdmi_rst_n) begin
            S_dbg_cam_cfg_seen_sync <= 2'b00;
            S_dbg_hs_seen_sync      <= 2'b00;
            S_dbg_csi_seen_sync     <= 2'b00;
            S_dbg_raw10_seen_sync   <= 2'b00;
            S_dbg_raw_seen_sync    <= 2'b00;
            S_dbg_isp_seen_sync    <= 2'b00;
            S_dbg_ddr_wr_seen_sync <= 2'b00;
            S_dbg_ddr_rd_seen_sync <= 2'b00;
            S_dbg_isp_fs_seen_sync  <= 2'b00;
            S_dbg_isp_valid_seen_sync <= 2'b00;
            S_dbg_ddr_req_seen_sync <= 2'b00;
            S_dbg_ddr_ready_seen_sync <= 2'b00;
            S_dbg_video_nonzero_seen <= 1'b0;
            S_dbg_rd_req_seen_sync <= 2'b00;
            S_dbg_rd_valid_seen_sync <= 2'b00;
            S_dbg_rd_nonzero_seen_sync <= 2'b00;
            S_dbg_mc_init_seen_sync <= 2'b00;
            S_dbg_mc_app_rdy_seen_sync <= 2'b00;
            S_dbg_mc_wdf_rdy_seen_sync <= 2'b00;
            S_dbg_mc_cmd_pop_seen_sync <= 2'b00;
            S_dbg_frame_repeat_sync <= 2'b00;
            S_dbg_width_1280_sync <= 2'b00;
            S_dbg_height_720_sync <= 2'b00;
            S_dbg_isp_frame_repeat_sync <= 2'b00;
        end
        else begin
            S_dbg_cam_cfg_seen_sync <= {S_dbg_cam_cfg_seen_sync[0], S_dbg_cam_cfg_seen};
            S_dbg_hs_seen_sync      <= {S_dbg_hs_seen_sync[0],      S_dbg_hs_seen};
            S_dbg_csi_seen_sync     <= {S_dbg_csi_seen_sync[0],     S_dbg_csi_seen};
            S_dbg_raw10_seen_sync   <= {S_dbg_raw10_seen_sync[0],   S_dbg_raw10_seen};
            S_dbg_raw_seen_sync    <= {S_dbg_raw_seen_sync[0],    S_dbg_raw_seen};
            S_dbg_isp_seen_sync    <= {S_dbg_isp_seen_sync[0],    S_dbg_isp_seen};
            S_dbg_ddr_wr_seen_sync <= {S_dbg_ddr_wr_seen_sync[0], S_dbg_ddr_wr_seen};
            S_dbg_ddr_rd_seen_sync <= {S_dbg_ddr_rd_seen_sync[0], S_dbg_ddr_rd_seen};
            S_dbg_isp_fs_seen_sync  <= {S_dbg_isp_fs_seen_sync[0],  S_dbg_isp_fs_seen};
            S_dbg_isp_valid_seen_sync <= {S_dbg_isp_valid_seen_sync[0], S_dbg_isp_valid_seen};
            S_dbg_ddr_req_seen_sync <= {S_dbg_ddr_req_seen_sync[0], S_dbg_ddr_req_seen};
            S_dbg_ddr_ready_seen_sync <= {S_dbg_ddr_ready_seen_sync[0], S_dbg_ddr_ready_seen};
            S_dbg_rd_req_seen_sync <= {S_dbg_rd_req_seen_sync[0], S_dbg_rd_req_seen};
            S_dbg_rd_valid_seen_sync <= {S_dbg_rd_valid_seen_sync[0], S_dbg_rd_valid_seen};
            S_dbg_rd_nonzero_seen_sync <= {S_dbg_rd_nonzero_seen_sync[0], S_dbg_rd_nonzero_seen};
            S_dbg_mc_init_seen_sync <= {S_dbg_mc_init_seen_sync[0], S_dbg_mc_init_seen};
            S_dbg_mc_app_rdy_seen_sync <= {S_dbg_mc_app_rdy_seen_sync[0], S_dbg_mc_app_rdy_seen};
            S_dbg_mc_wdf_rdy_seen_sync <= {S_dbg_mc_wdf_rdy_seen_sync[0], S_dbg_mc_wdf_rdy_seen};
            S_dbg_mc_cmd_pop_seen_sync <= {S_dbg_mc_cmd_pop_seen_sync[0], S_dbg_mc_cmd_pop_seen};
            S_dbg_frame_repeat_sync <= {S_dbg_frame_repeat_sync[0], S_dbg_frame_repeat_seen};
            S_dbg_width_1280_sync <= {S_dbg_width_1280_sync[0], S_dbg_width_1280_seen};
            S_dbg_height_720_sync <= {S_dbg_height_720_sync[0], S_dbg_height_720_seen};
            S_dbg_isp_frame_repeat_sync <= {S_dbg_isp_frame_repeat_sync[0], S_dbg_isp_frame_repeat_seen};
            if(S_hdmi_window_rd_en && (S_video_rd_data != 24'd0))
                S_dbg_video_nonzero_seen <= 1'b1;
        end
    end

    assign S_lane_error_any = |S_lane_error;

    // 下列调试入口在当前顶层未接到下级模块内部探针，固定为 0，
    // 使相关状态逻辑保持确定值；以后重新接入 ChipWatcher 时可替换这些常量。
    assign S_vo_dbg_fifo_rst = 1'b0;
    assign S_vo_dbg_ddr_rd_valid = 1'b0;
    assign S_vo_dbg_fifo_rd_en = 1'b0;
    assign S_vo_dbg_fifo_empty = 1'b0;
    assign S_mc_dbg_fifo_afull = 1'b0;
    assign S_mc_dbg_app_rdy = 1'b0;
    assign S_mc_dbg_wdf_rdy = 1'b0;
    assign S_mc_dbg_cmd_pop = 1'b0;

    // DEBUG_MODE=3 时的屏幕启动状态（从左到右）：
    // 摄像头 I2C 配置完成、检测到 MIPI HS 活动、检测到连续 CSI 帧、
    // 检测到一行 1280 像素的 RAW10 数据（400 个 32 bit CSI 数据字）。
    assign S_hdmi_debug_status = {
        S_dbg_width_1280_sync[1],
        S_dbg_frame_repeat_sync[1],
        S_dbg_hs_seen_sync[1],
        S_dbg_cam_cfg_seen_sync[1]
    };
	
	wire S_cam_i2c_ready;
    wire [15:0] S_cam_sensor_id; // ChipWatcher: expected EE4B or 9E4B
    wire S_cam_sensor_id_ok;
    wire S_cam_iic_error;
    // MCU owns keys and all nine menu items. FPGA executes parameter snapshots.
    // Bits: [0] power-up ready, [1] init sequence done, [2] AE sequence done,
    // [3] sensor ID accepted, [4] sticky I2C error, [5] DDR calibrated,
    // [6] video PLL locked, [7] HDMI reset released.
    wire [7:0] S_blc_offset;
    wire [42:0] S_menu_settings;
    wire S_threshold_owner,S_threshold_sof;
    wire [23:0] S_threshold_selected,S_red_config;
    wire S_candidate_valid,S_candidate_ready,S_candidate_done,S_candidate_done_ready;
    wire [69:0] S_candidate_record;
    wire [15:0] S_candidate_count,S_candidate_total;
    wire [3:0] S_candidate_error;
    wire [31:0] S_candidate_frame,S_result_frame;
    wire S_result_valid,S_result_ready,S_result_done,S_result_done_ready,S_result_alive,S_result_reset_n;
    wire [51:0] S_result_record;
    wire [15:0] S_result_count;
    wire [3:0] S_result_error;
    wire S_hud_clk,S_hud_reset_n,S_hud_submit,S_hud_ready,S_hud_done;
    wire [95:0] S_hud_command;
    wire S_mask_error,F_red_cap_error,F_final_cap_error;
    wire F_ext_write;wire [8:0] F_ext_write_word,F_ext_read_word;
    wire [31:0] F_ext_wdata,F_ext_rdata;
    wire F_red_camera,F_red_replay,F_red_cap_ready,F_red_idle;
    wire [50:0] F_camera_tag,F_red_tag,F_red_active_tag,F_post_tag;
    wire [18:0] F_generation;wire [1:0] F_mode,F_pixel_mode;
    wire F_linear_busy,F_linear_wr,F_linear_ready,F_linear_rd,F_linear_rd_ready,F_linear_rd_valid;
    wire [24:0] F_linear_addr,F_linear_rd_addr;wire [127:0] F_linear_data;
    wire [7:0] F_faults;wire F_show_red,F_show_motion,F_pixel_running;
    wire [127:0] F_motion_boxes;wire [3:0] F_motion_box_valid;
    wire [14:0] F_motion_mask_addr;wire F_motion_mask_data,F_motion_mask_buf,F_motion_mask_enable;
    wire signed [7:0] F_motion_y_offset;
    wire [31:0] F_red_display_frame,F_pixel_ui;
    mcu_bringup u_mcu_bringup(
        .O_ext_write(F_ext_write),.O_ext_write_word(F_ext_write_word),.O_ext_read_word(F_ext_read_word),
        .O_ext_wdata(F_ext_wdata),.I_ext_rdata(F_ext_rdata),
        .I_sys_clk(I_sys_clk),.I_rst_n(I_rst_n),
        .I_ctrl_clk(S_24m_clk),.I_seg_clk(S_ddr_clk),.I_video_rst_n(S_rst_n && S_hdmi_rst_n),
        .I_seg_sof(S_threshold_sof),.I_menu_value({8'd100,8'd65,8'd65}),
        .O_menu_settings(S_menu_settings),.O_threshold_owner(S_threshold_owner),.O_selected(S_threshold_selected),.O_seg_config(S_red_config),
        .I_target_valid(S_candidate_valid),.I_target_done(S_candidate_done),.I_target_record(S_candidate_record),
        .I_target_count(S_candidate_count),.I_target_total(S_candidate_total),.I_target_error(S_candidate_error),.I_target_frame(S_candidate_frame),
        .O_target_ready(S_candidate_ready),.O_target_done_ready(S_candidate_done_ready),
        .O_result_valid(S_result_valid),.O_result_done(S_result_done),.O_result_alive(S_result_alive),
        .O_result_reset_n(S_result_reset_n),
        .O_result_record(S_result_record),.O_result_count(S_result_count),.O_result_error(S_result_error),.O_result_frame(S_result_frame),
        .I_result_ready(S_result_ready),.I_result_done_ready(S_result_done_ready),
        .I_camera_ready(S_cam_i2c_ready),.O_cam_scl(O_cam_scl),.IO_cam_sda(IO_cam_sda),
        .O_cam_cfg_done(S_cam_cfg_done),.O_cam_ae_done(S_ae_cfg_done),.O_cam_id_ok(S_cam_sensor_id_ok),
        .O_cam_error(S_cam_iic_error),.O_cam_id(S_cam_sensor_id),
        .O_hud_clk(S_hud_clk),.O_hud_reset_n(S_hud_reset_n),.O_hud_submit(S_hud_submit),
        .O_hud_command(S_hud_command),.I_hud_ready(S_hud_ready),.I_hud_done(S_hud_done),
        .O_servo_pan(O_servo_pan),.O_servo_tilt(O_servo_tilt),
        .I_uart0_rx(I_uart0_rx),.O_uart0_tx(O_uart0_tx),.I_button(I_button),
        .I_hw_status({S_hdmi_rst_n,S_pll_lock,S_init_calib_complete,S_cam_iic_error,
                      S_cam_sensor_id_ok,S_ae_cfg_done,S_cam_cfg_done,S_cam_i2c_ready}));
    wire [3:0] S_gamma_level,S_selected_item;
    wire S_blc_enable;
    wire [1:0] S_sf_mode;
    assign S_selected_item=S_menu_settings[42:39];
    assign {S_gamma_level,S_blc_enable,S_blc_offset,S_sf_mode}=S_menu_settings[38:24];
    // Coherent menu snapshot: {RED Gamma, shared RAW BL/BO, legacy SF field}.
    // final1_raw_front latches BL/BO at original RAW SOF; SF remains mode-owned.
    wire [14:0] S_filter_config;
    reg [14:0] S_filter_active;
    wire [14:0] S_filter_frame=S_raw_tuser ? S_filter_config : S_filter_active;
    view_mode_cdc #(.BITS(15),.RESET_VALUE({4'd6,1'b1,8'd32,2'd3})) u_filter_config(
        .src_clk(S_24m_clk),.dst_clk(S_csi_rx_clk),.reset_n(S_rst_n),
        .value({S_gamma_level,S_blc_enable,S_blc_offset,S_sf_mode}),.received(S_filter_config));
    always @(posedge S_csi_rx_clk or negedge S_rst_n)
        if(!S_rst_n) S_filter_active<={4'd6,1'b1,8'd32,2'd3};
        else if(S_raw_tuser) S_filter_active<=S_filter_config;
    wire [1:0] S_write_mode=F_mode;
    wire [1:0] S_frame_mode,S_read_bank;
    wire [2:0] S_read_metadata,S_display_metadata;
    wire S_frame_valid,S_frame_ready,S_write_ready,S_write_start,S_write_valid,S_write_abort;
    wire [127:0] S_write_data;
    // Private completed RGB capture ring: 28,000,000 .. 33,529,599.
    // Old display bases and reader protection remain unchanged.
    wire S_cap_busy,S_cap_wr,S_cap_ready,S_cap_valid;
    wire [24:0] S_cap_addr;
    wire [127:0] S_cap_data;
    wire [1:0] S_cap_bank,S_cap_lock;
    wire [31:0] S_cap_sequence;
    wire S_view_bus_ready,S_display_bus_ready,S_display_rd_valid;
    wire S_tf_rd,S_tf_wr,S_tf_bus_ready,S_tf_rd_valid,S_tf_error,S_tf_arb_error;
    wire [24:0] S_tf_addr;
    wire [127:0] S_tf_wr_data,S_tf_data;
    wire S_tf_valid,S_tf_start,S_tf_color_ready,S_unpack_ready,S_view_idle,S_detector_frame_ready;
    wire [95:0] S_tf_rgb;
    wire [95:0] S_shared_rgb_data;
    wire        S_shared_rgb_valid;
    wire        S_shared_rgb_user;
    wire        S_shared_rgb_last;
    wire S_tf_rgb_valid,S_tf_rgb_user,S_tf_rgb_last;
    assign S_tf_color_ready=1'b1;
    assign S_write_abort=1'b0;
    assign S_view_idle=F_red_idle;
    final1_runtime u_final1(
        .camera_clk(S_csi_rx_clk),.ddr_clk(S_ddr_clk),.ahb_clk(S_hud_clk),.pixel_clk(S_hdmi_pixel_clk),.rst_n(S_rst_n && S_hud_reset_n),
        .raw_data(S_raw_tdata),.raw_valid(S_raw_tvalid),.raw_user(S_raw_tuser),.raw_last(S_raw_tlast),
        .blc_enable(S_filter_config[10]),.blc_offset(S_filter_config[9:2]),
        .ext_write(F_ext_write),.ext_write_word(F_ext_write_word),.ext_read_word(F_ext_read_word),.ext_wdata(F_ext_wdata),.ext_rdata(F_ext_rdata),
        .red_capture_ready(F_red_cap_ready),.red_replay_idle(F_red_idle),.red_detector_ready(S_detector_frame_ready),
        .red_camera_enable(F_red_camera),.red_replay_enable(F_red_replay),.camera_tag(F_camera_tag),.generation(F_generation),.active_mode(F_mode),
        .final_frame_ready(S_frame_ready),.post_start(S_write_start),.post_data(S_write_data),.post_valid(S_write_valid),.post_tag(F_post_tag),
        .linear_busy(F_linear_busy),.linear_wr(F_linear_wr),.linear_addr(F_linear_addr),.linear_data(F_linear_data),.linear_ready(F_linear_ready),
        .linear_rd(F_linear_rd),.linear_rd_addr(F_linear_rd_addr),.linear_rd_ready(F_linear_rd_ready),.linear_rd_valid(F_linear_rd_valid),.rd_data(S_ddr_user_rd_data),
        .external_faults({(F_final_cap_error || F_red_cap_error),S_mask_error,S_tf_error,S_tf_arb_error,4'd0}),.faults(F_faults),
        .pixel_vs(S_target_vs),.red_display_frame(F_red_display_frame),.show_red(F_show_red),.show_motion(F_show_motion),
        .motion_boxes(F_motion_boxes),.motion_box_valid(F_motion_box_valid),.pixel_mode(F_pixel_mode),.pixel_running(F_pixel_running),.pixel_ui(F_pixel_ui),
        .motion_mask_rd_addr(F_motion_mask_addr),.motion_mask_rd_data(F_motion_mask_data),
        .motion_mask_wr_buf(F_motion_mask_buf),.motion_mask_enable(F_motion_mask_enable),.motion_y_offset(F_motion_y_offset),
        .shared_rgb_data(S_shared_rgb_data),.shared_rgb_valid(S_shared_rgb_valid),.shared_rgb_user(S_shared_rgb_user),.shared_rgb_last(S_shared_rgb_last));

    video_in #(.BASE0(28000000),.BASE1(29382400),.BASE2(30764800),.BASE3(32147200)) u_color_capture(
        .I_rst_n(S_rst_n),.I_camera_clk(S_csi_rx_clk),.I_camera_frame_start(S_ISP_O_tuser && F_red_camera),
        .I_camera_valid(S_ISP_O_tvalid),.I_camera_data(S_ISP_O_tdata),.I_camera_mode(2'd0),
        .I_frame_tag(F_camera_tag),.I_diagnostics(92'd0),
        .O_frame_tag(F_red_tag),.O_diagnostics(),.O_frame_sequence(S_cap_sequence),
        .I_camera_abort(S_raw_tuser && !F_red_camera),.I_mipi_rx_error(1'b0),.I_ddr_clk(S_ddr_clk),
        .I_display_pause(1'b0),.I_video_out_rd_busy(1'b0),.I_read_bank(S_cap_lock),
        .O_camera_ready(),.O_frame_ready(F_red_cap_ready),.O_capture_error(F_red_cap_error),.O_video_in_wr_busy(S_cap_busy),
        .O_video_out_rp(S_cap_bank),.O_frame_mode(),.O_frame_valid(S_cap_valid),
        .O_ddr_user_wr_en(S_cap_wr),.O_ddr_user_addr(S_cap_addr),.O_ddr_user_wr_data(S_cap_data),
        .I_ddr_user_ready(S_cap_ready));
    rgb_frame_replay u_tf(.clk(S_ddr_clk),.rst_n(S_rst_n),
        .frame_valid(S_cap_valid && F_red_tag[50:32]==F_generation),.frame_sequence(S_cap_sequence),.frame_bank(S_cap_bank),
        .frame_tag(F_red_tag),.frame_diagnostics(92'd0),.locked_bank(S_cap_lock),
        .start_ready(F_red_replay && S_detector_frame_ready && S_unpack_ready),
        .idle(F_red_idle),.active_tag(F_red_active_tag),
        .frame_start(S_tf_start),.active_diagnostics(),
        .m_data(S_tf_data),.m_valid(S_tf_valid),.m_ready(S_tf_color_ready && S_unpack_ready),
        .rd_en(S_tf_rd),.wr_en(S_tf_wr),.address(S_tf_addr),.wr_data(S_tf_wr_data),
        .bus_ready(S_tf_bus_ready),.rd_valid(S_tf_rd_valid),.rd_data(S_ddr_user_rd_data),
        .error(S_tf_error),.completed());
    rgb_unpack96 u_tf_unpack(.clk(S_ddr_clk),.rst_n(S_rst_n),
        .s_data(S_tf_data),.s_valid(S_tf_valid && S_tf_color_ready),.s_ready(S_unpack_ready),
        .m_data(S_tf_rgb),.m_valid(S_tf_rgb_valid),.m_user(S_tf_rgb_user),.m_last(S_tf_rgb_last));
    sc520_powerup u_cam_powerup (
        .I_clk(S_24m_clk), .I_pll_locked(S_pll_lock),
        .O_pwdnb(O_cam_rst), .O_i2c_ready(S_cam_i2c_ready)
    );
    // Fixed-rate camera/legacy ISP sink; no end-to-end DDR backpressure.
    assign S_ISP_O_tready = 1'b1;
    assign O_cam_24m 	= S_24m_clk; // 向摄像头提供约 23.809524 MHz MCLK
	
	
	
	
    // ------------------------------------------------------------------------
    // 时钟生成
    // 由板级系统时钟生成 D-PHY 低速控制时钟、摄像头 MCLK、HDMI 像素时钟
    // 和 HDMI 串行时钟。DDR 控制器的用户时钟由其自身模块输出。
    // ------------------------------------------------------------------------
    PLL u_PLL(
        .refclk      ( I_sys_clk         ),
        .reset    	 ( ~I_rst_n          ),
        
        .clk0_out    ( S_100m_clk        ),
        .clk1_out    ( S_24m_clk         ),

        .clk4_out    ( S_hdmi_pixel_clk  ),
        .clk5_out    ( S_hdmi_serial_clk ),

        .lock        ( S_pll_lock        )

    );


	

  
    // ------------------------------------------------------------------------
    // v5: the MCU service owns sensor initialization and grouped AE/AG writes.
    // Power-up timing and the pin-level I2C engine remain in FPGA.
	
	
    // ------------------------------------------------------------------------
    // MIPI D-PHY 接收
    // 本例启用 DPHY0、2 条数据 Lane、每 Lane 每拍 1 Byte，合并为 16 bit。
    // 该硬核完成差分电气接收和字节对齐，尚未解析 CSI-2 包结构。
    // ------------------------------------------------------------------------
    mipi_dphy_rx_ph1p_mipiio_wrapper#(
        .DPHY_RX_LOCATION      ( "DPHY0" ),
        .HS_EQUALIZER          ( "3dB"   ),//"0dB","1.5dB","3dB","4.5dB","6dB","7.5dB","9dB","10.5dB"
        .HS_VGA_GAIN           ( "8dB" ),//"-3dB","-1.5dB","0dB","1.5dB","3dB","4.5dB","6dB","7.5dB"
        .LANE_NUM              ( 2       ),
        .BYTE_NUM              ( 1       )
    )u_mipi_dphy_rx_ph1p_mipiio_wrapper(
        .I_lp_clk              ( S_100m_clk       ),
        .I_rst                 ( ~S_rst_n         ),

        .I_clk_lane_in_delay   ( 6'd0             ),
        .I_data_lane0_in_delay ( 6'd0             ),
        .I_data_lane1_in_delay ( 6'd0             ),
        .I_data_lane2_in_delay ( 6'd0             ),
        .I_data_lane3_in_delay ( 6'd0             ),

        .I_lane_invert         ( 4'b0000          ),
     
        .O_hs_rx_clk           ( S_csi_rx_clk     ),
        .O_hs_rx_valid         ( S_hs_rx_valid    ),
        .O_hs_rx_data          ( S_hs_rx_data     ),
      
        .O_lp_rx_lane0_p       (  ),
        .O_lp_rx_lane0_n       (  ),
      
        .I_lp_tx_en            ( 1'b0             ),
        .I_lp_tx_lane0_p       ( 1'b1             ),
        .I_lp_tx_lane0_n       ( 1'b1             ),
      
        .O_lane_match_error    (                  ),
        .O_lane_error          ( S_lane_error     ),
      
        .IO_rx_clk_pad_n       ( IO_rx_clk_pad_n  ),
        .IO_rx_clk_pad_p       ( IO_rx_clk_pad_p  ),
        .IO_rx_data_pad_n      ( IO_rx_data_pad_n ),
        .IO_rx_data_pad_p      ( IO_rx_data_pad_p )
    );
	
	
 // 可选的 ChipWatcher 在线逻辑分析探针；默认注释，不参与综合。
 //  cwc cwc_inst
 //(
 //    .probe0(S_hs_rx_valid),
 //    .probe1(S_hs_rx_data),
 //    .probe2(S_lane_error),
 //    .clk(S_csi_rx_clk)
 //);

// ---------------------------------------------------------------------------
// MIPI CSI-2 协议与 RAW10 像素解包
// ---------------------------------------------------------------------------
// 解析 CSI-2 长包/短包，去除包头、ECC、CRC 等协议字段，输出 32 bit 负载，
// 同时恢复帧开始、帧结束和数据有效标志。
csi_unpacket_2lane u_csi_unpacket(
.I_clk                 ( S_csi_rx_clk       ),
.I_rst_n               ( S_rst_n        	),
.I_hs_valid            ( S_hs_rx_valid     ),
.I_hs_data             ( S_hs_rx_data      ),

.O_csi_frame_start     ( S_csi_frame_start ),
.O_csi_frame_end       ( S_csi_frame_end   ),
.O_csi_valid           ( S_csi_valid       ),
.O_csi_data            ( S_csi_data        )
);


// 按 MIPI RAW10 打包规则，把 32 bit CSI 负载重新组合成 4×10 bit Bayer 像素。
// 原注释中的“RAW8”不准确：本模块实际输出 40 bit RAW10 数据。
raw10_unpacket_2lane u_raw10_unpacket (
.I_clk  (S_csi_rx_clk),
.I_rst_n(S_rst_n),

.I_csi_frame_start(S_csi_frame_start),
.I_csi_frame_end  (S_csi_frame_end),
.I_csi_valid      (S_csi_valid),
.I_csi_data       (S_csi_data),

.O_raw10_frame_start(S_raw10_frame_start),
.O_raw10_frame_end  (S_raw10_frame_end),
.O_raw10_valid      (S_raw10_valid),
.O_raw10_data       (S_raw10_data)
  );


// 将原生帧/行控制信号转换为类 AXI4-Stream 视频流。
// 1280×720 参数用于产生每行末尾 tlast 和每帧开头 tuser。
uial2axis #(
.IMG_WIDTH(1280),
.IMG_HEIGHT(720),
.INPUT_DATA_WIDTH(40)
) 
u_uial2axis (
.I_native_clk(S_csi_rx_clk),
.I_rst_n     (S_rst_n),
.I_data      (S_raw10_data       ),
.I_data_valid(S_raw10_valid      ),
.I_data_start(S_raw10_frame_start),
.I_data_end  (S_raw10_frame_end  ),
.axis_tvalid (S_axis_tvalid),
.axis_tdata  (S_axis_tdata ),
.axis_tuser  (S_axis_tuser ),
.axis_tlast  (S_axis_tlast )
);
	

// SC520CS 的当前 HD 配置已经直接输出 1280×720 RAW10，无需再做裁剪，
// 因此把 AXI4-Stream 信号原样旁路到 ISP 输入。这里也是后续插入自定义
// RAW 域算法（坏点校正、黑电平校正等）的一个自然位置。
assign S_raw_tdata  = S_axis_tdata;
assign S_raw_tvalid = S_axis_tvalid;
assign S_raw_tlast  = S_axis_tlast;
assign S_raw_tuser  = S_axis_tuser;


// 可选的 ISP 前后数据 ChipWatcher 探针；默认不参与综合。
//cwc1 cwc1_Inst
//  (
//      .probe0(S_axis_tuser),
//      .probe1(S_axis_tvalid),
//      .probe2(S_axis_tlast),
//      .probe3(S_axis_tdata),
//      .probe4(S_ISP_O_tuser),
//      .probe5(S_ISP_O_tvalid),
//      .probe6(S_ISP_O_tlast),
//      .probe7(S_ISP_O_tdata),
//      .probe8 (S_raw_tdata ),
//      .probe9 (S_raw_tlast ),
//      .probe10(S_raw_tvalid),
//      .probe11(S_raw_tuser ),
//      .clk(S_csi_rx_clk)
//  );


// ---------------------------------------------------------------------------
// ISP 图像处理
// isp_top 接收共享去马赛克 RGB，只完成 RED 固定白平衡、R-only Gamma 和打包。
// GMR 影响红色检测输入；公共显示走 final1_post 的独立 Gamma。
// BL/BO 已在共享 RAW 前端帧首锁存，RED/MOTION/STYLE 均使用该 BLC 结果。
// ---------------------------------------------------------------------------
isp_top u_isp_top (
    .axi4s_video_aclk   (S_csi_rx_clk),
    .I_rst_n            (S_rst_n),
    .I_gamma_level      (S_filter_active[14:11]),
    .I_color_config     ({S_filter_frame[10:2],2'd1}),
    .O_diagnostics      (),
    .I_rgb_data         (S_shared_rgb_data),
    .I_rgb_valid        (S_shared_rgb_valid),
    .I_rgb_user         (S_shared_rgb_user),
    .I_rgb_last         (S_shared_rgb_last),
    .O_tready           (S_ISP_O_tready),
    .O_tdata            (S_ISP_O_tdata ),
    .O_tlast            (S_ISP_O_tlast ),
    .O_tuser            (S_ISP_O_tuser ),
    .O_tvalid           (S_ISP_O_tvalid),
    .I_tready           (),
    .O_detect_data      (S_detect_data),
    .O_detect_valid     (S_detect_valid),
    .O_detect_user      (S_detect_user),
    .O_detect_last      (S_detect_last)
  );


    // ------------------------------------------------------------------------
    // 摄像头流写入 DDR 帧缓存
    // VIEW 选择后的整帧经异步 FIFO 写入 DDR。只发布完整写入的帧，并避开
    // 当前 HDMI 读取银行和最近发布银行；检测掩膜可反压，固定节奏 ISP 不停顿。
    // 正常彩色输入若溢出/截断则丢弃该帧，显示保留上一幅完整图像。
    // ------------------------------------------------------------------------
    wire [50:0] F_final_tag;
    video_in #(.ELASTIC(0)) u_video_in(
        .I_frame_tag(F_post_tag),.I_diagnostics(92'd0),.O_frame_tag(F_final_tag),.O_diagnostics(),.O_frame_sequence(),
        .I_camera_mode(S_write_mode),.I_camera_abort(S_write_abort),.I_read_bank(S_read_bank),
        .O_camera_ready(S_write_ready),.O_frame_ready(S_frame_ready),.O_capture_error(F_final_cap_error),
        .O_frame_mode(S_frame_mode),.O_frame_valid(S_frame_valid),
        .I_rst_n              (  S_rst_n             ),

        .I_camera_clk         ( S_ddr_clk          ),
        .I_camera_frame_start ( S_write_start  ),
        .I_camera_valid       ( S_write_valid ),
        .I_camera_data        ( S_write_data  ),
        .I_mipi_rx_error      ( 1'b0			      ),

        .I_ddr_clk            ( S_ddr_clk             ),
		.I_display_pause      ( 1'b0                  ),
        .I_video_out_rd_busy  ( 1'b0 ),
        .O_video_in_wr_busy   ( S_video_in_wr_busy    ),
        .O_video_out_rp       ( S_video_out_rp        ),

        .O_ddr_user_wr_en     ( S_vi_ddr_wr_en        ),
        .O_ddr_user_addr      ( S_vi_ddr_wr_addr      ),
        .O_ddr_user_wr_data   ( S_vi_ddr_wr_data      ),
        .I_ddr_user_ready     ( S_view_bus_ready )
    );
    // ------------------------------------------------------------------------
    // DDR 用户端口仲裁
    // 写请求优先于读请求；video_in/video_out 的 busy 握手用于避免二者同时
    // 占用单一 DDR 用户接口。地址单位由下级 DDR 接口定义，不能按 Byte 直读。
    // ------------------------------------------------------------------------
    // Reserved mask slot: controller halfword addresses [0x200000,0x210000).
    wire S_mask_request,S_mask_wr,S_mask_rd,S_mask_ready,S_mask_valid;
    wire [24:0] S_mask_addr;
    wire [127:0] S_mask_data;
    wire S_mask_write_retired=S_mc_app_en && S_mc_app_rdy && S_mc_app_wdf_wren &&
        S_mc_app_wdf_rdy && S_mc_app_cmd==3'd0 && S_mc_app_addr[24:16]==9'h020;
    final1_ddr_arbiter u_tf_arbiter(.clk(S_ddr_clk),.rst_n(S_rst_n),
        .linear_busy(F_linear_busy),.linear_wr(F_linear_wr),.linear_addr(F_linear_addr),.linear_data(F_linear_data),.linear_ready(F_linear_ready),
        .linear_rd(F_linear_rd),.linear_rd_addr(F_linear_rd_addr),.linear_rd_ready(F_linear_rd_ready),.linear_rd_valid(F_linear_rd_valid),.outstanding(),
        .cap_busy(S_cap_busy),.cap_wr(S_cap_wr),.cap_addr(S_cap_addr),.cap_data(S_cap_data),.cap_ready(S_cap_ready),
        .view_busy(S_video_in_wr_busy),.view_wr(S_vi_ddr_wr_en),.view_addr(S_vi_ddr_wr_addr),
        .view_data(S_vi_ddr_wr_data),.view_ready(S_view_bus_ready),
        .display_busy(S_video_out_rd_busy),.display_rd(S_vo_ddr_rd_en),.display_addr(S_vo_ddr_rd_addr),
        .display_ready(S_display_bus_ready),.display_valid(S_display_rd_valid),
        .tf_rd(S_tf_rd),.tf_wr(S_tf_wr),.tf_addr(S_tf_addr),.tf_data(S_tf_wr_data),
        .tf_ready(S_tf_bus_ready),.tf_valid(S_tf_rd_valid),
        .mask_request(S_mask_request),.mask_wr(S_mask_wr),.mask_rd(S_mask_rd),
        .mask_addr(S_mask_addr),.mask_data(S_mask_data),.mask_ready(S_mask_ready),.mask_valid(S_mask_valid),
        .ready(S_ddr_user_ready),.rd_valid(S_ddr_user_rd_valid),
        .wr_en(S_ddr_user_wr_en),.rd_en(S_ddr_user_rd_en),.address(S_ddr_user_addr),
        .wr_data(S_ddr_user_wr_data),.error(S_tf_arb_error));

    assign S_video_out_rst_n = S_hdmi_rst_n;

    // ------------------------------------------------------------------------
    // DDR 帧缓存读取
    // video_out 根据 VTC 场同步和 hdmi_mixer 的像素请求，从选定的完整帧缓存
    // 读出 128 bit 数据，并转换成逐像素 24 bit RGB888；内部异步 FIFO 完成
    // DDR 时钟域到 HDMI 像素时钟域的跨域。
    // ------------------------------------------------------------------------
    wire [31:0] F_display_source_id;
    wire F_display_good;
    wire F_latency_reset_n=S_rst_n && S_hud_reset_n && S_hdmi_rst_n;
    wire F_latency_published,F_latency_display_armed;
    video_out #(.FRAME_ID_ENABLE(1)) u_video_out(
        .I_frame_id_valid(F_latency_published),
        .I_frame_id(F_final_tag[31:0]),.O_display_frame_id(F_display_source_id),.O_display_good(F_display_good),
        .I_frame_mode(S_frame_mode),.I_frame_valid(S_frame_valid),.O_read_bank(S_read_bank),
        .O_read_metadata(S_read_metadata),.O_display_metadata(S_display_metadata),
        .I_rst_n             ( S_video_out_rst_n    ),
        .I_ddr_clk           ( S_ddr_clk            ),
 
        .O_video_out_rd_busy ( S_video_out_rd_busy  ),
        .I_video_in_wr_busy  ( 1'b0 ),
        .I_video_out_rp      ( S_video_out_rp       ),
 
        .O_ddr_user_rd_en    ( S_vo_ddr_rd_en       ),
        .O_ddr_user_addr     ( S_vo_ddr_rd_addr     ),
        .I_ddr_user_ready    ( S_display_bus_ready ),
        .I_ddr_user_rd_valid ( S_display_rd_valid ),
        .I_ddr_user_rd_data  ( S_ddr_user_rd_data   ),

        .I_dsi_clk           ( S_hdmi_pixel_clk     ),
        .I_video_vsync       ( S_video_out_vsync    ),
        .I_video_rd_en       ( S_hdmi_window_rd_en  ),
        .O_vdieo_data        ( S_video_rd_data      )
    );
    // ------------------------------------------------------------------------
    // DDR 用户接口适配
    // 把上层较简单的读写使能/地址/数据，转换为 DDR 控制器的命令通道、
    // 写数据通道和读返回通道握手信号。
    // ------------------------------------------------------------------------
    mc_to_user_interface u_mc_to_user_interface(
        .I_clk                   ( S_ddr_clk               ),
        .I_rst_n                 ( S_rst_n                 ),

        .I_ddr_user_wr_en        ( S_ddr_user_wr_en        ),
        .I_ddr_user_rd_en        ( S_ddr_user_rd_en        ),
        .I_ddr_user_addr         ( S_ddr_user_addr         ),
        .I_ddr_user_wr_data      ( S_ddr_user_wr_data      ),
        .O_ddr_user_ready        ( S_ddr_user_ready        ),
        .O_ddr_user_rd_valid     ( S_ddr_user_rd_valid     ),
        .O_ddr_user_rd_data      ( S_ddr_user_rd_data      ),
            
        .O_mc_app_en             ( S_mc_app_en             ),
        .O_mc_app_addr           ( S_mc_app_addr           ),
        .O_mc_app_cmd            ( S_mc_app_cmd            ),
        .I_mc_app_rdy            ( S_mc_app_rdy            ),
        .O_mc_app_wdf_wren       ( S_mc_app_wdf_wren       ),
        .O_mc_app_wdf_data       ( S_mc_app_wdf_data       ),
        .O_mc_app_wdf_end        ( S_mc_app_wdf_end        ),
        .O_mc_app_wdf_mask       ( S_mc_app_wdf_mask       ),
        .I_mc_app_wdf_rdy        ( S_mc_app_wdf_rdy        ),
        .I_mc_app_rd_data        ( S_mc_app_rd_data        ),
        .I_mc_app_rd_data_end    ( S_mc_app_rd_data_end    ),
        .I_mc_app_rd_data_valid  ( S_mc_app_rd_data_valid  )
    );
    // ------------------------------------------------------------------------
    // PH1P35 集成 DDR 控制器及物理层
    // 负责 DDR 初始化、校准和实际存储访问，并导出全部 DDR 封装引脚。
    // ------------------------------------------------------------------------
    ph1p35_324_ddr_wrapper u_ph1p35_324_ddr_wrapper(
        .I_sys_clk              ( I_sys_clk              ),
        .I_sys_rst_n            ( S_rst_n                ),

        .O_ddr_clk              ( S_ddr_clk              ),
        .O_init_calib_complete  ( S_init_calib_complete  ),
        .I_mc_app_addr          ( S_mc_app_addr          ),
        .I_mc_app_cmd           ( S_mc_app_cmd           ),
        .I_mc_app_en            ( S_mc_app_en            ),
        .I_mc_app_wdf_data      ( S_mc_app_wdf_data      ),
        .I_mc_app_wdf_end       ( S_mc_app_wdf_end       ),
        .I_mc_app_wdf_mask      ( S_mc_app_wdf_mask      ),
        .I_mc_app_wdf_wren      ( S_mc_app_wdf_wren      ),
        .O_mc_app_rd_data       ( S_mc_app_rd_data       ),
        .O_mc_app_rd_data_end   ( S_mc_app_rd_data_end   ),
        .O_mc_app_rd_data_valid ( S_mc_app_rd_data_valid ),
        .O_mc_app_rdy           ( S_mc_app_rdy           ),
        .O_mc_app_wdf_rdy       ( S_mc_app_wdf_rdy       ),

        .ddr_addr               ( ddr_addr               ),
        .ddr_ba                 ( ddr_ba                 ),
        .ddr_cke                ( ddr_cke                ),
        .ddr_odt                ( ddr_odt                ),
        .ddr_cs_n               ( ddr_cs_n               ),
        .ddr_ras_n              ( ddr_ras_n              ),
        .ddr_cas_n              ( ddr_cas_n              ),
        .ddr_we_n               ( ddr_we_n               ),
        .ddr_ck_p               ( ddr_ck_p               ),
        .ddr_ck_n               ( ddr_ck_n               ),
        .ddr_dm                 ( ddr_dm                 ),
        .ddr_dq                 ( ddr_dq                 ),
        .ddr_dqs_p              ( ddr_dqs_p              ),
        .ddr_dqs_n              ( ddr_dqs_n              )
    );
    // ------------------------------------------------------------------------
    // 1280×720 HDMI 显示时序
    // 水平总周期 1650、有效 1280；垂直总周期 750、有效 720，构成 720P 时序。
    // VTC 只生成同步/消隐/有效区坐标，不保存或处理像素。
    // ------------------------------------------------------------------------
    uivtc #(
        .H_ActiveSize ( 1280 ),
        .H_FrameSize  ( 1650 ),
        .H_SyncStart  ( 1390 ),
        .H_SyncEnd    ( 1430 ),
        .V_ActiveSize ( 720  ),
        .V_FrameSize  ( 750  ),
        .V_SyncStart  ( 725  ),
        .V_SyncEnd    ( 730  )
    )u_hdmi_vtc(
        .I_vtc_rstn    ( S_hdmi_rst_n    ),
        .I_vtc_clk     ( S_hdmi_pixel_clk ),
        .O_vtc_vs      ( S_hdmi_vsync     ),
        .O_vtc_hs      ( S_hdmi_hsync     ),
        .O_vtc_de_valid( S_hdmi_de        ),
        .O_vtc_user    ( S_hdmi_user      ),
        .O_vtc_last    ( S_hdmi_last      )
    );

    // ------------------------------------------------------------------------
    // 彩色画面流水
    // 在有效显示窗口内向video_out请求DDR中的FINAL彩色像素，并将RGB数据、
    // VTC同步信号与RGB保持原三级延迟。DEBUG_MODE=0直接透传彩色画面，
    // 此处无Logo及CNT；最终参数OSD叠加紧凑安路Logo，不改写DDR内容。
    // ------------------------------------------------------------------------
    hdmi_mixer #(
        .H_OFFSET   ( 0    ),
        .V_OFFSET   ( 0    ),
        .IMG_WIDTH  ( 1280 ),
        .IMG_HEIGHT ( 720  ),
        .DEBUG_MODE ( 0    ) // 正常透传彩色视频
    )u_hdmi_mixer(
        .I_clk           ( S_hdmi_pixel_clk   ),
        .I_rst_n         ( S_hdmi_rst_n       ),
        .I_video_vsync   ( S_hdmi_vsync       ),
        .I_video_hsync   ( S_hdmi_hsync       ),
        .I_video_de      ( S_hdmi_de          ),
        .I_video_user    ( S_hdmi_user        ),
        .I_video_last    ( S_hdmi_last        ),
        .I_overlay_enable(S_display_metadata[2] && S_display_metadata[1:0]==0),
        .I_debug_status  ( S_hdmi_debug_status),
        .O_video_rd_en   ( S_hdmi_window_rd_en),
        .I_video_rd_data ( S_display_metadata[2] ? S_video_rd_data : 24'd0 ),
        .O_hdmi_vsync    ( S_hdmi_out_vsync   ),
        .O_hdmi_hsync    ( S_hdmi_out_hsync   ),
        .O_hdmi_de       ( S_hdmi_out_de      ),
        .O_hdmi_data     ( S_hdmi_out_data    )
    );

    // ------------------------------------------------------------------------
    // HDMI 1.4 发送
    // 将 24 bit RGB 和同步信号编码、并串转换为 3 路 TMDS 数据及 1 路时钟。
    // 本例关闭音频、I2S、EDID/DDC 读取以及额外的流式视频握手接口。
    // ------------------------------------------------------------------------
    red_target_video #(.MIN_AREA(2500),.MCU_POSTPROCESS(1),.MASK_DDR(1),.EXTERNAL_FRAME_ID(1)) u_red_targets(.threshold_sof(S_threshold_sof),
        .mask_reset_n(S_rst_n),.mask_bus_ready(S_mask_ready),.mask_rd_valid(S_mask_valid),
        .mask_write_retired(S_mask_write_retired),.mask_rd_data(S_ddr_user_rd_data),
        .mask_request(S_mask_request),.mask_wr(S_mask_wr),.mask_rd(S_mask_rd),
        .mask_addr(S_mask_addr),.mask_wr_data(S_mask_data),.mask_protocol_error(S_mask_error),
        .candidate_valid(S_candidate_valid),.candidate_done(S_candidate_done),.candidate_record(S_candidate_record),
        .candidate_count(S_candidate_count),.candidate_total(S_candidate_total),.candidate_error(S_candidate_error),.candidate_frame(S_candidate_frame),
        .candidate_ready(S_candidate_ready),.candidate_done_ready(S_candidate_done_ready),
        .result_valid(S_result_valid),.result_done(S_result_done),.result_alive(S_result_alive),
        .result_reset_n(S_result_reset_n),
        .result_record(S_result_record),.result_count(S_result_count),.result_error(S_result_error),.result_frame(S_result_frame),
        .result_ready(S_result_ready),.result_done_ready(S_result_done_ready),
        .red_rmin(S_red_config[23:16]),.red_rgap(S_red_config[15:8]),.red_bgap(S_red_config[7:0]),
        .source_frame_id(F_red_active_tag[31:0]),
        .show_targets(F_show_red && S_display_metadata[2] && S_display_metadata[1:0]==0),
        .debug_raw_data(),.debug_raw_valid(),.debug_raw_user(),.debug_raw_ready(1'b1),
        .debug_erode_data(),.debug_erode_valid(),.debug_erode_user(),.debug_erode_ready(1'b1),
        .debug_clean_data(),.debug_clean_valid(),.debug_clean_user(),.debug_clean_ready(1'b1),
        .input_frame_ready(S_detector_frame_ready),.detector_clk(S_ddr_clk),.pixel_clk(S_hdmi_pixel_clk),.reset_n(S_rst_n && S_hdmi_rst_n),
        .awb_data(S_tf_rgb),.awb_valid(S_tf_rgb_valid),.awb_user(S_tf_rgb_user),.awb_last(S_tf_rgb_last),
        .video_rgb(S_hdmi_out_data),.video_de(S_hdmi_out_de),.video_hs(S_hdmi_out_hsync),.video_vs(S_hdmi_out_vsync),
        .out_rgb(S_target_rgb),.out_de(S_target_de),.out_hs(S_target_hs),.out_vs(S_target_vs),
        .display_count(),.display_error(),.display_frame_id(F_red_display_frame),.display_valid(),.display_commit());

    wire [23:0] F_overlay_rgb;
    wire F_overlay_de,F_overlay_hs,F_overlay_vs;
    final1_motion_osd u_motion_osd(.clk(S_hdmi_pixel_clk),.rst_n(S_hdmi_rst_n),
        .rgb(S_target_rgb),.de(S_target_de),.hs(S_target_hs),.vs(S_target_vs),
        .boxes(F_motion_boxes),.box_valid(F_motion_box_valid & {4{S_display_metadata[2] && S_display_metadata[1:0]==1}}),
        .mask_data(F_motion_mask_data),.mask_wr_buf(F_motion_mask_buf),
        .mask_enable(F_motion_mask_enable && S_display_metadata[2] && S_display_metadata[1:0]==1),
        .mask_y_offset(F_motion_y_offset),.mask_rd_addr(F_motion_mask_addr),
        .mode(F_pixel_mode),.running(F_pixel_running),.ui(F_pixel_ui),.out_rgb(F_overlay_rgb),
        .out_de(F_overlay_de),.out_hs(F_overlay_hs),.out_vs(F_overlay_vs));
    wire [23:0] S_settings_rgb;
    wire S_settings_de,S_settings_hs,S_settings_vs;
    wire [88:0] F_latency_hud;
    final1_latency_epoch_gate u_latency_epoch(
        .ddr_clk(S_ddr_clk),.pixel_clk(S_hdmi_pixel_clk),.rst_n(F_latency_reset_n),
        .published_bank(S_video_out_rp),.frame_valid(S_frame_valid),.display_vs(S_settings_vs),
        .published(F_latency_published),.display_armed(F_latency_display_armed));
    final1_latency u_latency(
        .capture_clk(S_csi_rx_clk),.measure_clk(S_100m_clk),.pixel_clk(S_hdmi_pixel_clk),
        .rst_n(F_latency_reset_n),
        .capture_sof(S_raw_tuser),.capture_id(F_camera_tag[31:0]),
        .display_vs(S_settings_vs),.display_de(S_settings_de),
        .display_good(F_display_good && F_latency_display_armed),.display_id(F_display_source_id),
        .hud_data(F_latency_hud),.hud_valid());
    camera_settings_osd #(.LATENCY_ENABLE(1)) u_camera_settings(
        .latency_data(F_latency_hud),
        .src_clk(S_hud_clk),.pixel_clk(S_hdmi_pixel_clk),.reset_n(S_hud_reset_n),
        .command(S_hud_command),.submit(S_hud_submit),.ready(S_hud_ready),.done(S_hud_done),
        .cfg_done(S_cam_cfg_done),.iic_error(S_cam_iic_error),
        .rgb(F_overlay_rgb),.de(F_overlay_de),.hs(F_overlay_hs),.vs(F_overlay_vs),
        .out_rgb(S_settings_rgb),.out_de(S_settings_de),.out_hs(S_settings_hs),.out_vs(S_settings_vs));
    // FINAL: RGB pipeline -> target annotations -> parameter panel -> HDMI.
    hdmi_tx u_hdmi_tx(
        .I_pixel_clk        ( S_hdmi_pixel_clk  ),
        .I_serial_clk       ( S_hdmi_serial_clk ),
        .I_rst              ( ~S_hdmi_rst_n     ),
        .I_key_in           ( 1'b0              ),
        .I_edid_read_trig   ( 1'b0              ),
        .O_edid_read_valid  (                   ),
        .O_edid_read_data   (                   ),
        .I_video_rgb_enable ( 1'b1              ),
        .I_video_in_vs      ( S_settings_vs   ),
        .I_video_in_de      ( S_settings_de   ),
        .I_video_in_user    ( 1'b0              ),
        .I_video_in_valid   ( 1'b0              ),
        .I_video_in_last    ( 1'b0              ),
        .O_video_in_ready   (                   ),
        .I_video_in_data    ( S_settings_rgb  ),
        .I_audio_valid      ( 1'b0              ),
        .I_audio_left_data  ( 24'd0             ),
        .I_audio_right_data ( 24'd0             ),
        .I_i2s_BCLK         ( 1'b0              ),
        .I_i2s_LRCK         ( 1'b0              ),
        .I_i2s_DOUT         ( 1'b0              ),
        .O_ddc_scl          (                   ),
        .O_hdmi_clk_p       (                   ),
        .O_hdmi_tx_p        (                   ),
        .O_tmds_ch0_p       ( O_tmds_ch0_p      ),
        .O_tmds_ch1_p       ( O_tmds_ch1_p      ),
        .O_tmds_ch2_p       ( O_tmds_ch2_p      ),
        .O_tmds_clk_p       ( O_tmds_clk_p      )
    );


    
endmodule
