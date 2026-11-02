// User-selected hatch_sketch_core(rgb,8,false,0): single diagonal hatch.
// Gray=floor((R+2G+B)/4); darkest band (<48) is solid black, exactly as MATLAB.
// PIXELS RGB888 pixels per valid clock, highest group is the leftmost pixel.
// Two pipeline registers; SOF/EOL/valid travel with pixels. No RAM or multiplier.
module hatch_sketch_96 #(
    parameter integer IMG_WIDTH=1280, IMG_HEIGHT=720, PIXELS=4,
    parameter integer GROUPS=IMG_WIDTH/PIXELS,
    parameter integer X_BITS=(GROUPS>1)?$clog2(GROUPS):1
)(
    input I_clk,I_rst_n,I_tlast,I_tuser,I_tvalid,
    input [PIXELS*24-1:0] I_tdata,
    output reg O_tlast,O_tuser,O_tvalid,
    output reg [PIXELS*24-1:0] O_tdata
);
    reg [X_BITS-1:0] group_x;
    reg [2:0] line_y;
    reg sof_pending;
    wire sof=I_tvalid && (I_tuser || sof_pending);
    wire [X_BITS-1:0] current_x=sof?{X_BITS{1'b0}}:group_x;
    wire [2:0] current_y=sof?3'd0:line_y;
    wire row_end=I_tlast || current_x==GROUPS-1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin group_x<=0;line_y<=0;sof_pending<=0;end
        else begin
            if(sof) sof_pending<=0;
            else if(I_tuser) sof_pending<=1;
            if(I_tvalid) begin
                if(row_end) begin group_x<=0;line_y<=current_y+3'd1;end
                else begin group_x<=current_x+1'b1;line_y<=current_y;end
            end
        end
    end
    reg valid_d,user_d,last_d;
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n) begin
            valid_d<=0;user_d<=0;last_d<=0;O_tvalid<=0;O_tuser<=0;O_tlast<=0;
        end else begin
            valid_d<=I_tvalid;user_d<=sof;last_d<=I_tlast && I_tvalid;
            O_tvalid<=valid_d;O_tuser<=user_d;O_tlast<=last_d;
        end
    genvar lane;
    generate for(lane=0;lane<PIXELS;lane=lane+1) begin:g_pixel
        wire [23:0] rgb=I_tdata[PIXELS*24-1-24*lane -:24];
        reg [9:0] sum_d;
        reg [2:0] phase_d;
        wire [7:0] gray=sum_d[9:2];
        // x = PIXELS*current_x+lane; only low coordinate bits affect spacing 8.
        wire ink=(gray<8'd224 && phase_d==0) ||
                 (gray<8'd160 && phase_d==4) ||
                 (gray<8'd96 && (phase_d==2 || phase_d==6)) || gray<8'd48;
        always @(posedge I_clk or negedge I_rst_n)
            if(!I_rst_n) begin sum_d<=0;phase_d<=0;O_tdata[PIXELS*24-1-24*lane -:24]<=0;end
            else begin
                sum_d<={2'b0,rgb[23:16]}+{1'b0,rgb[15:8],1'b0}+{2'b0,rgb[7:0]};
                phase_d<=PIXELS*current_x+current_y+lane;
                O_tdata[PIXELS*24-1-24*lane -:24]<=valid_d?(ink?24'h000000:24'hffffff):24'd0;
            end
    end endgenerate
endmodule
