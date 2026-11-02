// Local 3x5 bitmap font, row-major, most significant bit at top left.
module target_osd_font(input wire [7:0] code,input wire [2:0] row,
    input wire [1:0] col,output wire pixel);
    wire [14:0] glyph;
    target_osd_glyph u_glyph(.code(code),.glyph(glyph));
    reg [2:0] row_bits;
    always @* begin
        case(row)
            3'd0:row_bits=glyph[14:12];
            3'd1:row_bits=glyph[11:9];
            3'd2:row_bits=glyph[8:6];
            3'd3:row_bits=glyph[5:3];
            3'd4:row_bits=glyph[2:0];
            default:row_bits=3'b000;
        endcase
    end
    assign pixel=col==2'd0 ?row_bits[2]:col==2'd1 ?row_bits[1]:col==2'd2 ?row_bits[0]:1'b0;
endmodule

// Shared complete-glyph decoder, also used by blanking-time label preparation.
module target_osd_glyph(input wire [7:0] code,output reg [14:0] glyph);
    always @* begin
        case(code)
            "0":glyph=15'b111101101101111; "1":glyph=15'b010110010010111;
            "2":glyph=15'b111001111100111; "3":glyph=15'b111001111001111;
            "4":glyph=15'b101101111001001; "5":glyph=15'b111100111001111;
            "6":glyph=15'b111100111101111; "7":glyph=15'b111001001001001;
            "8":glyph=15'b111101111101111; "9":glyph=15'b111101111001111;
            "A":glyph=15'b010101111101101; "B":glyph=15'b110101110101110;
            "C":glyph=15'b111100100100111; "D":glyph=15'b110101101101110;
            "E":glyph=15'b111100110100111; "F":glyph=15'b111100110100100;
            "G":glyph=15'b111100101101111; "I":glyph=15'b111010010010111;
            "K":glyph=15'b101101110101101; "L":glyph=15'b100100100100111;
            "M":glyph=15'b101111111101101; "P":glyph=15'b110101110100100;
            "N":glyph=15'b101111111111101; "O":glyph=15'b111101101101111;
            "R":glyph=15'b110101110101101; "T":glyph=15'b111010010010010;
            "U":glyph=15'b101101101101111; "W":glyph=15'b101101111111101;
            "X":glyph=15'b101101010101101; "Y":glyph=15'b101101010010010;
            ":":glyph=15'b000010000010000;
            default:glyph=0;
        endcase
    end
endmodule
