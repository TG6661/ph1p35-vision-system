// Eleven-item panel. HUD bit39 carries AUTO EXP in the unused fixed-GMR field.
// Held payload crosses with a request/ack;
// acknowledgement means staged in pixel domain, not shown/current source frame.
module camera_settings_osd_reference #(parameter LATENCY_ENABLE=0)(
    input wire src_clk,pixel_clk,reset_n,
    input wire [95:0] command,input wire submit,
    output wire ready,output reg done,
    input wire cfg_done,iic_error,
    input wire [88:0] latency_data, // Coherent mailbox output in pixel_clk.
    input wire [23:0] rgb,input wire de,hs,vs,
    output reg [23:0] out_rgb,output reg out_de,out_hs,out_vs
);
    localparam [95:0] DEFAULTS={1'b0,2'd3,1'b1,4'd0,12'h065,12'h065,12'h100,12'h032,12'h070,12'h190,16'h1991};
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
    // BEGIN GENERATED COMPACT ANLOGIC LOGO (tools/generate_compact_logo.py)
    // 64x48 one-bit artwork (384 bytes), sharing the existing HUD coordinates.
    // Final OSD priority keeps the logo visible over motion veil/target boxes.
    // No extra video pipeline or frame buffer. No ERAM is requested.
    wire logo_box=de && S_x_2d>=32 && S_x_2d<96 && S_y_2d>=640 && S_y_2d<688;
    wire [5:0] logo_x=S_x_2d-12'd32;
    wire [5:0] logo_y=S_y_2d-12'd640;
    function [63:0] compact_logo_row;
        input [5:0] y;
        begin
            case(y)
                6'd3:compact_logo_row=64'h000001ffffffffff;
                6'd4:compact_logo_row=64'h00000cfffffffffe;
                6'd5:compact_logo_row=64'h00001c0000000000;
                6'd6:compact_logo_row=64'h00001e0000000000;
                6'd7:compact_logo_row=64'h00003e0000000000;
                6'd8:compact_logo_row=64'h00003f3ffffffff8;
                6'd9:compact_logo_row=64'h00007f3ffffffff8;
                6'd10:compact_logo_row=64'h00007f8000000000;
                6'd11:compact_logo_row=64'h0000ff8000000000;
                6'd12:compact_logo_row=64'h0000ffc000000000;
                6'd13:compact_logo_row=64'h0001ffcfffffffe0;
                6'd14:compact_logo_row=64'h0001ffe7ffffffc0;
                6'd15:compact_logo_row=64'h0003ffe000000000;
                6'd16:compact_logo_row=64'h0003fff000000000;
                6'd17:compact_logo_row=64'h0007fff000000000;
                6'd18:compact_logo_row=64'h0007fff9ffffff00;
                6'd19:compact_logo_row=64'h000ffff9ffffff00;
                6'd20:compact_logo_row=64'h000ffffc00000000;
                6'd21:compact_logo_row=64'h001ffffc00000000;
                6'd22:compact_logo_row=64'h001ff7fe7ffffc00;
                6'd23:compact_logo_row=64'h003ff3fe7ffffc00;
                6'd24:compact_logo_row=64'h003fe3ff3ffff800;
                6'd25:compact_logo_row=64'h007fe1ff00000000;
                6'd26:compact_logo_row=64'h007fc1ff80000000;
                6'd27:compact_logo_row=64'h00ffc0ff9fffe000;
                6'd28:compact_logo_row=64'h00ff80ffcfffe000;
                6'd29:compact_logo_row=64'h01ff807fc4004000;
                6'd30:compact_logo_row=64'h01ff007fe0000000;
                6'd31:compact_logo_row=64'h03ff003fe0000000;
                6'd32:compact_logo_row=64'h03fe003ff3ff8000;
                6'd33:compact_logo_row=64'h07fe001ff3ff8000;
                6'd34:compact_logo_row=64'h07fc001ff8000000;
                6'd35:compact_logo_row=64'h0ffc000ff8000000;
                6'd36:compact_logo_row=64'h0ffffe07fc000000;
                6'd37:compact_logo_row=64'h1fffff07fefe0000;
                6'd38:compact_logo_row=64'h1fffff03fe7c0000;
                6'd39:compact_logo_row=64'h3fffff83ff000000;
                6'd40:compact_logo_row=64'h3fffff81ff000000;
                6'd41:compact_logo_row=64'h7fffffc1ff800000;
                6'd42:compact_logo_row=64'h7fffffc0ff900000;
                6'd43:compact_logo_row=64'hffffffe0ff800000;
                default:compact_logo_row=64'd0;
            endcase
        end
    endfunction
    wire [63:0] logo_row=compact_logo_row(logo_y);
    wire logo_ink=logo_row[6'd63-logo_x];
    // END GENERATED COMPACT ANLOGIC LOGO
    wire S_osd_box=de && S_x_2d>=24 && S_x_2d<216 && S_y_2d>=24 && S_y_2d<288;
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
    reg S_osd_text,S_osd_selected_line;
    reg [7:0] S_char_code,S_font_bits;
    reg [127:0] line_text;
    integer local_x,local_y,line_no,row,col,index,j;
    always @(*) begin
        local_x=0;local_y=0;line_no=-1;row=0;col=0;index=0;
        S_osd_text=0;S_osd_selected_line=0;S_char_code=0;S_font_bits=0;line_text="                ";
        if(S_osd_box) begin
            local_x=S_x_2d-24;local_y=S_y_2d-24;
            index=local_x>>4;col=(local_x>>1)&7;
            for(j=0;j<13;j=j+1) if(local_y>=4+j*20 && local_y<20+j*20) begin
                line_no=j;row=(local_y-4-j*20)>>1;
            end
            if(line_no>=0 && line_no<11) S_osd_selected_line=(selection==line_no);
            case(line_no)
                0:line_text={"AE:",digit(0,3),digit(0,2),digit(0,1),digit(0,0),"         "};
                1:line_text={"AG:",dec3(1),"          "};
                2:line_text="GMR0.70 FIX     "; // All 11 visible columns fit; stale legacy payloads cannot change it.
                3:line_text=displayed[92] ? "BL:ON           " : "BL:OFF          ";
                4:line_text={"BO:",dec3(3),"          "};
                5:case(mode_sel)
                    2'd1:    line_text="MODE:MOT        ";
                    2'd2:    line_text="MODE:STY        ";
                    default: line_text="MODE:RED        ";
                  endcase
                6:case(mode_sel)
                    2'd1:    line_text={"DIFF:",dec3(4),"        "};
                    2'd2:    line_text={"FX:  ",dec3(4),"        "};
                    default: line_text={"RMIN:",dec3(4),"        "};
                  endcase
                7:case(mode_sel)
                    2'd1:    line_text={"NEIG:",dec3(5),"        "};
                    2'd2:    line_text={"CL:  ",dec3(5),"        "};
                    default: line_text={"RGAP:",dec3(5),"        "};
                  endcase
                8:case(mode_sel)
                    2'd1:    line_text={"HOLD:",dec3(6),"        "};
                    2'd2:    line_text={"LSC: ",dec3(6),"        "};
                    default: line_text={"BGAP:",dec3(6),"        "};
                  endcase
                9:line_text=displayed[95] ? "TRACK:ON        " : "TRACK:OFF       ";
                10:line_text=displayed[39] ? "AUTO EXP:ON     " : "AUTO EXP:OFF    ";
                11:line_text=displayed[96] ? "CFG:1           " : "CFG:0           ";
                12:line_text=displayed[97] ? "I2C:1           " : "I2C:0           ";
                default:line_text="                ";
            endcase
        end else if(latency_box) begin
            local_x=S_x_2d-1008;local_y=S_y_2d-56;
            index=local_x>>4;col=(local_x>>1)&7;
            for(j=0;j<4;j=j+1) if(local_y>=4+j*20 && local_y<20+j*20) begin
                line_no=j;row=(local_y-4-j*20)>>1;
            end
            case(line_no)
                0:line_text={"IN: ",latency_in_text,"      "};
                1:line_text={"OUT:",latency_out_text,"      "};
                2:line_text={"FD: ",latency_fd_text[23:0],(latency_displayed[86] && latency_displayed[85])?8'h2b:8'h20,"        "};
                3:line_text={"LAT:",latency_us_text,(latency_displayed[86] && latency_displayed[84])?8'h2b:8'h20,"US   "};
                default:line_text="                ";
            endcase
        end
        if(S_osd_box || latency_box) begin
            if(index<16) S_char_code=line_text[127-index*8-:8];
            S_font_bits=font8_row(S_char_code,row[2:0]);S_osd_text=S_font_bits[7-col];
        end
    end
    always @(posedge pixel_clk or negedge dst_reset_n) begin
        if(!dst_reset_n) begin out_rgb<=0;out_de<=0;out_hs<=0;out_vs<=0;end
        else begin
            out_rgb<=logo_box ? (logo_ink ? 24'hffffff : 24'h182840) : (S_osd_box || latency_box) ? (S_osd_text ? (S_osd_selected_line ? 24'hfff200 : 24'hffffff) :
                (S_osd_selected_line ? 24'h203050 : 24'h101010)) : rgb;
            out_de<=de;out_hs<=hs;out_vs<=vs;
        end
    end
endmodule
