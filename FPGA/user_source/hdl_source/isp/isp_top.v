// OPFPGA fixed-rate shared-demosaic RGB / WB / R-Gamma capture front end.
// Shared frontend owns RED-only STRONG SF and the single demosaic instance.
module isp_top #(
    parameter [19:0] FIXED_R_GAIN_Q16 = 20'd95907,
    parameter [19:0] FIXED_B_GAIN_Q16 = 20'd100825,
    parameter FIXED_CALIBRATED = 1'b1
) (
    input               axi4s_video_aclk,
    input               I_rst_n,
    input [3:0]         I_gamma_level,
    input [10:0]        I_color_config, // coherent {BL, BO[7:0], WB[1:0]}, already in pixel domain
    output reg [91:0]   O_diagnostics, // valid, calibrated, mode, Rq16, Bq16, preRGB, postRGB
    // Shared linear RGB stream from final1_raw_front (4px/beat, 96-bit RGB888)
    input [95:0]        I_rgb_data,
    input               I_rgb_valid,
    input               I_rgb_user,
    input               I_rgb_last,
    input               O_tready,
    output [127:0]      O_tdata,
    output              O_tlast,
    output              O_tuser,
    output              O_tvalid,
    output              I_tready,
    output [95:0]       O_detect_data,
    output              O_detect_valid,
    output              O_detect_user,
    output              O_detect_last
);

    assign I_tready = 1'b1;

    // Fixed-gain white balance (awb)
    wire [1:0]  wb_active;
    wire [19:0] r_gain_q16, b_gain_q16;
    wire        awb_O_tlast;
    wire        awb_O_tuser;
    wire [95:0] awb_O_tdata;
    wire        awb_O_tvalid;
    wire        awb_O_tready = O_tready;

    reg [10:0] color_active;
    wire [10:0] color_frame = I_rgb_user ? I_color_config : color_active;
    always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
        if (!I_rst_n)
            color_active <= {1'b0, 8'd32, 2'd1};
        else if (I_rgb_user)
            color_active <= I_color_config;
    end

    awb #(
        .FIXED_R_GAIN_Q16(FIXED_R_GAIN_Q16),
        .FIXED_B_GAIN_Q16(FIXED_B_GAIN_Q16),
        .IMG_HEIGHT(720),
        .IMG_WIDTH(1280)
    ) u_awb (
        .I_wb_mode  (color_active[1:0]),
        .O_wb_mode  (wb_active),
        .O_r_gain_q16(r_gain_q16),
        .O_b_gain_q16(b_gain_q16),
        .I_clk      (axi4s_video_aclk),
        .I_rst_n    (I_rst_n),
        .I_tlast    (I_rgb_last),
        .I_tuser    (I_rgb_user),
        .I_tdata    (I_rgb_data),
        .I_tvalid   (I_rgb_valid),
        .I_tready   (),
        .O_tlast    (awb_O_tlast),
        .O_tuser    (awb_O_tuser),
        .O_tdata    (awb_O_tdata),
        .O_tvalid   (awb_O_tvalid),
        .O_tready   (awb_O_tready)
    );

    // R-only Gamma
    wire [95:0] gamma_O_tdata;
    wire        gamma_O_tvalid, gamma_O_tuser, gamma_O_tlast;

    axis_gamma_rgb96 u_gamma (
        .I_clk          (axi4s_video_aclk),
        .I_rst_n        (I_rst_n),
        .I_gamma_level  (I_gamma_level),
        .I_tdata        (awb_O_tdata),
        .I_tvalid       (awb_O_tvalid),
        .I_tuser        (awb_O_tuser),
        .I_tlast        (awb_O_tlast),
        .O_tdata        (gamma_O_tdata),
        .O_tvalid       (gamma_O_tvalid),
        .O_tuser        (gamma_O_tuser),
        .O_tlast        (gamma_O_tlast)
    );

    // Diagnostics register
    always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
        if (!I_rst_n)
            O_diagnostics <= 92'd0;
        else
            O_diagnostics <= {1'b1, FIXED_CALIBRATED, wb_active, r_gain_q16, b_gain_q16, 24'd0, 24'd0};
    end

    // Tap detection outputs
    assign O_detect_data = gamma_O_tdata;

    reg detect_pending, detect_active;
    reg [8:0] detect_x;
    reg [9:0] detect_y;
    assign O_detect_valid = gamma_O_tvalid && (detect_active || detect_pending || gamma_O_tuser);
    assign O_detect_user  = O_detect_valid && !detect_active;
    assign O_detect_last  = O_detect_valid && (detect_x == 319);

    always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            detect_pending <= 1'b0;
            detect_active  <= 1'b0;
            detect_x       <= 9'd0;
            detect_y       <= 10'd0;
        end else begin
            if (gamma_O_tuser)
                detect_pending <= 1'b1;
            if (O_detect_valid) begin
                if (!detect_active) begin
                    detect_pending <= 1'b0;
                    detect_active  <= 1'b1;
                end
                if (detect_x == 319) begin
                    detect_x <= 9'd0;
                    if (detect_y == 719) begin
                        detect_y <= 10'd0;
                        detect_active <= 1'b0;
                    end else begin
                        detect_y <= detect_y + 1'b1;
                    end
                end else begin
                    detect_x <= detect_x + 1'b1;
                end
            end
        end
    end

    // 96-bit to 128-bit packing for DDR capture
    wire         awb_O_tuser_128;
    wire         awb_O_tvalid_128;
    wire [127:0] awb_O_tdata_128;

    data_96bit_to_128bit u_data_96bit_to_128bit (
        .I_clk              (axi4s_video_aclk),
        .I_rst_n            (I_rst_n),
        .I_96b_frame_start  (gamma_O_tuser),
        .I_96b_valid        (gamma_O_tvalid),
        .I_96b_data         (gamma_O_tdata),
        .O_128b_frame_start (awb_O_tuser_128),
        .O_128b_valid       (awb_O_tvalid_128),
        .O_128b_data        (awb_O_tdata_128)
    );

    // 1280 RGB888 pixels = 240 packed beats per row. Align EOL to packed data.
    reg [7:0] packed_x;
    always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
        if (!I_rst_n)
            packed_x <= 8'd0;
        else if (O_tuser)
            packed_x <= 8'd0;
        else if (O_tvalid)
            packed_x <= (packed_x == 239) ? 8'd0 : packed_x + 1'b1;
    end

    assign O_tdata  = awb_O_tdata_128;
    assign O_tvalid = awb_O_tvalid_128;
    assign O_tuser  = awb_O_tuser_128;
    assign O_tlast  = O_tvalid && (packed_x == 239);

endmodule
