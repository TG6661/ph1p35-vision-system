// Mode-specific HUD v2. Semantic selection IDs and the 96-bit CDC are retained.
// [28] display AWB, [29] mask, [38:32] MIN BCD, [39] AUTO EXP.
// MOT [75:68] is DWELL BCD and [67:64] is NEIG; see fabric_regs.h.
// Held payload crosses with a request/ack;
// acknowledgement means staged in pixel domain, not shown/current source frame.
module camera_settings_osd #(parameter LATENCY_ENABLE=0)(
    input wire src_clk,pixel_clk,reset_n,
    input wire [95:0] command,input wire submit,
    output wire ready,output reg done,
    input wire cfg_done,iic_error,
    input wire [88:0] latency_data, // Coherent mailbox output in pixel_clk.
    input wire [23:0] rgb,input wire de,hs,vs,
    output reg [23:0] out_rgb,output reg out_de,out_hs,out_vs
);
    localparam [95:0] DEFAULTS={1'b0,2'd0,1'b1,4'd5,12'h065,12'h065,12'h100,12'h032,12'h000,12'h190,16'h1991};
    wire src_idle,src_reset_n,dst_reset_n,pending;
    reg waiting;
    target_result_cdc #(.SYNC_RELEASE(1)) u_cdc(
        .src_clk(src_clk),.dst_clk(pixel_clk),.reset_n(reset_n),
        .src_submit(submit),.src_idle(src_idle),.src_reset_n(src_reset_n),
        .dst_reset_n(dst_reset_n),.dst_pending(pending),.dst_accept(pending));
    assign ready=src_idle && !waiting && !submit;
    always @(posedge src_clk or negedge src_reset_n)
        if(!src_reset_n) begin waiting<=0;done<=0;end
        else begin
            done<=0;
            if(submit && src_idle) waiting<=1;
            else if(waiting && src_idle) begin waiting<=0;done<=1;end
        end
    reg [95:0] staged;
    reg [97:0] displayed;
    (* ASYNC_REG="TRUE" *) reg [1:0] status_meta,status_sync;
    reg vs_d,de_d;
    reg [88:0] latency_displayed;
    // The mailbox already stages its payload. Commit the whole snapshot at VS.
    always @(posedge pixel_clk or negedge dst_reset_n)
        if(!dst_reset_n) latency_displayed<=0;
        else if(LATENCY_ENABLE && vs && !vs_d) latency_displayed<=latency_data;
    reg [11:0] S_x_2d,S_y_2d;
    always @(posedge pixel_clk or negedge dst_reset_n) begin
        if(!dst_reset_n) begin
            staged<=DEFAULTS;displayed<={2'd0,DEFAULTS};status_meta<=0;status_sync<=0;
            vs_d<=0;de_d<=0;S_x_2d<=0;S_y_2d<=0;
        end else begin
            status_meta<={iic_error,cfg_done};status_sync<=status_meta;
            vs_d<=vs;de_d<=de;
            if(pending) staged<=command;
            // Same-edge arrival is intentionally displayed at the NEXT VS.
            if(vs&&!vs_d) begin displayed<={status_sync,staged};S_x_2d<=0;S_y_2d<=0;end
            else if(de) S_x_2d<=S_x_2d+1'b1;
            else if(de_d) begin S_x_2d<=0;S_y_2d<=S_y_2d+1'b1;end
        end
    end
    wire [3:0] selection=displayed[91:88];
    wire [1:0] mode_sel=displayed[94:93];
    function [7:0] digit;
        input integer n,pos;integer offset;
        begin
            offset=n==0?0:16+(n-1)*12;
            digit=8'h30+{4'd0,displayed[offset+pos*4+:4]};
        end
    endfunction
    function [23:0] dec3;
        input integer n;
        begin dec3={digit(n,2),digit(n,1),digit(n,0)};end
    endfunction
    function [7:0] font8_row;
        input [7:0] char_code;
        input [2:0] row_index;
        reg [63:0] glyph;
        begin
            case(char_code)
                8'h2b: glyph=64'h0010107c10100000; // + (saturated reading)
                8'h2f: glyph=64'h0204081020400000; // /
                8'h50: glyph=64'h7c42427c40404000; // P
                8'h42: glyph=64'h7c42427c42427c00; // B
                8'h55: glyph=64'h4242424242423c00; // U
                8'h59: glyph=64'h4242241818181800; // Y
                8'h2e: glyph=64'h0000000000181800; // .
                8'h2d: glyph=64'h0000007e00000000; // -
                8'h48: glyph=64'h4242427e42424200; // H
                8'h58: glyph=64'h4242241824424200; // X
                8'h44: glyph = 64'h7844444444447800; // D
                8'h4b: glyph = 64'h4244487048444200; // K
                8'h4c: glyph = 64'h4040404040407e00; // L
                8'h4e: glyph = 64'h4262524a46424200; // N
                8'h4f: glyph = 64'h3c42424242423c00; // O
                8'h52: glyph = 64'h7c42427c48444200; // R
                8'h53: glyph = 64'h3c42403c02423c00; // S
                8'h54: glyph = 64'h7f08080808080800; // T
                8'h56: glyph = 64'h4242424242241800; // V
                8'h57: glyph = 64'h4242425a5a664200; // W
                8'h41: glyph = 64'h1824427e42424200; // A
                8'h43: glyph = 64'h3c42404040423c00; // C
                8'h45: glyph = 64'h7e40407c40407e00; // E
                8'h46: glyph = 64'h7e40407c40404000; // F
                8'h47: glyph = 64'h3c42404e42423c00; // G
                8'h49: glyph = 64'h3e08080808083e00; // I
                8'h4a: glyph = 64'h1e04040444443800; // J (ADJUST)
                8'h4d: glyph = 64'h42665a5a42424200; // M
                8'h30: glyph = 64'h3c42464a52623c00; // 0
                8'h31: glyph = 64'h1828080808083e00; // 1
                8'h32: glyph = 64'h3c42020c30407e00; // 2
                8'h33: glyph = 64'h3c42021c02423c00; // 3
                8'h34: glyph = 64'h0c1424447e040400; // 4
                8'h35: glyph = 64'h7e407c0202423c00; // 5
                8'h36: glyph = 64'h1c20407c42423c00; // 6
                8'h37: glyph = 64'h7e02040810202000; // 7
                8'h38: glyph = 64'h3c42423c42423c00; // 8
                8'h39: glyph = 64'h3c42423e02043800; // 9
                8'h3a: glyph = 64'h0018180018180000; // :
                default: glyph = 64'h0000000000000000;
            endcase
            font8_row = glyph >> ((7-row_index)*8);
        end
    endfunction
    // Full Anlogic Corporate Logo (146x94, 2-bit palette BRAM ROM)
    wire logo_box=de && S_x_2d>=12'd32 && S_x_2d<12'd178 && S_y_2d>=12'd600 && S_y_2d<12'd694;
    wire [11:0] logo_fetch_x=S_x_2d+12'd1;
    wire [11:0] logo_local_x=(logo_fetch_x>=12'd32 && logo_fetch_x<12'd178)?(logo_fetch_x-12'd32):12'd0;
    wire [11:0] logo_local_y=(S_y_2d>=12'd600 && S_y_2d<12'd694)?(S_y_2d-12'd600):12'd0;
    wire [13:0] logo_y_x146=({7'd0,logo_local_y[6:0]}<<7)+({7'd0,logo_local_y[6:0]}<<4)+({7'd0,logo_local_y[6:0]}<<1);
    wire [13:0] logo_addr=logo_y_x146+{6'd0,logo_local_x[7:0]};
    wire [23:0] logo_pixel_rgb;
    wire logo_pixel_valid;
    anlogic_logo_rom u_logo_rom (
        .clk(pixel_clk),
        .addr(logo_addr),
        .pixel_rgb(logo_pixel_rgb),
        .pixel_valid(logo_pixel_valid)
    );
    wire [11:0] fx_value=displayed[63:52];
    // Adjustable rows only: RED10, MOTION9, STYLE8 (LSC removed).
    wire [4:0] panel_rows=mode_sel==2?5'd8:mode_sel==1?5'd9:5'd10;
    wire [11:0] panel_bottom=12'd28+({7'd0,panel_rows}<<4)+({7'd0,panel_rows}<<2);
    wire S_osd_box=de && S_x_2d>=24 && S_x_2d<344 && S_y_2d>=24 && S_y_2d<panel_bottom;
    // Below the existing mode/UI badge; 16 double-size characters x 4 lines.
    wire latency_box=LATENCY_ENABLE && de && S_x_2d>=1008 && S_x_2d<1264 && S_y_2d>=56 && S_y_2d<140;
    function [47:0] latency_dec6;
        input [23:0] value;input valid;integer k;
        begin
            latency_dec6="------";
            if(valid) for(k=0;k<6;k=k+1) latency_dec6[k*8+:8]=8'h30+{4'd0,value[k*4+:4]};
        end
    endfunction
    wire [47:0] latency_in_text=latency_dec6(latency_displayed[83:60],latency_displayed[88]);
    wire [47:0] latency_out_text=latency_dec6(latency_displayed[59:36],latency_displayed[87]);
    wire [47:0] latency_fd_text=latency_dec6({12'd0,latency_displayed[35:24]},latency_displayed[86]);
    wire [47:0] latency_us_text=latency_dec6(latency_displayed[23:0],latency_displayed[86]);
    reg S_osd_text,S_osd_selected_line,S_osd_readonly_line;
    reg [3:0] line_item;
    reg [7:0] S_char_code,S_font_bits;
    // Decode the scanline before the visible box, then fetch each character
    // two pixels ahead. Only overlay metadata is pipelined; RGB/DE/HS/VS keep
    // their original one-clock output latency and all three OSD priorities.
    reg [159:0] text_q;
    reg [2:0] row_q;
    reg selected_q,readonly_q;
    wire latency_prefetch=LATENCY_ENABLE && S_x_2d>=12'd1004;
    wire [11:0] fetch_x=S_x_2d+12'd2;
    wire [11:0] fetch_local_x=latency_prefetch ? fetch_x-12'd1008 : fetch_x-12'd24;
    wire [7:0] fetch_index=fetch_local_x[11:4];
    wire [11:0] pixel_local_x=latency_prefetch ? S_x_2d-12'd1008 : S_x_2d-12'd24;
    reg [159:0] line_text;
    integer local_x,local_y,line_no,row,col,index,j;
    always @(*) begin
        local_x=0;local_y=0;line_no=-1;row=0;col=0;index=0;
        S_osd_text=0;S_osd_selected_line=0;S_osd_readonly_line=0;line_item=15;line_text="                    ";
        if(!latency_prefetch && S_y_2d>=24 && S_y_2d<panel_bottom) begin
            local_x=S_x_2d-24;local_y=S_y_2d-24;
            index=local_x>>4;col=(local_x>>1)&7;
            for(j=0;j<10;j=j+1) if(local_y>=4+j*20 && local_y<20+j*20) begin
                line_no=j;row=(local_y-4-j*20)>>1;
            end
            case(line_no)
                0:begin line_text=(mode_sel==1)?"MODE:MOTION         ":(mode_sel==2)?"MODE:STYLE          ":"MODE:RED            ";line_item=4'd5;end
                1:begin line_text=displayed[39]?"AUTO EXP:ON         ":"AUTO EXP:OFF        ";line_item=4'd10;end
                2:begin line_text={"AE:",{digit(0,3),digit(0,2),digit(0,1),digit(0,0)},"             "};line_item=4'd0;end
                3:begin line_text={"AG:",dec3(1),"              "};line_item=4'd1;end
                4:begin line_text=displayed[92]?"BL:ON               ":"BL:OFF              ";line_item=4'd3;end
                5:begin line_text={"BO:",dec3(3),"              "};line_item=4'd4;end
                6:begin
                    line_item=4'd6;
                    if(mode_sel==1) line_text={"DIFF:",dec3(4),"            "};
                    else if(mode_sel==2) case(fx_value)
                        1:line_text="FX:CRT              ";
                        2:line_text="FX:PIX              ";
                        3:line_text="FX:HAT              ";
                        4:line_text="FX:NEG              ";
                        5:line_text="FX:ASCII            ";
                        default:line_text="FX:RGB              ";
                    endcase
                    else line_text={"RMIN:",dec3(4),"            "};
                end
                7:begin
                    line_item=4'd7;
                    if(mode_sel==1) line_text={"NEIG:",{8'h30,8'h30,digit(5,0)},"            "};
                    else if(mode_sel==2) case(displayed[67:64])
                        1:line_text="CL:CLD              ";
                        2:line_text="CL:WRM              ";
                        default:line_text="CL:ALL              ";
                    endcase
                    else line_text={"RGAP:",dec3(5),"            "};
                end
                8:begin
                    line_item=4'd8;
                    if(mode_sel==1) line_text={"HOLD:",dec3(6),"            "};
                    else if(mode_sel==2) begin line_text="                    ";line_item=4'd15;end
                    else line_text={"BGAP:",dec3(6),"            "};
                end
                9:if(mode_sel!=1 && mode_sel!=2) begin
                    line_text=displayed[95]?"TRACK:PATROL        ":"TRACK:OFF           ";line_item=4'd9;
                end
                default:;
            endcase
            S_osd_readonly_line=(line_item==4'd15);
            S_osd_selected_line=(line_item!=4'd15 && selection==line_item);
        end else if(latency_prefetch && S_y_2d>=56 && S_y_2d<140) begin
            local_x=S_x_2d-1008;local_y=S_y_2d-56;
            index=local_x>>4;col=(local_x>>1)&7;
            for(j=0;j<4;j=j+1) if(local_y>=4+j*20 && local_y<20+j*20) begin
                line_no=j;row=(local_y-4-j*20)>>1;
            end
            case(line_no)
                0:line_text={"IN: ",latency_in_text,"          "};
                1:line_text={"OUT:",latency_out_text,"          "};
                2:line_text={"FD: ",latency_fd_text[23:0],(latency_displayed[86] && latency_displayed[85])?8'h2b:8'h20,"            "};
                3:line_text={"LAT:",latency_us_text,(latency_displayed[86] && latency_displayed[84])?8'h2b:8'h20,"US       "};
                default:line_text="                    ";
            endcase
        end
        S_osd_text=S_font_bits[3'd7-pixel_local_x[3:1]];
    end
    always @(posedge pixel_clk or negedge dst_reset_n) begin
        if(!dst_reset_n) begin
            text_q<=160'd0;row_q<=0;selected_q<=0;readonly_q<=0;
            S_char_code<=0;S_font_bits<=0;
        end else begin
            text_q<=line_text;row_q<=row[2:0];
            selected_q<=S_osd_selected_line;readonly_q<=S_osd_readonly_line;
            S_char_code<=fetch_index<20 ? text_q[159-fetch_index*8-:8] : 8'h20;
            S_font_bits<=font8_row(S_char_code,row_q);
        end
    end
    wire [23:0] rgb_dim = {1'b0, rgb[23:17], 1'b0, rgb[15:9], 1'b0, rgb[7:1]};
    wire [23:0] text_color = selected_q ? 24'h00ffcc : readonly_q ? 24'h8899a6 : 24'he2e8f0;
    always @(posedge pixel_clk or negedge dst_reset_n) begin
        if(!dst_reset_n) begin out_rgb<=0;out_de<=0;out_hs<=0;out_vs<=0;end
        else begin
            out_rgb <= logo_box ? (logo_pixel_valid ? logo_pixel_rgb : rgb) :
                       latency_box ? (S_osd_text ? 24'he2e8f0 : rgb) :
                       S_osd_box ? (S_osd_text ? text_color : (selected_q ? rgb_dim : rgb)) :
                       rgb;
            out_de<=de;out_hs<=hs;out_vs<=vs;
        end
    end
endmodule
