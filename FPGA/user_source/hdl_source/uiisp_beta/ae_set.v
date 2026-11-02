/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2023/03/23
*Module Name:
*File Name:
*Description: 
*The reference demo provided by Milianke is only used for learning. 
*We cannot ensure that the demo itself is free of bugs, so users 
*should be responsible for the technical problems and consequences
*caused by the use of their own products.
*Copyright: Copyright (c) MiLianKe
*All rights reserved.
*Revision: 1.0
*Signal description
*1) I_ input
*2) O_ output
*3) IO_ input output
*4) S_ system internal signal
*5) _n activ low
*6) _dg debug signal 
*7) _r delay or register
*8) _s state mechine
*********************************************************************/
// OOPFPGA: nine adjustable items; WB is FIXED and the display is FINAL only.
// Camera and segmentation menu; thresholds adjust by one per press/repeat.
//
// KEY0: move selection up
// KEY1: move selection down
// KEY2: increase selected value
// KEY3: decrease selected value
//
// Exposure, gain and gamma use different long-press repeat rates because
// their numeric ranges are very different.  AE/AG writes retain the original
// request/done handshake, so a long press always publishes the newest target
// value instead of queueing every intermediate I2C write.
module ae_set #(
    parameter integer DEBOUNCE_CYCLES = 480000,    // 20 ms @ 24 MHz
    parameter integer HOLD_CYCLES     = 12000000,  // 500 ms @ 24 MHz
    parameter integer AE_REPEAT       = 240000,    // 10 ms @ 24 MHz
    parameter integer AG_REPEAT       = 1200000,   // 50 ms @ 24 MHz
    parameter integer GAMMA_REPEAT    = 6000000    // 250 ms @ 24 MHz
) (
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_threshold_lock,
    input  wire [3:0]  I_btn,
    input  wire        I_ae_cfg_done,
    input  wire        I_cam_cfg_done,
    output wire        O_ae_req,
    output wire [15:0] O_ae,
    output wire [15:0] O_ag,
    output wire [3:0]  O_gamma_level,
    output wire [3:0]  O_selected_item,
    output reg [1:0] O_sf_mode,
    output wire [1:0] O_view_mode,
    output reg O_blc_enable,
    output reg [7:0] O_blc_offset,
    output wire [1:0] O_wb_mode,
    output reg [7:0] O_rmin,O_rgap,O_bgap
);

    localparam [3:0] ITEM_AE=0, ITEM_AG=1, ITEM_GAMMA=2,
        ITEM_BL=3, ITEM_BO=4, ITEM_SF=5,
        ITEM_RMIN=6, ITEM_RGAP=7, ITEM_BGAP=8;
    assign O_wb_mode=2'd1;
    assign O_view_mode=2'd0;

    localparam [15:0] AE_MIN = 16'd2;
    // Legacy controller: same half-line limit as MCU for fixed VTS=1000.
    localparam [15:0] AE_MAX = 16'd1991;
    localparam [15:0] AG_MIN = 16'd16;
    localparam [15:0] AG_MAX = 16'd239;

    // 12 gamma levels:
    // 0..11 -> 1.00, 0.95, 0.90, 0.85, 0.80, 0.75,
    //          0.70, 0.65, 0.60, 0.55, 0.50, 0.45.
    localparam [3:0] GAMMA_DEFAULT = 4'd6;
    localparam [3:0] GAMMA_MAX     = 4'd11;

    reg [3:0] btn_meta;
    reg [3:0] btn_sync;
    reg [3:0] btn_candidate;
    reg [3:0] btn_debounced;
    reg [3:0] btn_pressed_d;
    reg [18:0] debounce_cnt;

    wire [3:0] btn_pressed = ~btn_debounced;
    wire [3:0] btn_press_pulse = btn_pressed & ~btn_pressed_d;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            btn_meta       <= 4'hf;
            btn_sync       <= 4'hf;
            btn_candidate  <= 4'hf;
            btn_debounced  <= 4'hf;
            btn_pressed_d  <= 4'h0;
            debounce_cnt   <= 19'd0;
        end else begin
            btn_meta      <= I_btn;
            btn_sync      <= btn_meta;
            btn_pressed_d <= btn_pressed;

            if (btn_sync == btn_debounced) begin
                btn_candidate <= btn_sync;
                debounce_cnt  <= 19'd0;
            end else if (btn_sync != btn_candidate) begin
                btn_candidate <= btn_sync;
                debounce_cnt  <= 19'd0;
            end else if (debounce_cnt == DEBOUNCE_CYCLES - 1) begin
                btn_debounced <= btn_candidate;
                debounce_cnt  <= 19'd0;
            end else begin
                debounce_cnt <= debounce_cnt + 1'b1;
            end
        end
    end

    reg [3:0] selected_item;
    assign O_selected_item = selected_item;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            selected_item <= ITEM_AE;
        end else if (btn_press_pulse[0] && !btn_press_pulse[1]) begin
            selected_item <= selected_item==ITEM_AE ? ITEM_BGAP : selected_item-1'b1;
        end else if (btn_press_pulse[1] && !btn_press_pulse[0]) begin
            selected_item <= selected_item>=ITEM_BGAP ? ITEM_AE : selected_item+1'b1;
        end
    end

    // Long-press auto repeat for KEY2/KEY3.  Only one direction is accepted
    // at a time; pressing both value keys suppresses adjustment.
    wire adjust_held = btn_pressed[2] ^ btn_pressed[3];
    reg [23:0] hold_cnt;
    reg [22:0] repeat_cnt;
    reg        repeat_pulse;
    reg [22:0] repeat_limit;

    always @(*) begin
        case (selected_item)
            ITEM_AE:    repeat_limit = AE_REPEAT;
            ITEM_AG:    repeat_limit = AG_REPEAT;
            default:    repeat_limit = GAMMA_REPEAT;
        endcase
    end

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            hold_cnt     <= 24'd0;
            repeat_cnt   <= 23'd0;
            repeat_pulse <= 1'b0;
        end else begin
            repeat_pulse <= 1'b0;
            if (!adjust_held) begin
                hold_cnt   <= 24'd0;
                repeat_cnt <= 23'd0;
            end else if (hold_cnt < HOLD_CYCLES) begin
                hold_cnt   <= hold_cnt + 1'b1;
                repeat_cnt <= 23'd0;
            end else if (repeat_cnt >= repeat_limit - 1'b1) begin
                repeat_cnt   <= 23'd0;
                repeat_pulse <= 1'b1;
            end else begin
                repeat_cnt <= repeat_cnt + 1'b1;
            end
        end
    end

    wire increase_event = (btn_press_pulse[2] && !btn_pressed[3]) ||
                          (repeat_pulse && btn_pressed[2] && !btn_pressed[3]);
    wire decrease_event = (btn_press_pulse[3] && !btn_pressed[2]) ||
                          (repeat_pulse && btn_pressed[3] && !btn_pressed[2]);

    reg [15:0] ae_target;
    reg [15:0] ag_target;
    reg [3:0]  gamma_target;
    wire [15:0] ae_step = repeat_pulse ? 16'd8 : 16'd1;

    assign O_gamma_level = gamma_target;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            ae_target    <= 16'd1991;
            ag_target    <= 16'd190;
            gamma_target <= GAMMA_DEFAULT;
            O_sf_mode<=3;O_blc_enable<=1;O_blc_offset<=32;
            O_rmin<=100;O_rgap<=65;O_bgap<=65;
        end else begin
            case (selected_item)
                ITEM_AE: begin
                    if (increase_event) begin
                        if (ae_target >= AE_MAX - ae_step)
                            ae_target <= AE_MAX;
                        else
                            ae_target <= ae_target + ae_step;
                    end else if (decrease_event) begin
                        if (ae_target <= AE_MIN + ae_step)
                            ae_target <= AE_MIN;
                        else
                            ae_target <= ae_target - ae_step;
                    end
                end

                ITEM_AG: begin
                    if (increase_event && ag_target < AG_MAX)
                        ag_target <= ag_target + 1'b1;
                    else if (decrease_event && ag_target > AG_MIN)
                        ag_target <= ag_target - 1'b1;
                end

                ITEM_BL: begin
                    if(increase_event) O_blc_enable<=1;
                    else if(decrease_event) O_blc_enable<=0;
                end
                ITEM_BO: begin
                    if(increase_event && O_blc_offset<255) O_blc_offset<=O_blc_offset+1'b1;
                    else if(decrease_event && O_blc_offset>0) O_blc_offset<=O_blc_offset-1'b1;
                end
                ITEM_SF: begin
                    if(btn_press_pulse[2] && !btn_pressed[3]) O_sf_mode<=O_sf_mode+1'b1;
                    else if(btn_press_pulse[3] && !btn_pressed[2]) O_sf_mode<=O_sf_mode-1'b1;
                end
                ITEM_RMIN: begin
                    if(!I_threshold_lock && increase_event && O_rmin<255) O_rmin<=O_rmin+1'b1;
                    else if(!I_threshold_lock && decrease_event && O_rmin>0) O_rmin<=O_rmin-1'b1;
                end
                ITEM_RGAP: begin
                    if(!I_threshold_lock && increase_event && O_rgap<255) O_rgap<=O_rgap+1'b1;
                    else if(!I_threshold_lock && decrease_event && O_rgap>0) O_rgap<=O_rgap-1'b1;
                end
                ITEM_BGAP: begin
                    if(!I_threshold_lock && increase_event && O_bgap<255) O_bgap<=O_bgap+1'b1;
                    else if(!I_threshold_lock && decrease_event && O_bgap>0) O_bgap<=O_bgap-1'b1;
                end
                ITEM_GAMMA: begin
                    // The internal curve index runs in the opposite direction
                    // to the displayed exponent:
                    // index 0 = 1.00, index 11 = 0.45.
                    // Therefore KEY2 (increase) decrements the index so that
                    // the OSD value changes 0.70 -> 0.75, while KEY3 changes
                    // 0.70 -> 0.65 and produces stronger brightening.
                    if (increase_event && gamma_target > 0)
                        gamma_target <= gamma_target - 1'b1;
                    else if (decrease_event && gamma_target < GAMMA_MAX)
                        gamma_target <= gamma_target + 1'b1;
                end
            endcase
        end
    end

    reg [15:0] ae_applied;
    reg [15:0] ag_applied;
    reg        ae_req;

    assign O_ae     = ae_applied;
    assign O_ag     = ag_applied;
    assign O_ae_req = ae_req;

    always @(posedge I_clk or posedge I_rst) begin
        if (I_rst) begin
            ae_req     <= 1'b0;
            ae_applied <= 16'd1990;
            ag_applied <= 16'd17;
        end else if (ae_req) begin
            ae_req <= 1'b0;
        end else if (((ae_applied != ae_target) ||
                      (ag_applied != ag_target)) &&
                     I_cam_cfg_done && I_ae_cfg_done) begin
            ae_applied <= ae_target;
            ag_applied <= ag_target;
            ae_req     <= 1'b1;
        end
    end

endmodule
