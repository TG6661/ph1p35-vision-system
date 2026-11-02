// Fixed 720p center ROI x=512..767, y=232..487, all four RGB pixels.
// Counts valid beats (legacy tlast need not be aligned). Accepts early SOF or
// SOF on first valid. A new SOF aborts an unfinished ROI; idle cycles don't count.
module rgb_center_stats(input wire clk,rst_n,sof,valid,input wire [95:0] data,
    output reg [23:0] mean_rgb,output reg done,output reg [7:0] frame_id);
    reg active;
    reg [8:0] x;
    reg [9:0] y;
    reg [23:0] sr,sg,sb;
    wire [8:0] cx=sof ? 9'd0 : x;
    wire [9:0] cy=sof ? 10'd0 : y;
    wire inside_roi=cx>=128 && cx<192 && cy>=232 && cy<488;
    wire [9:0] ar={2'b0,data[95:88]}+{2'b0,data[71:64]}+{2'b0,data[47:40]}+{2'b0,data[23:16]};
    wire [9:0] ag={2'b0,data[87:80]}+{2'b0,data[63:56]}+{2'b0,data[39:32]}+{2'b0,data[15:8]};
    wire [9:0] ab={2'b0,data[79:72]}+{2'b0,data[55:48]}+{2'b0,data[31:24]}+{2'b0,data[7:0]};
    wire [23:0] nr=sr+{14'd0,ar},ng=sg+{14'd0,ag},nb=sb+{14'd0,ab};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin active<=0;x<=0;y<=0;sr<=0;sg<=0;sb<=0;mean_rgb<=0;done<=0;frame_id<=0;end
        else begin
            done<=0;
            if(sof) begin active<=1;x<=0;y<=0;sr<=0;sg<=0;sb<=0;frame_id<=frame_id+1'b1;end
            if(valid && (active || sof)) begin
                if(cx==319) begin x<=0;y<=cy+1'b1;if(cy==719) active<=0;end
                else begin x<=cx+1'b1;y<=cy;end
                if(inside_roi) begin
                    sr<=nr;sg<=ng;sb<=nb;
                    if(cx==191 && cy==487) begin mean_rgb<={nr[23:16],ng[23:16],nb[23:16]};done<=1;end
                end
            end
        end
    end
endmodule
