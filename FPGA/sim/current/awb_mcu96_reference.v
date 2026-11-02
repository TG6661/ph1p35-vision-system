// MCU AWB：FPGA仅统计原始RGB、在帧首应用MCU系数、执行逐像素乘法。
// 参考式统计：每个完整帧发布最新RGB和/帧计数，不等MCU确认。
// 增益包仍整组跨时钟，在帧首应用；MCU停止时像素流和统计均继续。
module awb_mcu96_reference #(parameter integer IMG_WIDTH=1280,IMG_HEIGHT=720,PIXELS=4)(
    input I_clk,I_rst_n,I_tuser,I_tlast,I_tvalid,input [PIXELS*24-1:0] I_tdata,
    output O_tuser,O_tlast,O_tvalid,output [PIXELS*24-1:0] O_tdata,
    input I_mcu_ready,output reg O_stats_request,
    output reg [191:0] O_stats_payload,
    input I_gain_request,input [71:0] I_gain_payload,output reg O_gain_ack
);
    localparam integer FRAME_BEATS=IMG_WIDTH*IMG_HEIGHT/PIXELS;
    localparam integer COUNT_BITS=(FRAME_BEATS>1)?$clog2(FRAME_BEATS):1;
    // At most one sample per original four-pixel group. Early SOF restarts
    // accumulation; a completed frame closes it until the next SOF. Keep the
    // 32-bit software packet unchanged, but do not store impossible high bits.
    localparam integer MAX_SAMPLES=(PIXELS==4)?FRAME_BEATS:(FRAME_BEATS/2);
    localparam integer SAMPLE_BITS=(MAX_SAMPLES>0)?$clog2(MAX_SAMPLES+1):1;
    localparam integer SUM_BITS=$clog2(MAX_SAMPLES*255+2);
    reg sof_pending,frame_open;
    reg [COUNT_BITS-1:0] beat_count;
    reg [SUM_BITS-1:0] sum_r,sum_g,sum_b;
    reg [SAMPLE_BITS-1:0] sample_count;
    reg [31:0] frame_seq;
    reg request_meta,request_sync,ready_meta,ready_sync;
    reg [1:0] gain_state;
    reg [71:0] pending_gain;
    reg [19:0] active_r,active_b;
    wire sof=I_tvalid && (I_tuser || sof_pending);
    wire [9:0] rgb_sum={2'b0,I_tdata[23:16]}+{2'b0,I_tdata[15:8]}+{2'b0,I_tdata[7:0]};
    wire eligible=(rgb_sum<720) && ((PIXELS==4) || (!sof && beat_count[0])); // 与参考一致：只排除过亮像素，暗像素仍参与统计。
    // 两像素时只在第二对采样；仍取原四像素组最低24位：每行x=3,7,11...；所有行参与，和原AWB相同。
    wire [SUM_BITS-1:0] next_r=(sof?32'd1:sum_r)+(eligible?{24'd0,I_tdata[23:16]}:32'd0);
    wire [SUM_BITS-1:0] next_g=(sof?32'd1:sum_g)+(eligible?{24'd0,I_tdata[15:8]}:32'd0);
    wire [SUM_BITS-1:0] next_b=(sof?32'd1:sum_b)+(eligible?{24'd0,I_tdata[7:0]}:32'd0);
    wire [SAMPLE_BITS-1:0] next_count=(sof?32'd0:sample_count)+(eligible?32'd1:32'd0);
    wire [31:0] packet_r=next_r,packet_g=next_g,packet_b=next_b;
    wire [31:0] packet_count=next_count;
    wire frame_done=I_tvalid && ((sof && FRAME_BEATS==1) ||
        (!sof && frame_open && beat_count==FRAME_BEATS-1));
    wire apply_gain=sof && gain_state==3 && ready_sync;
    // 帧首第一拍也用新系数；未提交/尚未到帧首时，整帧保持旧系数。
    wire [19:0] pixel_r_gain=apply_gain?pending_gain[19:0]:active_r;
    wire [19:0] pixel_b_gain=apply_gain?pending_gain[39:20]:active_b;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            request_meta<=0;request_sync<=0;ready_meta<=0;ready_sync<=0;
        end else begin
            request_meta<=I_gain_request;request_sync<=request_meta;
            ready_meta<=I_mcu_ready;ready_sync<=ready_meta;
        end
    end
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            sof_pending<=0;frame_open<=0;beat_count<=0;sum_r<=1;sum_g<=1;sum_b<=1;sample_count<=0;
            frame_seq<=0;O_stats_payload<=0;O_stats_request<=0;
            gain_state<=0;pending_gain<=0;O_gain_ack<=0;active_r<=95907;active_b<=100825;
        end else begin
            if(I_tuser && !I_tvalid) sof_pending<=1;
            if(I_tvalid) begin
                if(sof) begin sof_pending<=0;frame_open<=1;beat_count<=1;end
                else if(frame_open) beat_count<=beat_count+1'b1;
                if(sof || frame_open) begin
                    sum_r<=next_r;sum_g<=next_g;sum_b<=next_b;sample_count<=next_count;
                end
                if(frame_done) begin
                    frame_open<=0;frame_seq<=frame_seq+1'b1;
                    if(ready_sync) begin
                        // 源端保持到下一帧，接收端同步toggle后锁存整包。
                        // [31:0]R，[63:32]G，[95:64]B，[127:96]样本数，
                        // [159:128]完整帧计数，[191:160]保留0。没有统计ACK/丢包等待。
                        O_stats_payload<={32'd0,frame_seq+32'd1,packet_count,packet_b,packet_g,packet_r};
                        O_stats_request<=!O_stats_request;
                    end
                end
            end
            if(!ready_sync) begin
                O_stats_request<=0;gain_state<=0;O_gain_ack<=request_sync;
                active_r<=95907;active_b<=100825;
            end else case(gain_state)
                0: if(request_sync!=O_gain_ack) gain_state<=1;
                1: gain_state<=2;
                2: begin pending_gain<=I_gain_payload;gain_state<=3;end
                3: if(apply_gain) begin
                    active_r<=pending_gain[19:0];active_b<=pending_gain[39:20];
                    O_gain_ack<=request_sync;gain_state<=0;
                end
            endcase
        end
    end
    reg [27:0] r_product[0:PIXELS-1],b_product[0:PIXELS-1];
    reg [7:0] green_q[0:PIXELS-1];
    reg valid_q,user_q,last_q;
    assign O_tvalid=valid_q;assign O_tuser=user_q;assign O_tlast=last_q;
    genvar p;
    generate for(p=0;p<PIXELS;p=p+1) begin:g_pixel
        assign O_tdata[p*24+16+:8]=valid_q?((|r_product[p][27:24])?8'd255:r_product[p][23:16]):8'd0;
        assign O_tdata[p*24+8+:8]=valid_q?green_q[p]:8'd0;
        assign O_tdata[p*24+:8]=valid_q?((|b_product[p][27:24])?8'd255:b_product[p][23:16]):8'd0;
        always @(posedge I_clk or negedge I_rst_n)
            if(!I_rst_n) begin r_product[p]<=0;b_product[p]<=0;green_q[p]<=0;end
            else if(I_tvalid) begin
                r_product[p]<=I_tdata[p*24+16+:8]*pixel_r_gain;
                b_product[p]<=I_tdata[p*24+:8]*pixel_b_gain;green_q[p]<=I_tdata[p*24+8+:8];
            end
    end endgenerate
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n) begin valid_q<=0;user_q<=0;last_q<=0;end
        else begin valid_q<=I_tvalid;user_q<=sof;last_q<=I_tlast && I_tvalid;end
endmodule
