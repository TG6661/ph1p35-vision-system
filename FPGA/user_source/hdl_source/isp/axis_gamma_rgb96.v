// RED-only Gamma fixed at 0.70 (legacy mode 6), approved 2026-10-26.
// This table is EXACTLY the prior integer piecewise-linear implementation,
// including rounding and the input-255 override; it is not a new pow() curve.
// Four R pixels per clock, one-clock latency; G/B and sidebands stay aligned.
// Legacy I_gamma_level remains for source/port compatibility and is ignored.
module axis_gamma_rgb96 (
    input wire I_clk, I_rst_n,
    input wire [3:0] I_gamma_level,
    input wire I_tlast, I_tuser,
    input wire [95:0] I_tdata,
    input wire I_tvalid,
    output reg O_tlast, O_tuser,
    output wire [95:0] O_tdata,
    output reg O_tvalid
);
    function [7:0] fixed_gamma07;
        input [7:0] value;
        begin
            case(value)
                8'd0: fixed_gamma07=8'd0;
                8'd1: fixed_gamma07=8'd2;
                8'd2: fixed_gamma07=8'd5;
                8'd3: fixed_gamma07=8'd7;
                8'd4: fixed_gamma07=8'd9;
                8'd5: fixed_gamma07=8'd12;
                8'd6: fixed_gamma07=8'd14;
                8'd7: fixed_gamma07=8'd16;
                8'd8: fixed_gamma07=8'd19;
                8'd9: fixed_gamma07=8'd21;
                8'd10: fixed_gamma07=8'd23;
                8'd11: fixed_gamma07=8'd25;
                8'd12: fixed_gamma07=8'd28;
                8'd13: fixed_gamma07=8'd30;
                8'd14: fixed_gamma07=8'd32;
                8'd15: fixed_gamma07=8'd35;
                8'd16: fixed_gamma07=8'd37;
                8'd17: fixed_gamma07=8'd38;
                8'd18: fixed_gamma07=8'd40;
                8'd19: fixed_gamma07=8'd41;
                8'd20: fixed_gamma07=8'd43;
                8'd21: fixed_gamma07=8'd44;
                8'd22: fixed_gamma07=8'd46;
                8'd23: fixed_gamma07=8'd47;
                8'd24: fixed_gamma07=8'd49;
                8'd25: fixed_gamma07=8'd50;
                8'd26: fixed_gamma07=8'd51;
                8'd27: fixed_gamma07=8'd53;
                8'd28: fixed_gamma07=8'd54;
                8'd29: fixed_gamma07=8'd56;
                8'd30: fixed_gamma07=8'd57;
                8'd31: fixed_gamma07=8'd59;
                8'd32: fixed_gamma07=8'd60;
                8'd33: fixed_gamma07=8'd61;
                8'd34: fixed_gamma07=8'd62;
                8'd35: fixed_gamma07=8'd64;
                8'd36: fixed_gamma07=8'd65;
                8'd37: fixed_gamma07=8'd66;
                8'd38: fixed_gamma07=8'd67;
                8'd39: fixed_gamma07=8'd68;
                8'd40: fixed_gamma07=8'd70;
                8'd41: fixed_gamma07=8'd71;
                8'd42: fixed_gamma07=8'd72;
                8'd43: fixed_gamma07=8'd73;
                8'd44: fixed_gamma07=8'd74;
                8'd45: fixed_gamma07=8'd75;
                8'd46: fixed_gamma07=8'd77;
                8'd47: fixed_gamma07=8'd78;
                8'd48: fixed_gamma07=8'd79;
                8'd49: fixed_gamma07=8'd80;
                8'd50: fixed_gamma07=8'd81;
                8'd51: fixed_gamma07=8'd82;
                8'd52: fixed_gamma07=8'd84;
                8'd53: fixed_gamma07=8'd85;
                8'd54: fixed_gamma07=8'd86;
                8'd55: fixed_gamma07=8'd87;
                8'd56: fixed_gamma07=8'd88;
                8'd57: fixed_gamma07=8'd89;
                8'd58: fixed_gamma07=8'd90;
                8'd59: fixed_gamma07=8'd91;
                8'd60: fixed_gamma07=8'd93;
                8'd61: fixed_gamma07=8'd94;
                8'd62: fixed_gamma07=8'd95;
                8'd63: fixed_gamma07=8'd96;
                8'd64: fixed_gamma07=8'd97;
                8'd65: fixed_gamma07=8'd98;
                8'd66: fixed_gamma07=8'd99;
                8'd67: fixed_gamma07=8'd100;
                8'd68: fixed_gamma07=8'd101;
                8'd69: fixed_gamma07=8'd102;
                8'd70: fixed_gamma07=8'd103;
                8'd71: fixed_gamma07=8'd104;
                8'd72: fixed_gamma07=8'd105;
                8'd73: fixed_gamma07=8'd106;
                8'd74: fixed_gamma07=8'd107;
                8'd75: fixed_gamma07=8'd108;
                8'd76: fixed_gamma07=8'd109;
                8'd77: fixed_gamma07=8'd110;
                8'd78: fixed_gamma07=8'd111;
                8'd79: fixed_gamma07=8'd112;
                8'd80: fixed_gamma07=8'd113;
                8'd81: fixed_gamma07=8'd114;
                8'd82: fixed_gamma07=8'd115;
                8'd83: fixed_gamma07=8'd116;
                8'd84: fixed_gamma07=8'd117;
                8'd85: fixed_gamma07=8'd118;
                8'd86: fixed_gamma07=8'd119;
                8'd87: fixed_gamma07=8'd120;
                8'd88: fixed_gamma07=8'd121;
                8'd89: fixed_gamma07=8'd122;
                8'd90: fixed_gamma07=8'd123;
                8'd91: fixed_gamma07=8'd124;
                8'd92: fixed_gamma07=8'd125;
                8'd93: fixed_gamma07=8'd126;
                8'd94: fixed_gamma07=8'd127;
                8'd95: fixed_gamma07=8'd128;
                8'd96: fixed_gamma07=8'd129;
                8'd97: fixed_gamma07=8'd130;
                8'd98: fixed_gamma07=8'd131;
                8'd99: fixed_gamma07=8'd132;
                8'd100: fixed_gamma07=8'd133;
                8'd101: fixed_gamma07=8'd133;
                8'd102: fixed_gamma07=8'd134;
                8'd103: fixed_gamma07=8'd135;
                8'd104: fixed_gamma07=8'd136;
                8'd105: fixed_gamma07=8'd137;
                8'd106: fixed_gamma07=8'd138;
                8'd107: fixed_gamma07=8'd139;
                8'd108: fixed_gamma07=8'd140;
                8'd109: fixed_gamma07=8'd140;
                8'd110: fixed_gamma07=8'd141;
                8'd111: fixed_gamma07=8'd142;
                8'd112: fixed_gamma07=8'd143;
                8'd113: fixed_gamma07=8'd144;
                8'd114: fixed_gamma07=8'd145;
                8'd115: fixed_gamma07=8'd146;
                8'd116: fixed_gamma07=8'd147;
                8'd117: fixed_gamma07=8'd147;
                8'd118: fixed_gamma07=8'd148;
                8'd119: fixed_gamma07=8'd149;
                8'd120: fixed_gamma07=8'd150;
                8'd121: fixed_gamma07=8'd151;
                8'd122: fixed_gamma07=8'd152;
                8'd123: fixed_gamma07=8'd153;
                8'd124: fixed_gamma07=8'd154;
                8'd125: fixed_gamma07=8'd154;
                8'd126: fixed_gamma07=8'd155;
                8'd127: fixed_gamma07=8'd156;
                8'd128: fixed_gamma07=8'd157;
                8'd129: fixed_gamma07=8'd158;
                8'd130: fixed_gamma07=8'd159;
                8'd131: fixed_gamma07=8'd160;
                8'd132: fixed_gamma07=8'd161;
                8'd133: fixed_gamma07=8'd161;
                8'd134: fixed_gamma07=8'd162;
                8'd135: fixed_gamma07=8'd163;
                8'd136: fixed_gamma07=8'd164;
                8'd137: fixed_gamma07=8'd165;
                8'd138: fixed_gamma07=8'd166;
                8'd139: fixed_gamma07=8'd167;
                8'd140: fixed_gamma07=8'd168;
                8'd141: fixed_gamma07=8'd168;
                8'd142: fixed_gamma07=8'd169;
                8'd143: fixed_gamma07=8'd170;
                8'd144: fixed_gamma07=8'd171;
                8'd145: fixed_gamma07=8'd172;
                8'd146: fixed_gamma07=8'd173;
                8'd147: fixed_gamma07=8'd173;
                8'd148: fixed_gamma07=8'd174;
                8'd149: fixed_gamma07=8'd175;
                8'd150: fixed_gamma07=8'd176;
                8'd151: fixed_gamma07=8'd177;
                8'd152: fixed_gamma07=8'd178;
                8'd153: fixed_gamma07=8'd178;
                8'd154: fixed_gamma07=8'd179;
                8'd155: fixed_gamma07=8'd180;
                8'd156: fixed_gamma07=8'd181;
                8'd157: fixed_gamma07=8'd182;
                8'd158: fixed_gamma07=8'd182;
                8'd159: fixed_gamma07=8'd183;
                8'd160: fixed_gamma07=8'd184;
                8'd161: fixed_gamma07=8'd185;
                8'd162: fixed_gamma07=8'd186;
                8'd163: fixed_gamma07=8'd186;
                8'd164: fixed_gamma07=8'd187;
                8'd165: fixed_gamma07=8'd188;
                8'd166: fixed_gamma07=8'd189;
                8'd167: fixed_gamma07=8'd190;
                8'd168: fixed_gamma07=8'd191;
                8'd169: fixed_gamma07=8'd191;
                8'd170: fixed_gamma07=8'd192;
                8'd171: fixed_gamma07=8'd193;
                8'd172: fixed_gamma07=8'd194;
                8'd173: fixed_gamma07=8'd195;
                8'd174: fixed_gamma07=8'd195;
                8'd175: fixed_gamma07=8'd196;
                8'd176: fixed_gamma07=8'd197;
                8'd177: fixed_gamma07=8'd198;
                8'd178: fixed_gamma07=8'd199;
                8'd179: fixed_gamma07=8'd199;
                8'd180: fixed_gamma07=8'd200;
                8'd181: fixed_gamma07=8'd201;
                8'd182: fixed_gamma07=8'd202;
                8'd183: fixed_gamma07=8'd202;
                8'd184: fixed_gamma07=8'd203;
                8'd185: fixed_gamma07=8'd204;
                8'd186: fixed_gamma07=8'd205;
                8'd187: fixed_gamma07=8'd205;
                8'd188: fixed_gamma07=8'd206;
                8'd189: fixed_gamma07=8'd207;
                8'd190: fixed_gamma07=8'd208;
                8'd191: fixed_gamma07=8'd208;
                8'd192: fixed_gamma07=8'd209;
                8'd193: fixed_gamma07=8'd210;
                8'd194: fixed_gamma07=8'd211;
                8'd195: fixed_gamma07=8'd211;
                8'd196: fixed_gamma07=8'd212;
                8'd197: fixed_gamma07=8'd213;
                8'd198: fixed_gamma07=8'd214;
                8'd199: fixed_gamma07=8'd214;
                8'd200: fixed_gamma07=8'd215;
                8'd201: fixed_gamma07=8'd216;
                8'd202: fixed_gamma07=8'd217;
                8'd203: fixed_gamma07=8'd217;
                8'd204: fixed_gamma07=8'd218;
                8'd205: fixed_gamma07=8'd219;
                8'd206: fixed_gamma07=8'd220;
                8'd207: fixed_gamma07=8'd220;
                8'd208: fixed_gamma07=8'd221;
                8'd209: fixed_gamma07=8'd222;
                8'd210: fixed_gamma07=8'd223;
                8'd211: fixed_gamma07=8'd223;
                8'd212: fixed_gamma07=8'd224;
                8'd213: fixed_gamma07=8'd225;
                8'd214: fixed_gamma07=8'd226;
                8'd215: fixed_gamma07=8'd226;
                8'd216: fixed_gamma07=8'd227;
                8'd217: fixed_gamma07=8'd228;
                8'd218: fixed_gamma07=8'd229;
                8'd219: fixed_gamma07=8'd229;
                8'd220: fixed_gamma07=8'd230;
                8'd221: fixed_gamma07=8'd231;
                8'd222: fixed_gamma07=8'd232;
                8'd223: fixed_gamma07=8'd232;
                8'd224: fixed_gamma07=8'd233;
                8'd225: fixed_gamma07=8'd234;
                8'd226: fixed_gamma07=8'd234;
                8'd227: fixed_gamma07=8'd235;
                8'd228: fixed_gamma07=8'd236;
                8'd229: fixed_gamma07=8'd236;
                8'd230: fixed_gamma07=8'd237;
                8'd231: fixed_gamma07=8'd238;
                8'd232: fixed_gamma07=8'd239;
                8'd233: fixed_gamma07=8'd239;
                8'd234: fixed_gamma07=8'd240;
                8'd235: fixed_gamma07=8'd241;
                8'd236: fixed_gamma07=8'd241;
                8'd237: fixed_gamma07=8'd242;
                8'd238: fixed_gamma07=8'd243;
                8'd239: fixed_gamma07=8'd243;
                8'd240: fixed_gamma07=8'd244;
                8'd241: fixed_gamma07=8'd245;
                8'd242: fixed_gamma07=8'd245;
                8'd243: fixed_gamma07=8'd246;
                8'd244: fixed_gamma07=8'd247;
                8'd245: fixed_gamma07=8'd247;
                8'd246: fixed_gamma07=8'd248;
                8'd247: fixed_gamma07=8'd249;
                8'd248: fixed_gamma07=8'd250;
                8'd249: fixed_gamma07=8'd250;
                8'd250: fixed_gamma07=8'd251;
                8'd251: fixed_gamma07=8'd252;
                8'd252: fixed_gamma07=8'd252;
                8'd253: fixed_gamma07=8'd253;
                8'd254: fixed_gamma07=8'd254;
                8'd255: fixed_gamma07=8'd255;
                default: fixed_gamma07=8'd0;
            endcase
        end
    endfunction

    // Each copy has two synchronous read ports, supplying two RGB lanes.
    // ROM/read-data registers have no reset; O_tvalid masks reset/invalid data.
    // Planning budget: two ERAMs; physical mapping is pending user TD run.
    genvar pair;
    generate for(pair=0;pair<2;pair=pair+1) begin:g_pair
        (* rom_style="bram" *) reg [7:0] table_data[0:255];
        integer address;
        initial for(address=0;address<256;address=address+1)
            table_data[address]=fixed_gamma07(address[7:0]);
        reg [7:0] red_a,red_b;
        reg [15:0] gb_a,gb_b;
        always @(posedge I_clk) red_a<=table_data[I_tdata[pair*48+16+:8]];
        always @(posedge I_clk) red_b<=table_data[I_tdata[pair*48+40+:8]];
        always @(posedge I_clk) begin
            gb_a<=I_tdata[pair*48+:16];
            gb_b<=I_tdata[pair*48+24+:16];
        end
        assign O_tdata[pair*48+:24]=O_tvalid ? {red_a,gb_a}:24'd0;
        assign O_tdata[pair*48+24+:24]=O_tvalid ? {red_b,gb_b}:24'd0;
    end endgenerate
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin O_tlast<=0;O_tuser<=0;O_tvalid<=0;end
        else begin O_tlast<=I_tlast;O_tuser<=I_tuser;O_tvalid<=I_tvalid;end
    end
endmodule
