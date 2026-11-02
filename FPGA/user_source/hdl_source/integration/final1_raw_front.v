module final1_raw_front #(parameter integer IMG_WIDTH=1280,IMG_HEIGHT=720)(
    input I_clk,I_rst_n,input [39:0] I_data,input I_valid,I_user,I_last,
    output [95:0] O_data,output O_valid,O_user,O_last,
    input I_sf_enable, // Camera-domain RED selection, latched at the original RAW SOF.
    input I_blc_enable,input [7:0] I_blc_offset // Coherent camera-domain menu snapshot.
);
    // Common to RED/MOTION/STYLE. Capture on the original RAW SOF, including
    // early SOF; a menu update during the frame must not split the correction.
    reg blc_frame_enable;
    reg [7:0] blc_frame_offset;
    wire blc_enable_now=I_user ? I_blc_enable : blc_frame_enable;
    wire [9:0] blc_offset_now={2'b0,I_user ? I_blc_offset : blc_frame_offset};
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n) begin blc_frame_enable<=1'b1;blc_frame_offset<=8'd32;end
        else if(I_user) begin blc_frame_enable<=I_blc_enable;blc_frame_offset<=I_blc_offset;end
    wire [39:0] corrected;
    genvar p;
    generate for(p=0;p<4;p=p+1) begin:g_blc
        wire [9:0] value=I_data[p*10+:10];
        // One unsigned subtraction supplies both result and borrow.
        // 11 bits cover -255..1023; equality naturally produces zero.
        wire [10:0] difference={1'b0,value}-{1'b0,blc_offset_now};
        assign corrected[p*10+:10]=!blc_enable_now ? value :
            (difference[10] ? 10'd0 : difference[9:0]);
    end endgenerate
    // Keep one shared demosaic: RED uses STRONG; MOTION/STYLE use an aligned
    // bypass. Consequently RED's display background also receives filtered RAW.
    // The sensor can announce SOF before valid pixels. Hold it until the first
    // valid beat, and retain the mode chosen at the original SOF during the gap.
    reg sf_pending_user,sf_frame_enable;
    wire sf_input_user=I_valid && (I_user || sf_pending_user);
    wire sf_enable_now=I_user ? I_sf_enable : sf_frame_enable;
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n) begin sf_pending_user<=0;sf_frame_enable<=0;end
        else begin
            if(I_user) sf_frame_enable<=I_sf_enable;
            if(sf_input_user) sf_pending_user<=0;
            else if(I_user) sf_pending_user<=1;
        end
    wire [39:0] sf_raw;
    wire sf_valid,sf_user,sf_last;
    raw10_same_phase_filter #(.WIDTH(IMG_WIDTH),.FRAME_BYPASS(1)) u_sf(
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_tdata(corrected),
        .I_tvalid(I_valid),.I_tuser(sf_input_user),.I_tlast(I_last),
        .I_mode(sf_enable_now ? 2'd3 : 2'd0),
        .O_tdata(sf_raw),.O_tvalid(sf_valid),.O_tuser(sf_user),.O_tlast(sf_last));
    wire [39:0] delayed_raw;
    wire delayed_valid,delayed_user,delayed_last;
    raw_delay_4px u_raw_delay(I_clk,I_rst_n,sf_raw,sf_valid,sf_user,sf_last,
        delayed_raw,delayed_valid,delayed_user,delayed_last);
    wire [127:0] demosaic_data;
    wire raw_user;
    demosaic #(.IMG_HEIGHT(IMG_HEIGHT),.IMG_WIDTH(IMG_WIDTH),
        .data_complete_delay(50),.BAYER_MODE("BGGR")) u_demosaic(
        .I_clk(I_clk),.I_rst_n(I_rst_n),.axi4s_video_tdata(delayed_raw),.axi4s_video_tdest(10'd0),
        .axi4s_video_tlast(delayed_last),.axi4s_video_tvalid(delayed_valid),.axi4s_video_tuser(delayed_user),
        .axi4s_video_tready(),.O_tlast(O_last),.O_tuser(raw_user),.O_tdata(demosaic_data),
        .O_tvalid(O_valid),.O_tready(1'b1));
    data128_96 u_rgb_order(.I_tdata(demosaic_data),.O_tdata(O_data));
    reg pending_user;
    assign O_user=O_valid && (raw_user || pending_user);
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n) pending_user<=0;
        else if(O_user) pending_user<=0;
        else if(raw_user) pending_user<=1;
endmodule

// Preserve the former frontend latency; no spatial gain or ROM remains.
module raw_delay_4px(input I_clk,I_rst_n,input [39:0] I_raw4,
 input I_valid,I_user,I_last,output [39:0] O_raw4,output O_valid,O_user,O_last);
 reg [39:0] data0,data1,data2;
 reg [2:0] valid_pipe,user_pipe,last_pipe;
 always @(posedge I_clk or negedge I_rst_n)
 if(!I_rst_n)begin data0<=0;data1<=0;data2<=0;valid_pipe<=0;user_pipe<=0;last_pipe<=0;end
 else begin data0<=I_raw4;data1<=data0;data2<=data1;
 valid_pipe<={valid_pipe[1:0],I_valid};user_pipe<={user_pipe[1:0],I_user};last_pipe<={last_pipe[1:0],I_last};end
 assign O_raw4=data2;assign O_valid=valid_pipe[2];assign O_user=user_pipe[2];assign O_last=last_pipe[2];
endmodule

// 连续3个128位字还原4个RGB96字；不改变RGB字节顺序，SOF/EOL重新对齐。
