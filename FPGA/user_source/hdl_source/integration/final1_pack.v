// PIXELS=2时8个48位拍打包为3个128位拍；4时保留原96位接口。空拍保留余数。
module final1_pack #(
    parameter LINE_BEATS = 240, PIXELS=4
)(
    input I_clk, I_rst_n, I_96b_frame_start, I_96b_valid,
    input [PIXELS*24-1:0] I_96b_data,
    output reg O_128b_frame_start, O_128b_last, O_128b_valid,
    output reg [127:0] O_128b_data
);
    generate if(PIXELS==2) begin:g_two
    // Eight RGB pairs form three DDR words. Fixed slices, no barrel shifter.
    reg [111:0] history;
    reg [2:0] phase;
    reg frame_pending;
    reg [15:0] output_x;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            history<=0;phase<=0;frame_pending<=0;output_x<=0;
            O_128b_frame_start<=0;O_128b_last<=0;O_128b_valid<=0;O_128b_data<=0;
        end else begin
            O_128b_frame_start<=0;O_128b_last<=0;O_128b_valid<=0;O_128b_data<=0;
            if(I_96b_valid) begin
                history<={history[63:0],I_96b_data};
                if(I_96b_frame_start) begin phase<=1;frame_pending<=1;output_x<=0;end
                else begin
                    phase<=phase+1'b1;
                    if(phase==2 || phase==5 || phase==7) begin
                        O_128b_valid<=1;O_128b_frame_start<=frame_pending;frame_pending<=0;
                        O_128b_last<=(output_x==LINE_BEATS-1);
                        output_x<=(output_x==LINE_BEATS-1)?0:output_x+1'b1;
                        case(phase)
                            2:O_128b_data<={history[95:0],I_96b_data[47:16]};
                            5:O_128b_data<={history,I_96b_data[47:32]};
                            7:O_128b_data<={history[79:0],I_96b_data};
                        endcase
                    end
                end
            end
        end
    end
    end else begin:g_four
    reg [95:0] previous;
    reg [1:0] phase;
    reg frame_pending;
    reg [15:0] output_x;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            previous<=0; phase<=0; frame_pending<=0; output_x<=0;
            O_128b_frame_start<=0; O_128b_last<=0;
            O_128b_valid<=0; O_128b_data<=0;
        end else begin
            O_128b_frame_start<=0; O_128b_last<=0;
            O_128b_valid<=0; O_128b_data<=0;
            if (I_96b_valid) begin
                previous <= I_96b_data;
                if (I_96b_frame_start) begin
                    // 新帧从第一个96位字重新开始，不沿用旧帧的残留字节。
                    phase<=1; frame_pending<=1; output_x<=0;
                end else begin
                    phase<=phase+1'b1;
                    if (phase!=0) begin
                        O_128b_valid<=1;
                        O_128b_frame_start<=frame_pending;
                        frame_pending<=0;
                        O_128b_last<=(output_x==LINE_BEATS-1);
                        output_x<=(output_x==LINE_BEATS-1)?0:output_x+1'b1;
                        case (phase)
                            1: O_128b_data<={previous,I_96b_data[95:64]};
                            2: O_128b_data<={previous[63:0],I_96b_data[95:32]};
                            3: O_128b_data<={previous[31:0],I_96b_data};
                        endcase
                    end
                end
            end
        end
    end
    end endgenerate
endmodule
