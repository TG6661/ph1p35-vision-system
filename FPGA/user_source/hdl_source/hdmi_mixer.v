// HDMI RGB/sync pipeline. Production DEBUG_MODE=0 passes every pixel through.
// Both the color Logo and the yellow CNT branding/counter have been removed.
// Keep the original port/parameter contract and three registered video stages.
// I_overlay_enable remains a compatibility input; target/menu OSD is downstream.
module hdmi_mixer #(
    parameter H_OFFSET = 128,
    parameter V_OFFSET = 60,
    parameter IMG_WIDTH = 1280,
    parameter IMG_HEIGHT = 720,
    parameter integer DEBUG_MODE = 0
)(
    input  wire        I_clk,
    input  wire        I_rst_n,

    input  wire        I_video_vsync,
    input  wire        I_video_hsync,
    input  wire        I_video_de,
    input  wire        I_video_user,
    input  wire        I_video_last,

    input  wire [3:0]  I_debug_status,
    input wire I_overlay_enable,

    output wire        O_video_rd_en,
    input  wire [23:0] I_video_rd_data,

    output reg         O_hdmi_vsync,
    output reg         O_hdmi_hsync,
    output reg         O_hdmi_de,
    output reg  [23:0] O_hdmi_data
);

    reg S_video_vsync_1d,S_video_vsync_2d;
    reg S_video_hsync_1d,S_video_hsync_2d;
    reg S_video_de_1d,S_video_de_2d;
    reg [23:0] S_video_data_1d,S_video_data_2d;
    reg [11:0] S_x,S_x_1d,S_x_2d;

    assign O_video_rd_en=I_video_de;
    // X is only needed by the retained standalone debug patterns. Production
    // DEBUG_MODE=0 removes these unused registers during implementation.
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin S_x<=0;S_x_1d<=0;S_x_2d<=0;end
        else begin
            if(I_video_user) S_x<=1;
            else if(I_video_de) S_x<=I_video_last ? 12'd0 : S_x+1'b1;
            S_x_1d<=S_x;S_x_2d<=S_x_1d;
        end
    end

    // 保留三级RGB与同步流水；正常模式直接输出延迟后的原像素。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            S_video_vsync_1d <= 1'b0; S_video_vsync_2d <= 1'b0;
            S_video_hsync_1d <= 1'b0; S_video_hsync_2d <= 1'b0;
            S_video_de_1d    <= 1'b0; S_video_de_2d    <= 1'b0;
            S_video_data_1d  <= 24'd0; S_video_data_2d <= 24'd0;
            O_hdmi_vsync <= 1'b0; O_hdmi_hsync <= 1'b0;
            O_hdmi_de    <= 1'b0; O_hdmi_data  <= 24'd0;
        end else begin
            S_video_vsync_1d <= I_video_vsync;
            S_video_vsync_2d <= S_video_vsync_1d;
            O_hdmi_vsync <= S_video_vsync_2d;
            S_video_hsync_1d <= I_video_hsync;
            S_video_hsync_2d <= S_video_hsync_1d;
            O_hdmi_hsync <= S_video_hsync_2d;
            S_video_de_1d <= I_video_de;
            S_video_de_2d <= S_video_de_1d;
            O_hdmi_de <= S_video_de_2d;
            S_video_data_1d <= I_video_rd_data;
            S_video_data_2d <= S_video_data_1d;

            if(DEBUG_MODE == 1) begin
                if(S_video_de_2d) begin
                    if(S_x_2d < 12'd128) O_hdmi_data <= 24'hff0000;
                    else if(S_x_2d < 12'd256) O_hdmi_data <= 24'h00ff00;
                    else if(S_x_2d < 12'd384) O_hdmi_data <= 24'h0000ff;
                    else if(S_x_2d < 12'd512) O_hdmi_data <= 24'hffff00;
                    else if(S_x_2d < 12'd640) O_hdmi_data <= 24'h00ffff;
                    else if(S_x_2d < 12'd768) O_hdmi_data <= 24'hff00ff;
                    else if(S_x_2d < 12'd896) O_hdmi_data <= 24'hffffff;
                    else O_hdmi_data <= 24'h202020;
                end else O_hdmi_data <= 24'd0;
            end else if(DEBUG_MODE == 2) begin
                if(S_video_de_2d) begin
                    case(I_debug_status)
                        4'b0000: O_hdmi_data <= 24'h000000;
                        4'b0001: O_hdmi_data <= 24'hff0000;
                        4'b0011: O_hdmi_data <= 24'hffff00;
                        4'b0111: O_hdmi_data <= 24'h00ff00;
                        4'b1111: O_hdmi_data <= S_video_data_2d;
                        default: O_hdmi_data <= 24'h0000ff;
                    endcase
                end else O_hdmi_data <= 24'd0;
            end else if(DEBUG_MODE == 3) begin
                if(S_video_de_2d) begin
                    if(S_x_2d < IMG_WIDTH/4)
                        O_hdmi_data <= I_debug_status[0] ? 24'hff8000 : 24'h404040;
                    else if(S_x_2d < IMG_WIDTH/2)
                        O_hdmi_data <= I_debug_status[1] ? 24'hffff00 : 24'h404040;
                    else if(S_x_2d < (IMG_WIDTH*3)/4)
                        O_hdmi_data <= I_debug_status[2] ? 24'hff0000 : 24'h404040;
                    else O_hdmi_data <= I_debug_status[3] ? 24'h00ffff : 24'h404040;
                end else O_hdmi_data <= 24'd0;
            end else begin
                O_hdmi_data <= S_video_data_2d;
            end
        end
    end

endmodule
