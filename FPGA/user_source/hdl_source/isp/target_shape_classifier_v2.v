// Version 2: UNKNOWN=0, RECT_CANDIDATE=1, CIRCLE_CANDIDATE=2.
// Geometry is zero-based inclusive in the fixed 1280x720 image.
// One record at a time. Completion cannot overtake pending classified targets.
module target_shape_classifier_v2 #(parameter ID_WIDTH=8)(
    input wire clk,rst_n,
    input wire s_target_valid,
    output wire s_target_ready,
    input wire [ID_WIDTH-1:0] s_target_id,
    input wire [19:0] s_target_area,
    input wire [10:0] s_target_xmin,s_target_xmax,
    input wire [9:0] s_target_ymin,s_target_ymax,
    input wire s_done_valid,
    output wire s_done_ready,
    input wire [15:0] s_target_count,
    input wire [3:0] s_frame_error,
    output wire target_valid,
    input wire target_ready,
    output reg [ID_WIDTH-1:0] target_id,
    output reg [19:0] target_area,
    output reg [10:0] target_xmin,target_xmax,
    output reg [9:0] target_ymin,target_ymax,
    output reg [1:0] class_id,
    output reg geometry_error,
    output wire done_valid,
    input wire done_ready,
    output reg [15:0] target_count,
    output reg [3:0] frame_error
);
    localparam IDLE=0,BOX=1,SCALE=2,DECIDE=3,EMIT=4,DONE=5;
    reg [2:0] state;
    reg [10:0] width;
    reg [9:0] height;
    reg coords_ok;
    reg [19:0] box_area;
    reg [31:0] area100,box90,box72,box85;
    reg [14:0] width10,height9,height11;
    assign s_target_ready=rst_n && state==IDLE;
    assign s_done_ready=rst_n && state==IDLE && !s_target_valid;
    assign target_valid=rst_n && state==EMIT;
    assign done_valid=rst_n && state==DONE;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; target_id<=0; target_area<=0;
            target_xmin<=0; target_xmax<=0; target_ymin<=0; target_ymax<=0;
            class_id<=0; geometry_error<=0; target_count<=0; frame_error<=0;
            width<=0; height<=0; coords_ok<=0; box_area<=0;
            area100<=0; box90<=0; box72<=0; box85<=0;
            width10<=0; height9<=0; height11<=0;
        end else case(state)
            IDLE: begin
                if(s_target_valid) begin
                    target_id<=s_target_id; target_area<=s_target_area;
                    target_xmin<=s_target_xmin; target_xmax<=s_target_xmax;
                    target_ymin<=s_target_ymin; target_ymax<=s_target_ymax;
                    coords_ok<=s_target_xmin<=s_target_xmax && s_target_ymin<=s_target_ymax &&
                        s_target_xmax<1280 && s_target_ymax<720;
                    // Invalid coordinates are masked before multiplication.
                    if(s_target_xmin<=s_target_xmax && s_target_ymin<=s_target_ymax &&
                       s_target_xmax<1280 && s_target_ymax<720) begin
                        width<=s_target_xmax-s_target_xmin+11'd1;
                        height<=s_target_ymax-s_target_ymin+10'd1;
                    end else begin width<=0; height<=0; end
                    state<=BOX;
                end else if(s_done_valid) begin
                    target_count<=s_target_count; frame_error<=s_frame_error; state<=DONE;
                end
            end
            BOX: begin
                box_area<=width*height;
                width10<=15'd10*width; height9<=15'd9*height; height11<=15'd11*height;
                state<=SCALE;
            end
            SCALE: begin
                area100<=32'd100*target_area;
                box90<=32'd90*box_area; box72<=32'd72*box_area; box85<=32'd85*box_area;
                geometry_error<=!coords_ok || target_area==0 || target_area>box_area;
                state<=DECIDE;
            end
            DECIDE: begin
                class_id<=0;
                if(!geometry_error && width>=8 && height>=8) begin
                    if(area100>=box90) class_id<=1;
                    else if(width10>=height9 && width10<=height11 && area100>=box72 && area100<=box85)
                        class_id<=2;
                end
                state<=EMIT;
            end
            EMIT: if(target_ready) state<=IDLE;
            DONE: if(done_ready) state<=IDLE;
            default: state<=IDLE;
        endcase
    end
endmodule
