/*
 * 8x8分块帧差运动检测器。
 *
 * 本模块旁接在data128_96之后、AWB之前，只观察视频流，不对主视频链施加
 * 反压。每个输入拍包含4个水平连续的RGB888像素。处理步骤为：
 *
 *   RGB -> Y=R/4+G/2+B/4
 *       -> 8x8块平均
 *       -> 与前一输入帧同位置块平均值作绝对差
 *       -> 差值大于DIFF_THRESHOLD得到原始运动块
 *       -> 3x3邻域内至少NEIGHBOR_THRESHOLD块运动才保留
 *       -> 统计运动块总数并将相邻运动块归入独立的方框
 *
 * 两个平均值Bank交替保存当前帧和前一帧。第一帧只建立参考，不输出运动。
 * 如果当前帧的有效运动块不足MIN_MOTION_BLOCKS，上一有效框还会保持
 * HOLD_FRAMES个输入帧，避免屏幕上的框快速闪烁。
 */
module motion_detect_8x8 #(
    parameter integer IMG_WIDTH              = 1280,
    parameter integer IMG_HEIGHT             = 720,
    parameter integer BLOCK_SIZE             = 8,
    parameter integer DIFF_THRESHOLD         = 20,
    parameter integer NEIGHBOR_THRESHOLD     = 3,
    parameter integer MIN_MOTION_BLOCKS      = 5,
    parameter integer HOLD_FRAMES            = 10,
    // 预留的全局光照突变抑制开关。第一版按确认方案关闭。
    parameter integer ENABLE_LIGHT_SUPPRESS  = 0,
    parameter integer EXTERNAL_FRAME_ID = 0
)(
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_bg_reset,
    input  wire [95:0] I_tdata,
    input  wire        I_tvalid,
    input  wire        I_tready,
    input  wire        I_tuser,
    input  wire        I_tlast,
    input  wire [31:0] I_frame_id,
    input  wire [7:0]  I_diff_threshold,
    input  wire [2:0]  I_neighbor_threshold,
    input  wire [5:0]  I_min_motion_blocks,
    input  wire [4:0]  I_hold_frames,
    input  wire [7:0]  I_motion_dwell_limit,

    // 结果总线在O_result_toggle下一次翻转前保持稳定，供其他时钟域同步。
    output reg         O_result_toggle,
    output reg         O_result_valid,
    output reg  [31:0] O_result_frame_id,
    output reg  [11:0] O_left,
    output reg  [11:0] O_right,
    output reg  [11:0] O_top,
    output reg  [11:0] O_bottom,
    output reg  [14:0] O_block_count,
    output reg  [3:0]  O_box_valid,
    output reg  [119:0] O_boxes,

    // 宏块级运动掩模RAM写入接口（用于HDMI半透明绿纱可视化）
    output reg         O_mask_wr_buf,
    output reg         O_mask_wr_en,
    output reg  [13:0] O_mask_wr_addr,
    output reg         O_mask_wr_data,
    output wire        O_cluster_error
);

    localparam integer BLOCK_COLS  = IMG_WIDTH / BLOCK_SIZE;
    localparam integer BLOCK_ROWS  = IMG_HEIGHT / BLOCK_SIZE;
    localparam integer BLOCK_COUNT = BLOCK_COLS * BLOCK_ROWS;
    localparam [7:0] DIFF_DEFAULT = DIFF_THRESHOLD;
    localparam [2:0] NEIGHBOR_DEFAULT = NEIGHBOR_THRESHOLD;
    localparam [5:0] MIN_DEFAULT = MIN_MOTION_BLOCKS;
    localparam [4:0] HOLD_DEFAULT = HOLD_FRAMES;
    localparam [7:0] DWELL_DEFAULT = 8'd20;
    localparam [21:0] CONFIG_DEFAULT =
        {DIFF_DEFAULT,NEIGHBOR_DEFAULT,MIN_DEFAULT,HOLD_DEFAULT};
    wire [21:0] S_config_async =
        {I_diff_threshold,I_neighbor_threshold,I_min_motion_blocks,I_hold_frames};
    reg [21:0] S_config_meta, S_config_sync, S_config_sync_d, S_config_frame;

    // 当前工程固定每拍4像素。8个横向像素恰好由连续两个有效拍组成。
    wire [7:0] S_gray0 = (I_tdata[95:88] >> 2) + (I_tdata[87:80] >> 1) +
                         (I_tdata[79:72] >> 2);
    wire [7:0] S_gray1 = (I_tdata[71:64] >> 2) + (I_tdata[63:56] >> 1) +
                         (I_tdata[55:48] >> 2);
    wire [7:0] S_gray2 = (I_tdata[47:40] >> 2) + (I_tdata[39:32] >> 1) +
                         (I_tdata[31:24] >> 2);
    wire [7:0] S_gray3 = (I_tdata[23:16] >> 2) + (I_tdata[15:8] >> 1) +
                         (I_tdata[7:0] >> 2);
    wire [9:0] S_gray_sum4 = {2'b0,S_gray0} + {2'b0,S_gray1} +
                              {2'b0,S_gray2} + {2'b0,S_gray3};
    wire S_block_end;
    wire       S_transfer = I_tvalid && I_tready;

    reg [8:0]  S_x_beat;
    reg [9:0]  S_y_pixel;
    reg [31:0] S_frame_id;
    reg        S_compare_enable;

    // 自适应背景模型控制与状态
    reg [2:0]  S_bg_reset_sync;
    wire       S_bg_reset_pulse = S_bg_reset_sync[1] & ~S_bg_reset_sync[2];
    reg        S_bg_reset_pending;
    reg        S_bg_reset_active;
    reg [6:0]  S_warmup_cnt;
    reg [1:0]  S_scene_change_cnt;

    // 8行内各横向块的灰度和。最大值为64*253=16192，14 bit足够。
    // BEGIN ACCUM_ERAM_IMPLEMENTATION
    // Prefetch the next cycle's block address to preserve the original timing.
    // A reset clears only valid bits. Unwritten RAM words logically read zero.
    // Forward the last write on read/write address collisions (two beats/block).
    localparam ACCUM_ADDR_BITS=(BLOCK_COLS>1)?$clog2(BLOCK_COLS):1;
    reg [BLOCK_COLS-1:0] S_accum_valid;
    wire [7:0] S_accum_addr=S_x_beat[8:1];
    wire [8:0] S_accum_next_beat=!S_transfer?S_x_beat:
        I_tuser?9'd1:I_tlast?9'd0:S_x_beat+9'd1;
    wire [7:0] S_accum_rd_addr=S_accum_next_beat[8:1];
    wire [7:0] S_accum_wr_addr=I_tuser?8'd0:S_accum_addr;
    wire S_accum_we=I_rst_n && S_transfer && S_accum_wr_addr<BLOCK_COLS;
    wire [13:0] S_accum_q;
    reg S_accum_forward_valid;
    reg [7:0] S_accum_forward_addr;
    reg [13:0] S_accum_forward_data;
    wire [13:0] S_accum_value=!S_accum_valid[S_accum_addr]?14'd0:
        (S_accum_forward_valid && S_accum_forward_addr==S_accum_addr)?
        S_accum_forward_data:S_accum_q;
    wire [13:0] S_accum_wr_data=I_tuser?{4'd0,S_gray_sum4}:
        (S_y_pixel[2:0]==3'd7 && S_x_beat[0])?14'd0:S_accum_value+S_gray_sum4;
    isp_line_ram #(.DATA_WIDTH_A(14),.DATA_WIDTH_B(14),
        .ADDR_WIDTH_A(ACCUM_ADDR_BITS),.ADDR_WIDTH_B(ACCUM_ADDR_BITS),
        .DATA_DEPTH_A(1<<ACCUM_ADDR_BITS),.DATA_DEPTH_B(1<<ACCUM_ADDR_BITS),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("READBEFOREWRITE")) u_accum_eram(
        .clka(I_clk),.wea(S_accum_we),.addra(S_accum_wr_addr[ACCUM_ADDR_BITS-1:0]),
        .dia(S_accum_wr_data),.doa(),
        .clkb(I_clk),.web(1'b0),.addrb(S_accum_rd_addr[ACCUM_ADDR_BITS-1:0]),
        .dib(14'd0),.dob(S_accum_q));
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_accum_valid<=0;S_accum_forward_valid<=0;
            S_accum_forward_addr<=0;S_accum_forward_data<=0;
        end else begin
            S_accum_forward_valid<=S_accum_we;
            if(S_accum_we) begin
                S_accum_valid[S_accum_wr_addr]<=1'b1;
                S_accum_forward_addr<=S_accum_wr_addr;
                S_accum_forward_data<=S_accum_wr_data;
            end
        end
    end
    // END ACCUM_ERAM_IMPLEMENTATION

    // 宏块级自适应背景模型与驻留状态机：[23:8]为Q8.8定点背景灰度，[7:0]为宏块驻留连续帧数。
    // 深度14400，总容量345.6 Kbit，在PH1A35可用BRAM裕量内（原工程空闲69块ERAM20K）。
    (* ram_style = "bram" *) reg [23:0] S_bg_model [0:BLOCK_COUNT-1];
    reg [23:0] S_bg_model_q;

    // 块结束事件打一拍：当前拍读取背景模型，下一拍计算背景差分并回写更新。
    reg        S_compare_pending;
    reg [7:0]  S_pending_average;
    reg [13:0] S_pending_block_addr;
    reg [7:0]  S_pending_block_x;
    reg [6:0]  S_pending_block_y;
    reg [31:0] S_pending_frame_id;
    reg        S_pending_compare_enable;

    // 原始运动掩膜只需保留相邻块行。偶/奇块行交替覆盖；在覆盖当前地址
    // 的同一时钟沿，非阻塞赋值右值仍可读到两行之前的旧数据。
    reg S_raw_even [0:BLOCK_COLS-1];
    reg S_raw_odd  [0:BLOCK_COLS-1];

    reg S_upper_d2, S_upper_d1;
    reg S_middle_d2, S_middle_d1;
    reg S_lower_d2, S_lower_d1;

    reg [14:0] S_motion_count;
    reg [7:0]  S_min_block_x, S_max_block_x;
    reg [6:0]  S_min_block_y, S_max_block_y;

    reg        S_held_valid;
    reg [11:0] S_held_left, S_held_right, S_held_top, S_held_bottom;
    reg [14:0] S_held_count;
    reg [7:0]  S_hold_remaining;

    // Each stage carries its block coordinates and frame identity with valid.
    // BRAM -> raw difference -> neighborhood sums -> candidates -> batch
    // extrema/count -> frame statistics -> result/hold. No multicycle exception.
    reg S_raw_pending, S_raw_motion;
    reg [7:0] S_raw_x;
    reg [6:0] S_raw_y;
    reg [31:0] S_raw_frame_id;
    reg S_raw_compare_enable;

    reg S_filter_pending;
    reg [3:0] S_sum_normal, S_sum_right, S_sum_bottom, S_sum_corner;
    reg [7:0] S_filter_x;
    reg [6:0] S_filter_y;
    reg [31:0] S_filter_frame_id;
    reg S_filter_compare_enable;

    reg S_candidate_pending;
    // bit0 normal, bit1 right edge, bit2 bottom edge, bit3 corner
    reg [3:0] S_candidates;
    reg [7:0] S_candidate_x;
    reg [6:0] S_candidate_y;
    reg [31:0] S_candidate_frame_id;
    reg S_candidate_compare_enable;

    reg S_batch_pending, S_batch_last, S_batch_compare_enable;
    reg [2:0] S_batch_count;
    reg [7:0] S_batch_min_x, S_batch_max_x;
    reg [6:0] S_batch_min_y, S_batch_max_y;
    reg [31:0] S_batch_frame_id;

    reg S_done_pending, S_done_compare_enable;
    reg [14:0] S_done_count;
    reg [7:0] S_done_min_x, S_done_max_x;
    reg [6:0] S_done_min_y, S_done_max_y;
    reg [31:0] S_done_frame_id;

    reg [1:0] S_region_extra_count, S_region_extra_kind;
    reg [2:0] S_region_extra_bits;
    reg [7:0] S_region_extra_x;
    reg [6:0] S_region_extra_y;
    reg S_region_extra_wait;
    reg [11:0] S_region_done_delay;
    reg S_region_fresh;
    wire S_region_clear = S_filter_pending &&
        S_filter_x == 8'd1 && S_filter_y == 7'd1;
    wire S_region_normal = S_candidate_pending &&
        S_candidate_x != 0 && S_candidate_y != 0;
    wire S_region_add = (S_region_extra_count != 0) ?
        (!S_region_extra_wait && S_region_extra_bits[0]) :
        (S_region_normal && S_candidates[0]);
    wire [7:0] S_region_x = (S_region_extra_count == 0) ?
        S_candidate_x - 1'b1 :
        (S_region_extra_kind == 2'd0 || S_region_extra_kind == 2'd2) ?
        S_region_extra_x : S_region_extra_x - 1'b1;
    wire [6:0] S_region_y = (S_region_extra_count == 0) ?
        S_candidate_y - 1'b1 :
        (S_region_extra_kind == 2'd0) ?
        S_region_extra_y - 1'b1 : S_region_extra_y;
    // 硬件级Y轴垂直空间校准：下移4个宏块(32像素)，对齐DDR/VTC显示缓冲区引起的32像素延迟
    wire [6:0] S_region_y_calib = (S_region_y + 7'd4 > 7'd89) ? 7'd89 : (S_region_y + 7'd4);
    wire [3:0] S_region_rank_valid;
    wire [119:0] S_region_rank_boxes;
    wire S_region_ready;
    wire S_cluster_error;
    assign O_cluster_error=S_cluster_error;

    motion_region_cluster u_motion_region_cluster (
        .I_clk(I_clk), .I_rst_n(I_rst_n), .I_clear(S_region_clear),
        .I_add(S_region_add), .I_x(S_region_x), .I_y(S_region_y_calib),
        .I_finish(S_region_done_delay[11]),
        .O_ready(S_region_ready), .O_overflow(S_cluster_error), .O_valid(S_region_rank_valid),
        .O_boxes(S_region_rank_boxes)
    );

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_config_meta <= CONFIG_DEFAULT;
            S_config_sync <= CONFIG_DEFAULT;
            S_config_sync_d <= CONFIG_DEFAULT;
            S_config_frame <= CONFIG_DEFAULT;
        end else begin
            S_config_meta <= S_config_async;
            S_config_sync <= S_config_meta;
            S_config_sync_d <= S_config_sync;
            if(S_block_end && S_y_pixel == BLOCK_SIZE-1 &&
               S_x_beat == 1 && S_config_sync == S_config_sync_d)
                S_config_frame <= S_config_sync;
        end
    end

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_region_extra_count <= 0;
            S_region_extra_kind <= 0;
            S_region_extra_bits <= 0;
            S_region_extra_x <= 0;
            S_region_extra_y <= 0;
            S_region_extra_wait <= 0;
            S_region_done_delay <= 0;
            S_region_fresh <= 0;
        end else begin
            S_region_done_delay <= {S_region_done_delay[10:0],S_done_pending};
            if(S_done_pending)
                S_region_fresh <= S_done_compare_enable &&
                    (S_done_count >= S_config_frame[10:5]);
            if(S_region_extra_count != 0) begin
                if(S_region_extra_wait)
                    S_region_extra_wait <= 0;
                else begin
                    S_region_extra_wait <= 1;
                    S_region_extra_count <= S_region_extra_count - 1'b1;
                    S_region_extra_bits <= {1'b0,S_region_extra_bits[2:1]};
                    if(S_region_extra_kind == 2'd0)
                        S_region_extra_kind <= 2'd1;
                    else
                        S_region_extra_kind <= 2'd2;
                end
            end else if(S_region_normal) begin
                S_region_extra_x <= S_candidate_x;
                S_region_extra_y <= S_candidate_y;
                if(S_candidate_x == BLOCK_COLS-1 &&
                   S_candidate_y == BLOCK_ROWS-1) begin
                    S_region_extra_bits <= {S_candidates[3],S_candidates[2],S_candidates[1]};
                    S_region_extra_count <= 2'd3;
                    S_region_extra_kind <= 2'd0;
                    S_region_extra_wait <= 1;
                end else if(S_candidate_x == BLOCK_COLS-1) begin
                    S_region_extra_bits <= {2'b0,S_candidates[1]};
                    S_region_extra_count <= 2'd1;
                    S_region_extra_kind <= 2'd0;
                    S_region_extra_wait <= 1;
                end else if(S_candidate_y == BLOCK_ROWS-1) begin
                    S_region_extra_bits <= {2'b0,S_candidates[2]};
                    S_region_extra_count <= 2'd1;
                    S_region_extra_kind <= 2'd1;
                    S_region_extra_wait <= 1;
                end
            end
        end
    end

    wire S_upper_in = (S_raw_y >= 2) &&
        (S_raw_y[0] ? S_raw_odd[S_raw_x] : S_raw_even[S_raw_x]);
    wire S_middle_in = S_raw_y[0] ? S_raw_even[S_raw_x] : S_raw_odd[S_raw_x];
    wire [1:0] S_upper_pair = {1'b0,S_upper_d2} + {1'b0,S_upper_d1};
    wire [1:0] S_middle_pair = {1'b0,S_middle_d2} + {1'b0,S_middle_d1};
    wire [1:0] S_lower_pair = {1'b0,S_lower_d2} + {1'b0,S_lower_d1};
    wire [1:0] S_upper_right = {1'b0,S_upper_d1} + {1'b0,S_upper_in};
    wire [1:0] S_middle_right = {1'b0,S_middle_d1} + {1'b0,S_middle_in};
    wire [1:0] S_lower_right = {1'b0,S_lower_d1} + {1'b0,S_raw_motion};
    wire [2:0] S_upper_sum = {1'b0,S_upper_pair} + {2'b0,S_upper_in};
    wire [2:0] S_middle_sum = {1'b0,S_middle_pair} + {2'b0,S_middle_in};
    wire [2:0] S_lower_sum = {1'b0,S_lower_pair} + {2'b0,S_raw_motion};
    wire [3:0] S_sum_normal_next = {1'b0,S_upper_sum} +
        {1'b0,S_middle_sum} + {1'b0,S_lower_sum};
    wire [3:0] S_sum_right_next = {2'b0,S_upper_right} +
        {2'b0,S_middle_right} + {2'b0,S_lower_right};
    wire [3:0] S_sum_bottom_next = {1'b0,S_middle_sum} + {1'b0,S_lower_sum};
    wire [3:0] S_sum_corner_next = {2'b0,S_middle_right} + {2'b0,S_lower_right};
    wire [1:0] S_candidate_pair0 = {1'b0,S_candidates[0]} + {1'b0,S_candidates[1]};
    wire [1:0] S_candidate_pair1 = {1'b0,S_candidates[2]} + {1'b0,S_candidates[3]};
    wire [2:0] S_batch_count_next = {1'b0,S_candidate_pair0} + {1'b0,S_candidate_pair1};
    wire [14:0] S_count_next = S_motion_count + {12'd0,S_batch_count};
    wire [7:0] S_min_x_next = (S_batch_count != 0 && S_batch_min_x < S_min_block_x) ? S_batch_min_x : S_min_block_x;
    wire [7:0] S_max_x_next = (S_batch_count != 0 && S_batch_max_x > S_max_block_x) ? S_batch_max_x : S_max_block_x;
    wire [6:0] S_min_y_next = (S_batch_count != 0 && S_batch_min_y < S_min_block_y) ? S_batch_min_y : S_min_block_y;
    wire [6:0] S_max_y_next = (S_batch_count != 0 && S_batch_max_y > S_max_block_y) ? S_batch_max_y : S_max_block_y;

    integer index;

    assign S_block_end = S_transfer &&
                              (S_y_pixel[2:0] == 3'd7) && S_x_beat[0];
    wire [13:0] S_block_sum = S_accum_value + S_gray_sum4;
    wire [13:0] S_block_addr = (S_y_pixel[9:3] * BLOCK_COLS) +
                               S_x_beat[8:1];

    // 自适应背景差分计算 (在S_compare_pending拍执行)
    // S_bg_model_q[23:8] 为Q8.8定点背景灰度，S_bg_model_q[7:0] 为宏块连续驻留帧数
    wire [15:0] S_curr_q88   = {S_pending_average, 8'h00};
    wire [7:0]  S_bg_int     = S_bg_model_q[23:16];
    wire [15:0] S_bg_q88     = S_bg_model_q[23:8];
    wire [7:0]  S_prev_dwell = S_bg_model_q[7:0];

    wire [7:0]  S_diff       = (S_pending_average >= S_bg_int) ?
                               (S_pending_average - S_bg_int) :
                               (S_bg_int - S_pending_average);

    // 差值是否超过前景阈值
    wire        S_diff_high = S_pending_compare_enable && (S_diff > S_config_frame[21:14]);

    // 前景驻留冻结阈值：默认20帧(~0.33秒)，可通过MCU动态调节
    wire [7:0]  S_dwell_freeze_limit = (I_motion_dwell_limit != 8'd0) ? I_motion_dwell_limit : DWELL_DEFAULT;

    // 方案一状态机判定：
    // 1. 动态运动中 (S_is_moving_fg)：差值超阈值但驻留未达上限，判定为移动物体穿过，
    //    此时彻底冻结背景更新，保证真实背景绝对不被污染，物体移开后0帧无残影！
    wire        S_is_moving_fg = S_diff_high && (S_prev_dwell < S_dwell_freeze_limit);

    // 2. 静止停稳 (S_is_static_fg)：差值超阈值且驻留已达上限(>=0.33秒)，判定为物体已停稳，
    //    立刻切入快速融景模式，在0.3~0.5秒内将物体平滑同化进背景，绿纱干净消隐！
    wire        S_is_static_fg = S_diff_high && (S_prev_dwell >= S_dwell_freeze_limit);

    // 前景输出使能：差值超阈值即为前景（运动物体与尚未完全融景的静止物体均输出绿纱并参与聚类）
    wire        S_is_foreground = S_diff_high;

    // BEGIN STAGE11_BG_PIPELINE
    // Stage A captures the decision and all transaction operands on the SAME
    // edge as the unchanged foreground/mask path. Never use live controls later.
    reg S_bg_a_valid, S_bg_b_valid;
    reg signed [16:0] S_bg_a_err;
    reg [15:0] S_bg_a_base, S_bg_b_base;
    reg S_bg_a_fast, S_bg_a_freeze;
    reg [13:0] S_bg_a_addr, S_bg_b_addr;
    reg [7:0] S_bg_a_dwell, S_bg_b_dwell;
    reg signed [12:0] S_bg_b_step;
    wire S_bg_initialize = !S_pending_compare_enable || S_bg_reset_active;
    wire signed [16:0] S_bg_error = $signed({1'b0,S_curr_q88}) - $signed({1'b0,S_bg_q88});
    wire signed [12:0] S_bg_shift = S_bg_a_fast ? S_bg_a_err[16:4] :
        {S_bg_a_err[16],S_bg_a_err[16:5]};
    wire signed [12:0] S_bg_corrected =
        (S_bg_shift==13'sd0 && S_bg_a_err!=17'sd0) ? 13'sd1 : S_bg_shift;
    // Stage B has only shift selection / minimum-step correction. Stage C
    // adds the signed step and writes RAM, two clocks after the old write edge.
    wire [15:0] S_bg_write_model = S_bg_b_base + {{3{S_bg_b_step[12]}},S_bg_b_step};
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_bg_a_valid<=0;S_bg_b_valid<=0;
            S_bg_a_err<=0;S_bg_a_base<=0;S_bg_b_base<=0;
            S_bg_a_fast<=0;S_bg_a_freeze<=0;
            S_bg_a_addr<=0;S_bg_b_addr<=0;
            S_bg_a_dwell<=0;S_bg_b_dwell<=0;S_bg_b_step<=0;
        end else begin
            S_bg_a_valid<=S_compare_pending;
            S_bg_b_valid<=S_bg_a_valid;
            if(S_compare_pending) begin
                S_bg_a_err<=S_bg_error;
                S_bg_a_base<=S_bg_initialize ? S_curr_q88 : S_bg_q88;
                S_bg_a_fast<=S_is_static_fg;
                S_bg_a_freeze<=S_bg_initialize || S_is_moving_fg;
                S_bg_a_addr<=S_pending_block_addr;
                S_bg_a_dwell<=(S_bg_initialize || !S_diff_high) ? 8'd0 :
                    (S_prev_dwell==8'd255 ? 8'd255 : S_prev_dwell+8'd1);
            end
            if(S_bg_a_valid) begin
                S_bg_b_base<=S_bg_a_base;S_bg_b_addr<=S_bg_a_addr;
                S_bg_b_dwell<=S_bg_a_dwell;
                S_bg_b_step<=S_bg_a_freeze ? 13'sd0 : S_bg_corrected;
            end
        end
    end
    // Reads remain on block-end. Different block transactions may overlap;
    // the background write stream accepts one transaction per clock.
    // A legal 8x8 block revisit takes >=32 accepted pixel beats, longer than
    // this pipeline. Reset cancels pending writes; RAM contents are not cleared.
    always @(posedge I_clk) begin
        if(S_block_end) S_bg_model_q <= S_bg_model[S_block_addr];
        if(I_rst_n && S_bg_b_valid)
            S_bg_model[S_bg_b_addr] <= {S_bg_write_model,S_bg_b_dwell};
    end
    // END STAGE11_BG_PIPELINE

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_x_beat                 <= 9'd0;
            S_y_pixel                <= 10'd0;
            S_frame_id               <= 32'd0;
            S_compare_enable         <= 1'b0;
            S_bg_reset_sync          <= 3'b0;
            S_bg_reset_pending       <= 1'b0;
            S_bg_reset_active        <= 1'b1;
            S_warmup_cnt             <= 7'd0;
            S_scene_change_cnt       <= 2'd0;
            S_compare_pending        <= 1'b0;
            S_pending_average        <= 8'd0;
            S_pending_block_addr     <= 14'd0;
            S_pending_block_x        <= 8'd0;
            S_pending_block_y        <= 7'd0;
            S_pending_frame_id       <= 32'd0;
            S_pending_compare_enable <= 1'b0;
            S_raw_pending <= 0; S_raw_motion <= 0;
            S_raw_x <= 0; S_raw_y <= 0; S_raw_frame_id <= 0; S_raw_compare_enable <= 0;
            S_filter_pending <= 0;
            S_sum_normal <= 0; S_sum_right <= 0; S_sum_bottom <= 0; S_sum_corner <= 0;
            S_filter_x <= 0; S_filter_y <= 0; S_filter_frame_id <= 0; S_filter_compare_enable <= 0;
            S_candidate_pending <= 0; S_candidates <= 0;
            S_candidate_x <= 0; S_candidate_y <= 0; S_candidate_frame_id <= 0; S_candidate_compare_enable <= 0;
            S_batch_pending <= 0; S_batch_last <= 0; S_batch_compare_enable <= 0;
            S_batch_count <= 0; S_batch_min_x <= 0; S_batch_max_x <= 0;
            S_batch_min_y <= 0; S_batch_max_y <= 0; S_batch_frame_id <= 0;
            S_done_pending <= 0; S_done_compare_enable <= 0; S_done_count <= 0;
            S_done_min_x <= 0; S_done_max_x <= 0; S_done_min_y <= 0; S_done_max_y <= 0; S_done_frame_id <= 0;
            S_upper_d2 <= 1'b0; S_upper_d1 <= 1'b0;
            S_middle_d2 <= 1'b0; S_middle_d1 <= 1'b0;
            S_lower_d2 <= 1'b0; S_lower_d1 <= 1'b0;
            S_motion_count <= 15'd0;
            S_min_block_x  <= BLOCK_COLS-1;
            S_max_block_x  <= 8'd0;
            S_min_block_y  <= BLOCK_ROWS-1;
            S_max_block_y  <= 7'd0;
            S_held_valid    <= 1'b0;
            S_held_left     <= 12'd0;
            S_held_right    <= 12'd0;
            S_held_top      <= 12'd0;
            S_held_bottom   <= 12'd0;
            S_held_count    <= 15'd0;
            S_hold_remaining <= 8'd0;
            O_result_toggle   <= 1'b0;
            O_result_valid    <= 1'b0;
            O_result_frame_id <= 32'd0;
            O_left            <= 12'd0;
            O_right           <= 12'd0;
            O_top             <= 12'd0;
            O_bottom          <= 12'd0;
            O_block_count     <= 15'd0;
            O_box_valid       <= 4'd0;
            O_boxes           <= 120'd0;
            O_mask_wr_buf     <= 1'b0;
            O_mask_wr_en      <= 1'b0;
            O_mask_wr_addr    <= 14'd0;
            O_mask_wr_data    <= 1'b0;
            // Accumulator reset is handled by S_accum_valid.
        end else begin
            S_compare_pending <= 1'b0;
            S_bg_reset_sync   <= {S_bg_reset_sync[1:0], I_bg_reset};
            if(S_bg_reset_pulse)
                S_bg_reset_pending <= 1'b1;

            // ----------------------------------------------------------------
            // 输入扫描、8x8累加、双Bank读写
            // ----------------------------------------------------------------
            if(S_transfer) begin
                if(I_tuser) begin
                    S_frame_id       <= EXTERNAL_FRAME_ID ? I_frame_id : S_frame_id + 1'b1;
                    O_mask_wr_buf    <= ~O_mask_wr_buf;
                    S_y_pixel        <= 10'd0;
                    S_x_beat         <= 9'd1;
                    // Accumulator SOF write is handled by u_accum_eram.
                    if(S_bg_reset_pending) begin
                        S_warmup_cnt <= 7'd0;
                        S_bg_reset_pending <= 1'b0;
                    end

                    // 上电/复位后前60帧(~1秒)为纯学习预热期，不输出运动检测，等待相机曝光彻底稳定
                    if(S_warmup_cnt < 7'd60) begin
                        S_warmup_cnt      <= S_warmup_cnt + 1'b1;
                        S_bg_reset_active <= 1'b1;
                        S_compare_enable  <= 1'b0;
                    end else begin
                        S_bg_reset_active <= 1'b0;
                        S_compare_enable  <= 1'b1;
                    end
                end else begin
                    // 每个8x8块在第8行、第二个4像素拍到达时结束。
                    if((S_y_pixel[2:0] == 3'd7) && S_x_beat[0]) begin
                        // Accumulator block-end clear is handled by u_accum_eram.

                        S_pending_average        <= S_block_sum[13:6];
                        S_pending_block_addr     <= S_block_addr;
                        S_pending_block_x        <= S_x_beat[8:1];
                        S_pending_block_y        <= S_y_pixel[9:3];
                        S_pending_frame_id       <= S_frame_id;
                        S_pending_compare_enable <= S_compare_enable && !S_bg_reset_active;
                        S_compare_pending        <= 1'b1;
                    end else begin
                        // Accumulator addition is handled by u_accum_eram.
                    end

                    if(I_tlast) begin
                        S_x_beat <= 9'd0;
                        if(S_y_pixel == IMG_HEIGHT-1) begin
                            S_y_pixel <= 10'd0;
                        end else begin
                            S_y_pixel <= S_y_pixel + 1'b1;
                        end
                    end else begin
                        S_x_beat <= S_x_beat + 1'b1;
                    end
                end
            end

            S_raw_pending <= S_compare_pending;
            S_filter_pending <= S_raw_pending;
            S_candidate_pending <= S_filter_pending;
            S_batch_pending <= S_candidate_pending;
            S_done_pending <= 1'b0;

            // Only background subtraction decision and stage 1 register transfer
            if(S_compare_pending) begin
                S_raw_x <= S_pending_block_x;
                S_raw_y <= S_pending_block_y;
                S_raw_frame_id <= S_pending_frame_id;
                S_raw_compare_enable <= S_pending_compare_enable;
                S_raw_motion <= S_is_foreground;
                O_mask_wr_en   <= 1'b1;
                O_mask_wr_addr <= S_pending_block_addr;
                O_mask_wr_data <= S_is_foreground;
            end else begin
                O_mask_wr_en   <= 1'b0;
            end

            // Read before overwrite retains the row two block-rows above.
            if(S_raw_pending) begin
                if(S_raw_y[0]) S_raw_odd[S_raw_x] <= S_raw_motion;
                else S_raw_even[S_raw_x] <= S_raw_motion;
                S_filter_x <= S_raw_x;
                S_filter_y <= S_raw_y;
                S_filter_frame_id <= S_raw_frame_id;
                S_filter_compare_enable <= S_raw_compare_enable;
                S_sum_normal <= S_sum_normal_next;
                S_sum_right <= S_sum_right_next;
                S_sum_bottom <= S_sum_bottom_next;
                S_sum_corner <= S_sum_corner_next;
                if(S_raw_x == 0) begin
                    S_upper_d2 <= 0; S_middle_d2 <= 0; S_lower_d2 <= 0;
                end else begin
                    S_upper_d2 <= S_upper_d1;
                    S_middle_d2 <= S_middle_d1;
                    S_lower_d2 <= S_lower_d1;
                end
                S_upper_d1 <= S_upper_in;
                S_middle_d1 <= S_middle_in;
                S_lower_d1 <= S_raw_motion;
            end

            // A separate stage thresholds the four possible boundary candidates.
            if(S_filter_pending) begin
                S_candidate_x <= S_filter_x;
                S_candidate_y <= S_filter_y;
                S_candidate_frame_id <= S_filter_frame_id;
                S_candidate_compare_enable <= S_filter_compare_enable;
                S_candidates[0] <= S_filter_x != 0 && S_filter_y != 0 && S_sum_normal >= S_config_frame[13:11];
                S_candidates[1] <= S_filter_x != 0 && S_filter_x == BLOCK_COLS-1 && S_filter_y != 0 && S_sum_right >= S_config_frame[13:11];
                S_candidates[2] <= S_filter_x != 0 && S_filter_y == BLOCK_ROWS-1 && S_sum_bottom >= S_config_frame[13:11];
                S_candidates[3] <= S_filter_x != 0 && S_filter_x == BLOCK_COLS-1 && S_filter_y == BLOCK_ROWS-1 && S_sum_corner >= S_config_frame[13:11];
            end

            // All candidates lie in {x-1,x} x {y-1,y}. Reduce them in parallel;
            // do not cascade four full-width count increments or box updates.
            if(S_candidate_pending) begin
                S_batch_count <= S_batch_count_next;
                S_batch_min_x <= (S_candidates[0] || S_candidates[2]) ? S_candidate_x - 1'b1 : S_candidate_x;
                S_batch_max_x <= (S_candidates[1] || S_candidates[3]) ? S_candidate_x : S_candidate_x - 1'b1;
                S_batch_min_y <= (S_candidates[0] || S_candidates[1]) ? S_candidate_y - 1'b1 : S_candidate_y;
                S_batch_max_y <= (S_candidates[2] || S_candidates[3]) ? S_candidate_y : S_candidate_y - 1'b1;
                S_batch_last <= S_candidate_x == BLOCK_COLS-1 && S_candidate_y == BLOCK_ROWS-1;
                S_batch_frame_id <= S_candidate_frame_id;
                S_batch_compare_enable <= S_candidate_compare_enable;
            end

            if(S_batch_pending) begin
                if(S_batch_last) begin
                    // Snapshot includes the last batch (up to four candidates).
                    S_done_pending <= 1'b1;
                    S_done_count <= S_count_next;
                    S_done_min_x <= S_min_x_next; S_done_max_x <= S_max_x_next;
                    S_done_min_y <= S_min_y_next; S_done_max_y <= S_max_y_next;
                    S_done_frame_id <= S_batch_frame_id;
                    S_done_compare_enable <= S_batch_compare_enable;
                    S_motion_count <= 0;
                    S_min_block_x <= BLOCK_COLS-1; S_max_block_x <= 0;
                    S_min_block_y <= BLOCK_ROWS-1; S_max_block_y <= 0;
                end else begin
                    S_motion_count <= S_count_next;
                    S_min_block_x <= S_min_x_next; S_max_block_x <= S_max_x_next;
                    S_min_block_y <= S_min_y_next; S_max_block_y <= S_max_y_next;
                end
            end

            // Threshold/hold/output mux starts from the registered final stats.
            if(S_done_pending) begin
                O_result_frame_id <= S_done_frame_id;
                // 场景突变检测：若超过50%宏块(>7200)判定为运动且持续2帧，自动触发背景重新建模
                if(S_done_compare_enable && (S_done_count > 15'd7200)) begin
                    if(S_scene_change_cnt >= 2'd2) begin
                        S_bg_reset_pending <= 1'b1;
                        S_scene_change_cnt <= 2'd0;
                    end else begin
                        S_scene_change_cnt <= S_scene_change_cnt + 1'b1;
                    end
                end else begin
                    S_scene_change_cnt <= 2'd0;
                end

                if(S_done_compare_enable &&
                   (S_done_count >= S_config_frame[10:5])) begin
                        O_result_valid <= 1'b1;
                        O_left   <= S_done_min_x * BLOCK_SIZE;
                        O_right  <= ((S_done_max_x + 1'b1) * BLOCK_SIZE) - 1'b1;
                        O_top    <= S_done_min_y * BLOCK_SIZE;
                        O_bottom <= ((S_done_max_y + 1'b1) * BLOCK_SIZE) - 1'b1;
                        O_block_count <= S_done_count;

                        S_held_valid  <= 1'b1;
                        S_held_left   <= S_done_min_x * BLOCK_SIZE;
                        S_held_right  <= ((S_done_max_x + 1'b1) * BLOCK_SIZE) - 1'b1;
                        S_held_top    <= S_done_min_y * BLOCK_SIZE;
                        S_held_bottom <= ((S_done_max_y + 1'b1) * BLOCK_SIZE) - 1'b1;
                        S_held_count  <= S_done_count;
                        S_hold_remaining <= S_config_frame[4:0];
                    end else if(S_held_valid && (S_hold_remaining != 0)) begin
                        O_result_valid <= 1'b1;
                        O_left         <= S_held_left;
                        O_right        <= S_held_right;
                        O_top          <= S_held_top;
                        O_bottom       <= S_held_bottom;
                        O_block_count  <= S_held_count;
                        S_hold_remaining <= S_hold_remaining - 1'b1;
                    end else begin
                        O_result_valid <= 1'b0;
                        O_left         <= 12'd0;
                        O_right        <= 12'd0;
                        O_top          <= 12'd0;
                        O_bottom       <= 12'd0;
                        O_block_count  <= 15'd0;
                        S_hold_remaining <= 8'd0;
                    end

            end
            if(S_region_ready) begin
                if(S_region_fresh) begin
                    O_box_valid <= S_region_rank_valid;
                    O_boxes <= S_region_rank_boxes;
                end else begin
                    O_box_valid <= 4'd0;
                    O_boxes <= 120'd0;
                end
                O_result_toggle <= ~O_result_toggle;
            end
        end
    end

endmodule

// Streaming, bounded region grouping with short axis-aligned gap bridging.
// The frame gap is used to rank eight temporary regions without a wide sorter.
// Eight-region algorithm, serialized over the sparse 8x8-block event stream.
// 512x15 FIFO absorbs the last macro-row's boundary candidates. One event takes
// 11 clocks; sustained two-clock events are NOT supported outside this schedule.
// Finish is a barrier: rank only after every queued update commits.
module motion_region_cluster #(
    parameter [8:0] BRIDGE_DISTANCE=9'd3,
    parameter [13:0] MIN_REGION_BLOCKS=14'd3
)(
    input wire I_clk,I_rst_n,I_clear,I_add,I_finish,
    input wire [7:0] I_x,input wire [6:0] I_y,
    output reg O_ready,output reg [3:0] O_valid,output reg [119:0] O_boxes,
    output reg O_overflow
);
    localparam IDLE=0,FETCH=1,SCAN=2,COMMIT=3,RANK=4;
    reg [2:0] state,scan;
    reg [8:0] wr_ptr,rd_ptr;
    reg [9:0] queued;
    reg finishing,frame_error;
    wire pop=state==IDLE && queued!=0 && !I_clear;
    wire push=I_add && !I_clear && !finishing && state!=RANK && (queued<512 || pop);
    wire [14:0] event_q;
    isp_line_ram #(.DATA_WIDTH_A(15),.DATA_WIDTH_B(15),.ADDR_WIDTH_A(9),.ADDR_WIDTH_B(9),
        .DATA_DEPTH_A(512),.DATA_DEPTH_B(512),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("READBEFOREWRITE")) u_events(
        .clka(I_clk),.wea(push),.addra(wr_ptr),.dia({I_x,I_y}),.doa(),
        .clkb(I_clk),.web(1'b0),.addrb(rd_ptr),.dib(15'd0),.dob(event_q));
    // Single asynchronous read + single write; active bits hide uninitialized RAM.
    (* ram_style="dram" *) reg [43:0] regions[0:7];
    reg [7:0] active,hit_mask,selected;
    wire [43:0] region=regions[scan];
    wire [7:0] left=region[43:36],right=region[35:28];
    wire [6:0] top=region[27:21],bottom=region[20:14];
    wire [13:0] size=region[13:0];
    reg [7:0] px,merge_left,merge_right;
    reg [6:0] py,merge_top,merge_bottom;
    reg [13:0] merge_size;
    reg found_hit,found_free;
    reg [2:0] hit_slot,free_slot;
    wire adjacent={1'b0,px}<={1'b0,right}+9'd1 && {1'b0,px}+9'd1>={1'b0,left} &&
        {1'b0,py}<={1'b0,bottom}+8'd1 && {1'b0,py}+8'd1>={1'b0,top};
    wire horizontal={1'b0,px}<={1'b0,right}+BRIDGE_DISTANCE &&
        {1'b0,px}+BRIDGE_DISTANCE>={1'b0,left} && py>=top && py<=bottom;
    wire vertical={1'b0,py}<={1'b0,bottom}+BRIDGE_DISTANCE[7:0] &&
        {1'b0,py}+BRIDGE_DISTANCE[7:0]>={1'b0,top} && px>=left && px<=right;
    wire hit=active[scan] && (adjacent || (size>=MIN_REGION_BLOCKS && (horizontal || vertical)));
    wire [2:0] destination=found_hit?hit_slot:free_slot;
    wire store=state==COMMIT && (found_hit || found_free) && !I_clear && I_rst_n;
    always @(posedge I_clk)
        if(store) regions[destination]<={merge_left,merge_right,merge_top,merge_bottom,merge_size};
    reg [1:0] rank;
    reg [2:0] best_index;
    reg [13:0] best_size;
    reg [29:0] best_box;
    wire wins=active[scan] && !selected[scan] && size>=MIN_REGION_BLOCKS && size>best_size;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            state<=IDLE;scan<=0;wr_ptr<=0;rd_ptr<=0;queued<=0;finishing<=0;frame_error<=0;
            active<=0;hit_mask<=0;selected<=0;px<=0;py<=0;
            merge_left<=0;merge_right<=0;merge_top<=0;merge_bottom<=0;merge_size<=0;
            found_hit<=0;found_free<=0;hit_slot<=0;free_slot<=0;
            rank<=0;best_index<=0;best_size<=0;best_box<=0;
            O_ready<=0;O_valid<=0;O_boxes<=0;O_overflow<=0;
        end else begin
            O_ready<=0;
            if(I_clear) begin
                state<=IDLE;queued<=0;wr_ptr<=0;rd_ptr<=0;finishing<=0;frame_error<=0;active<=0;
            end else begin
                if(push) wr_ptr<=wr_ptr+1'b1;
                if(pop) rd_ptr<=rd_ptr+1'b1;
                case({push,pop})
                    2'b10:queued<=queued+1'b1;
                    2'b01:queued<=queued-1'b1;
                    default:queued<=queued;
                endcase
                if(I_add && !push) begin O_overflow<=1;frame_error<=1;end
                if(I_finish) begin finishing<=1;O_valid<=0;O_boxes<=0;end
                case(state)
                    IDLE: if(pop) state<=FETCH;
                        else if(finishing && !I_add) begin
                            state<=RANK;scan<=0;rank<=0;selected<=0;best_size<=0;best_index<=0;best_box<=0;
                        end
                    FETCH: begin
                        px<=event_q[14:7];py<=event_q[6:0];scan<=0;hit_mask<=0;
                        merge_left<=event_q[14:7];merge_right<=event_q[14:7];
                        merge_top<=event_q[6:0];merge_bottom<=event_q[6:0];merge_size<=1;
                        found_hit<=0;found_free<=0;state<=SCAN;
                    end
                    SCAN: begin
                        // No region mutates during this scan: all hits use the old snapshot.
                        if(!active[scan] && !found_free) begin found_free<=1;free_slot<=scan;end
                        if(hit) begin
                            hit_mask[scan]<=1;
                            if(!found_hit) begin found_hit<=1;hit_slot<=scan;end
                            if(left<merge_left) merge_left<=left;
                            if(right>merge_right) merge_right<=right;
                            if(top<merge_top) merge_top<=top;
                            if(bottom>merge_bottom) merge_bottom<=bottom;
                            merge_size<=merge_size+size; // preserve 14-bit modular arithmetic
                        end
                        if(scan==7) state<=COMMIT;else scan<=scan+1'b1;
                    end
                    COMMIT: begin
                        if(found_hit || found_free) active<=(active & ~hit_mask) | (8'b1<<destination);
                        state<=IDLE;
                    end
                    RANK: begin
                        if(wins) begin best_size<=size;best_index<=scan;best_box<=region[43:14];end
                        if(scan==7) begin
                            if(!frame_error && (wins || best_size!=0)) begin
                                O_valid[rank]<=1;O_boxes[rank*30+:30]<=wins?region[43:14]:best_box;
                                selected[wins?scan:best_index]<=1;
                            end
                            scan<=0;best_size<=0;best_box<=0;
                            if(rank==3) begin state<=IDLE;finishing<=0;O_ready<=1;end
                            else rank<=rank+1'b1;
                        end else scan<=scan+1'b1;
                    end
                    default:state<=IDLE;
                endcase
            end
        end
    end
endmodule


/*
 * 运动掩模双缓冲BRAM (Ping-Pong Motion Mask Dual-Port RAM)
 * 存储容量：160 * 90 = 14,400 bits/帧。
 * 双缓冲有效数据 28,800 bits；{bank, block_addr[13:0]} 地址布局需 32,768 项。
 * bank 1 有效地址 16384..30783，不能将数组截为 28800 项。
 * PH1P35 当前映射为 2 块 ERAM20K；保留原读延迟和银行选择接口。
 */
module motion_mask_ram (
    input  wire        I_wr_clk,
    input  wire        I_wr_en,
    input  wire [14:0] I_wr_addr,
    input  wire        I_wr_data,

    input  wire        I_rd_clk,
    input  wire [14:0] I_rd_addr,
    output reg         O_rd_data
);

    (* ram_style = "bram" *) reg mem [0:32767];

    integer k;
    initial begin
        for(k = 0; k < 32768; k = k + 1)
            mem[k] = 1'b0;
    end

    always @(posedge I_wr_clk) begin
        if(I_wr_en)
            mem[I_wr_addr] <= I_wr_data;
    end

    always @(posedge I_rd_clk) begin
        O_rd_data <= mem[I_rd_addr];
    end

endmodule

