// 生产为RGB_INPUT_ENABLE=1、MCU_AWB_ENABLE=1、PIXELS=2，接收线性RGB DDR回放。
// 摄像头域保留四像素BLC/LSC/去马赛克；DDR域两像素WB -> GG -> Gamma -> FX -> CL -> pack。
// PIXELS=4兼容旧RAW输入/硬件AWB回归；这两个旧分支不支持两像素输入。
module before_final1_post #(parameter integer IMG_WIDTH=1280,IMG_HEIGHT=720,
    parameter integer RGB_INPUT_ENABLE=0, PIXELS=4, PIX_FIXED_LINE_PERIOD=0, GREEN_GAIN_ENABLE=0, MCU_AWB_ENABLE=0, SERIAL_CL_ENABLE=0)(
    input axi4s_video_aclk,I_rst_n,I_tlast,I_tuser,input I_style_enable,
    input [39:0] I_tdata,input I_tvalid,input [9:0] I_tdest,
    input [1:0] I_mode,I_color_select,input O_tready,
    output [127:0] O_tdata,output O_tlast,O_tuser,O_tvalid,I_tready,
    output [3:0] O_frame_config,output O_cl_overflow,
    input [PIXELS*24-1:0] I_rgb_data,input I_rgb_valid,I_rgb_user,I_rgb_last,input [8:0] I_green_gain,
    input I_awb_mcu_ready,output O_awb_stats_request,output [191:0] O_awb_stats_payload,
    input I_awb_gain_request,input [71:0] I_awb_gain_payload,output O_awb_gain_ack);
    wire [39:0] blc_raw_tdata;
    genvar raw_pixel;
    generate for(raw_pixel=0;raw_pixel<PIXELS;raw_pixel=raw_pixel+1) begin:g_blc
        wire [9:0] v=I_tdata[raw_pixel*10 +: 10];
        assign blc_raw_tdata[raw_pixel*10 +: 10]=(v>10'd32)?v-10'd32:10'd0;
    end endgenerate
    wire [127:0] m_aixs_tdata;
    wire m_aixs_tlast,m_aixs_tuser,m_aixs_tvalid;
    wire [PIXELS*24-1:0] m_aixs_tdata_96;
    generate if(RGB_INPUT_ENABLE==0) begin:g_raw_input
    demosaic #(.IMG_HEIGHT(IMG_HEIGHT),.IMG_WIDTH(IMG_WIDTH),.data_complete_delay(50),.BAYER_MODE("BGGR")) u_demosaic(
        .I_clk(axi4s_video_aclk),.I_rst_n(I_rst_n),.axi4s_video_tdata(blc_raw_tdata),
        .axi4s_video_tdest(I_tdest),.axi4s_video_tlast(I_tlast),.axi4s_video_tvalid(I_tvalid),
        .axi4s_video_tuser(I_tuser),.axi4s_video_tready(I_tready),
        .O_tlast(m_aixs_tlast),.O_tuser(m_aixs_tuser),.O_tdata(m_aixs_tdata),
        .O_tvalid(m_aixs_tvalid),.O_tready(O_tready));
    data128_96 u_data128_96(.I_tdata(m_aixs_tdata),.O_tdata(m_aixs_tdata_96));
    end else begin:g_rgb_input
        assign m_aixs_tdata=128'd0;
        assign m_aixs_tdata_96=I_rgb_data;
        assign m_aixs_tvalid=I_rgb_valid;
        assign m_aixs_tuser=I_rgb_user;
        assign m_aixs_tlast=I_rgb_last;
        assign I_tready=1'b1;
    end endgenerate
    wire [PIXELS*24-1:0] gamma_O_tdata;
    wire gamma_O_tlast,gamma_O_tuser,gamma_O_tvalid;
    wire [PIXELS*24-1:0] awb_tdata;
    wire awb_tlast,awb_tuser,awb_tvalid;
    wire [19:0] awb_r_gain,awb_b_gain;
    // 上板用MCU计算；原硬件AWB仅用于旧算法回归，生成分支不进入上板网表。
    generate if(MCU_AWB_ENABLE) begin:g_mcu_awb
        awb_mcu96 #(.PIXELS(PIXELS),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT)) u_awb_mcu96(
            .I_clk(axi4s_video_aclk),.I_rst_n(I_rst_n),
            .I_tlast(m_aixs_tlast),.I_tuser(m_aixs_tuser),.I_tvalid(m_aixs_tvalid),.I_tdata(m_aixs_tdata_96),
            .O_tlast(awb_tlast),.O_tuser(awb_tuser),.O_tvalid(awb_tvalid),.O_tdata(awb_tdata),
            .I_mcu_ready(I_awb_mcu_ready),
            .O_stats_request(O_awb_stats_request),.O_stats_payload(O_awb_stats_payload),
            .I_gain_request(I_awb_gain_request),.I_gain_payload(I_awb_gain_payload),.O_gain_ack(O_awb_gain_ack));
        assign awb_r_gain=20'd0;assign awb_b_gain=20'd0;
    end else begin:g_legacy_awb
    awb_frame96 #(.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT)) u_awb_frame96(
        .I_clk(axi4s_video_aclk),.I_rst_n(I_rst_n),
        .I_tlast(m_aixs_tlast),.I_tuser(m_aixs_tuser),.I_tvalid(m_aixs_tvalid),.I_tdata(m_aixs_tdata_96),
        .O_tlast(awb_tlast),.O_tuser(awb_tuser),.O_tvalid(awb_tvalid),.O_tdata(awb_tdata),
        .O_r_gain(awb_r_gain),.O_b_gain(awb_b_gain));
        assign O_awb_stats_request=1'b0;assign O_awb_stats_payload=192'd0;assign O_awb_gain_ack=1'b0;
    end endgenerate
    // STYLE中心减绿位于统计之后；RED/MOTION保持原增益像素语义。
    wire [PIXELS*24-1:0] corrected_tdata;wire corrected_tvalid,corrected_tuser,corrected_tlast;
    generate if(GREEN_GAIN_ENABLE) begin:g_green_gain
        green_gain96 #(.PIXELS(PIXELS),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT)) u_green_gain(.I_clk(axi4s_video_aclk),.I_rst_n(I_rst_n),
            .I_tdata(awb_tdata),.I_tvalid(awb_tvalid),.I_tuser(awb_tuser),.I_tlast(awb_tlast),.I_gain(I_green_gain),.I_style_enable(I_style_enable),
            .O_tdata(corrected_tdata),.O_tvalid(corrected_tvalid),.O_tuser(corrected_tuser),.O_tlast(corrected_tlast));
    end else begin:g_no_green_gain
        assign corrected_tdata=awb_tdata;assign corrected_tvalid=awb_tvalid;
        assign corrected_tuser=awb_tuser;assign corrected_tlast=awb_tlast;
    end endgenerate
    // Select the exact curve inside a shared per-channel table. Both old paths
    // had one registered cycle; frame mode is stable while post is running.
    before_final1_mode_gamma96 #(.PIXELS(PIXELS)) u_mode_gamma(.clk(axi4s_video_aclk),.rst_n(I_rst_n),.style(I_style_enable),
        .data(corrected_tdata),.valid(corrected_tvalid),.user(corrected_tuser),.last(corrected_tlast),
        .out_data(gamma_O_tdata),.out_valid(gamma_O_tvalid),.out_user(gamma_O_tuser),.out_last(gamma_O_tlast));
    // Normalize an early SOF to the first valid RGB group.
    reg style_frame_pending;
    wire style_tuser=gamma_O_tvalid && (gamma_O_tuser || style_frame_pending);
    wire [PIXELS*24-1:0] style_tdata=gamma_O_tdata;
    wire style_tvalid=gamma_O_tvalid,style_tlast=gamma_O_tlast;
    always @(posedge axi4s_video_aclk or negedge I_rst_n)
        if(!I_rst_n) style_frame_pending<=0;
        else if(style_tuser) style_frame_pending<=0;
        else if(gamma_O_tuser) style_frame_pending<=1;
    // FX与CL跨时钟一起稳定采样，输入帧首保存请求，输出帧首统一应用。
    reg [3:0] cfg_meta,cfg_sync,cfg_d,cfg_stable,frame_request;
    reg [1:0] mode_active;
    always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
        if(!I_rst_n) begin cfg_meta<=0;cfg_sync<=0;cfg_d<=0;cfg_stable<=0;frame_request<=0;end
        else begin
            cfg_meta<={I_mode,I_color_select};cfg_sync<=cfg_meta;cfg_d<=cfg_sync;
            if(cfg_sync==cfg_d) cfg_stable<={cfg_sync[3:2],(cfg_sync[1:0]<=2)?cfg_sync[1:0]:2'd0};
            if(style_tuser) frame_request<=cfg_stable;
        end
    end
    wire [PIXELS*24-1:0] cartoon_out_tdata,pixel_out_tdata;
    wire cartoon_out_tlast,cartoon_out_tuser,cartoon_out_tvalid;
    wire pixel_out_tlast,pixel_out_tuser,pixel_out_tvalid;
    wire [PIXELS*24-1:0] hatch_out_tdata;
    wire hatch_out_tlast,hatch_out_tuser,hatch_out_tvalid;
    hatch_sketch_96 #(.PIXELS(PIXELS),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT)) u_hatch_sketch_96(
        .I_clk(axi4s_video_aclk),.I_rst_n(I_rst_n),.I_tlast(style_tlast),.I_tuser(style_tuser),
        .I_tdata(style_tdata),.I_tvalid(style_tvalid),
        .O_tlast(hatch_out_tlast),.O_tuser(hatch_out_tuser),.O_tdata(hatch_out_tdata),.O_tvalid(hatch_out_tvalid));
    cartoon_96 #(.PIXELS(PIXELS),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT)) u_cartoon_96(
        .I_clk(axi4s_video_aclk),.I_rst_n(I_rst_n),.I_tlast(style_tlast),.I_tuser(style_tuser),
        .I_tdata(style_tdata),.I_tvalid(style_tvalid),.I_tready(1'b1),
        .O_tlast(cartoon_out_tlast),.O_tuser(cartoon_out_tuser),.O_tdata(cartoon_out_tdata),
        .O_tvalid(cartoon_out_tvalid),.O_tready());
    pixel_art_96 #(.PIXELS(PIXELS),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT),
        .FIXED_LINE_PERIOD(PIX_FIXED_LINE_PERIOD)) u_pixel_art_96(
        .I_clk(axi4s_video_aclk),.I_rst_n(I_rst_n),.I_tlast(style_tlast),.I_tuser(style_tuser),
        .I_tdata(style_tdata),.I_tvalid(style_tvalid),.I_tready(1'b1),
        .O_tlast(pixel_out_tlast),.O_tuser(pixel_out_tuser),.O_tdata(pixel_out_tdata),
        .O_tvalid(pixel_out_tvalid),.O_tready());
    wire [PIXELS*24-1:0] edge_O_tdata;
    wire edge_O_tvalid,edge_O_tuser,edge_O_tlast;
 // 输出帧选择器：先送完当前帧，再等待请求分支的SOF。
 // 像素画输出比输入晚8行；不能在输入SOF直接截断正在输出的旧帧。
 // 若新分支的SOF早于旧帧结束，该新帧整体跳过，等待它的下一个SOF。
 localparam integer FRAME_WORDS=IMG_WIDTH*IMG_HEIGHT/PIXELS;
 localparam integer FRAME_COUNT_BITS=(FRAME_WORDS>1)?$clog2(FRAME_WORDS):1;
 reg frame_output_open;
 reg [FRAME_COUNT_BITS-1:0] frame_output_count;
 wire [1:0] request_mode=style_tuser?cfg_stable[3:2]:frame_request[3:2];
 wire [1:0] request_color=style_tuser?cfg_stable[1:0]:frame_request[1:0];
 wire request_valid=(request_mode==1)?cartoon_out_tvalid:
                    (request_mode==2)?pixel_out_tvalid:
                    (request_mode==3)?hatch_out_tvalid:style_tvalid;
 wire request_user=(request_mode==1)?cartoon_out_tuser:
                   (request_mode==2)?pixel_out_tuser:
                   (request_mode==3)?hatch_out_tuser:style_tuser;
 wire start_output_frame=!frame_output_open && request_valid && request_user;
 // SOF所在的第一拍即选择新分支，避免寄存器更新晚一拍漏掉首个像素。
 wire [1:0] output_mode=start_output_frame?request_mode:mode_active;
 wire mux_valid=(output_mode==1)?cartoon_out_tvalid:
                (output_mode==2)?pixel_out_tvalid:
                (output_mode==3)?hatch_out_tvalid:style_tvalid;
 wire mux_last=(output_mode==1)?cartoon_out_tlast:
               (output_mode==2)?pixel_out_tlast:
               (output_mode==3)?hatch_out_tlast:style_tlast;
 assign edge_O_tdata=(output_mode==1)?cartoon_out_tdata:
                     (output_mode==2)?pixel_out_tdata:
                     (output_mode==3)?hatch_out_tdata:style_tdata;
 assign edge_O_tvalid=mux_valid && (frame_output_open || start_output_frame);
 assign edge_O_tuser=start_output_frame;
 assign edge_O_tlast=mux_last && edge_O_tvalid;
 always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
    if(!I_rst_n) begin
       mode_active<=0;frame_output_open<=0;frame_output_count<=0;
    end else if(edge_O_tvalid) begin
       if(start_output_frame) begin
          mode_active<=request_mode;
          
          frame_output_open<=(FRAME_WORDS>1);
          frame_output_count<=(FRAME_WORDS>1)?1:0;
       end else if(frame_output_count==FRAME_WORDS-1) begin
          frame_output_open<=0;frame_output_count<=0;
       end else frame_output_count<=frame_output_count+1'b1;
    end
 end
 // Production FX already emits pairs, so CL needs neither a queue nor repacking.
 // Legacy four-pixel serialization remains available for regression only.
 reg [1:0] color_active;
 wire [1:0] color_for_frame=start_output_frame?request_color:color_active;
 wire [1:0] cl_selection=(color_for_frame==1)?2'd0:((color_for_frame==2)?2'd1:2'd3);
 wire [PIXELS*24-1:0] color_tdata;
 wire color_tvalid,color_tuser,color_tlast;
 wire [3:0] color_output_config;
 generate if(SERIAL_CL_ENABLE && PIXELS==4) begin:g_serial_cl
  before_final1_color_serial u_serial(.clk(axi4s_video_aclk),.rst_n(I_rst_n),
   .data(edge_O_tdata),.valid(edge_O_tvalid),.user(edge_O_tuser),.last(edge_O_tlast),
   .config_tag({output_mode,color_for_frame}),.out_data(color_tdata),
   .out_valid(color_tvalid),.out_user(color_tuser),.out_last(color_tlast),
   .out_config(color_output_config),.overflow(O_cl_overflow));
 end else begin:g_parallel_cl
  before_color_select_96 #(.PIXELS(PIXELS),.COLOR0_H_CENTER_X2(360),.COLOR1_H_CENTER_X2(720),.H_WIDTH_X2(360),.COLD_SENSITIVITY_ENABLE(1)) u_color_select_96(
   .I_clk(axi4s_video_aclk),.I_rst_n(I_rst_n),.I_tlast(edge_O_tlast),.I_tuser(edge_O_tuser),
   .I_tdata(edge_O_tdata),.I_tvalid(edge_O_tvalid),.I_tready(1'b1),.I_color_sel(cl_selection),.I_cold_sensitivity(4'd0),
   .O_tlast(color_tlast),.O_tuser(color_tuser),.O_tdata(color_tdata),.O_tvalid(color_tvalid),.O_tready());
  reg [3:0] color_config_pipe[0:1];
  integer config_stage;
  always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
   if(!I_rst_n) begin
    for(config_stage=0;config_stage<2;config_stage=config_stage+1) color_config_pipe[config_stage]<=0;
   end else begin
    color_config_pipe[0]<={output_mode,color_for_frame};
    for(config_stage=1;config_stage<2;config_stage=config_stage+1) color_config_pipe[config_stage]<=color_config_pipe[config_stage-1];
   end
  end
  assign color_output_config=color_config_pipe[1];
  assign O_cl_overflow=1'b0;
 end endgenerate
 reg [3:0] packed_frame_config;
 always @(posedge axi4s_video_aclk or negedge I_rst_n) begin
  if(!I_rst_n) begin color_active<=0;packed_frame_config<=0;end
  else begin
   if(start_output_frame) color_active<=request_color;
   if(color_tvalid && color_tuser) packed_frame_config<=color_output_config;
  end
 end
 assign O_frame_config=packed_frame_config;
    final1_pack #(.PIXELS(PIXELS),.LINE_BEATS(IMG_WIDTH*3/16)) u_final1_pack(
        .I_clk(axi4s_video_aclk),.I_rst_n(I_rst_n),.I_96b_frame_start(color_tuser),
        .I_96b_valid(color_tvalid),.I_96b_data(color_tdata),
        .O_128b_frame_start(O_tuser),.O_128b_last(O_tlast),.O_128b_valid(O_tvalid),.O_128b_data(O_tdata));
endmodule

// CL definitions live with their caller so stale TD source lists cannot omit them.
// Four-pixel burst input -> ERAM queue -> two CL lanes -> four-pixel output.
// Legacy adapter only: input must supply <=320 words/row, rows >=1024 clocks.
// A continuous 320-word row adds at most 162 queued words (including startup).
// The 256-entry queue also carries frame configuration and SOF/EOL. Arbitrary
// sustained four-pixel input is NOT supported; overflow is a sticky diagnostic.
module before_final1_color_serial # (parameter ADDR_BITS=8)(
 input clk,rst_n,input [95:0] data,input valid,user,last,input [3:0] config_tag,
 output reg [95:0] out_data,output reg out_valid,out_user,out_last,
 output reg [3:0] out_config,output reg overflow
);
 localparam DEPTH=1<<ADDR_BITS;
 reg [ADDR_BITS-1:0] wr_ptr,rd_ptr;
 reg [ADDR_BITS:0] count;
 reg read_pending,second;
 reg [47:0] lower;
 reg lower_last;
 reg [3:0] lower_config;
 wire pop=(count!=0) && !read_pending;
 wire push=valid && count<DEPTH;
 wire [101:0] q;
 isp_line_ram #(.DATA_WIDTH_A(102),.DATA_WIDTH_B(102),
  .ADDR_WIDTH_A(ADDR_BITS),.ADDR_WIDTH_B(ADDR_BITS),
  .DATA_DEPTH_A(DEPTH),.DATA_DEPTH_B(DEPTH),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
  .WRITEMODE_A("NORMAL"),.WRITEMODE_B("READBEFOREWRITE")) u_queue_eram(
  .clka(clk),.wea(push),.addra(wr_ptr),.dia({config_tag,user,last,data}),.doa(),
  .clkb(clk),.web(1'b0),.addrb(rd_ptr),.dib(102'd0),.dob(q));
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   wr_ptr<=0;rd_ptr<=0;count<=0;read_pending<=0;second<=0;
   lower<=0;lower_last<=0;lower_config<=0;overflow<=0;
  end else begin
   if(valid && !push) overflow<=1;
   if(push) wr_ptr<=wr_ptr+1'b1;
   if(pop) rd_ptr<=rd_ptr+1'b1;
   case({push,pop})
    2'b10:count<=count+1'b1;
    2'b01:count<=count-1'b1;
    default:count<=count;
   endcase
   read_pending<=pop;
   second<=read_pending;
   if(read_pending) begin lower<=q[47:0];lower_last<=q[96];lower_config<=q[101:98];end
  end
 end
 wire half_valid=read_pending || second;
 wire [47:0] half_data=read_pending?q[95:48]:lower;
 wire [3:0] half_config=read_pending?q[101:98]:lower_config;
 wire [1:0] selection=(half_config[1:0]==1)?2'd0:((half_config[1:0]==2)?2'd1:2'd3);
 wire [47:0] cl_data;
 wire cl_valid,cl_user,cl_last;
 before_color_select_96 #(.PIXELS(2),.COLOR0_H_CENTER_X2(360),.COLOR1_H_CENTER_X2(720),.H_WIDTH_X2(360),.COLD_SENSITIVITY_ENABLE(1)) u_cl2(
  .I_clk(clk),.I_rst_n(rst_n),.I_tdata(half_data),.I_tvalid(half_valid),
  .I_tuser(read_pending && q[97]),.I_tlast(second && lower_last),
  .I_color_sel(selection),.I_cold_sensitivity(4'd0),.I_tready(1'b1),.O_tdata(cl_data),.O_tvalid(cl_valid),
  .O_tuser(cl_user),.O_tlast(cl_last),.O_tready());
 // This delay follows the CL core, not wall-clock time spent in the queue.
 reg [3:0] config_pipe[0:1];
 reg have_upper,saved_user;
 reg [47:0] upper;
 reg [3:0] saved_config;
 integer i;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   for(i=0;i<2;i=i+1) config_pipe[i]<=0;
   have_upper<=0;saved_user<=0;upper<=0;saved_config<=0;
   out_data<=0;out_valid<=0;out_user<=0;out_last<=0;out_config<=0;
  end else begin
   config_pipe[0]<=half_config;
   for(i=1;i<2;i=i+1) config_pipe[i]<=config_pipe[i-1];
   out_valid<=0;out_user<=0;out_last<=0;
   if(cl_valid) begin
    have_upper<=!have_upper;
    if(!have_upper) begin upper<=cl_data;saved_user<=cl_user;saved_config<=config_pipe[1];end
    else begin
     out_data<={upper,cl_data};out_valid<=1;out_user<=saved_user;
     out_last<=cl_last;out_config<=saved_config;
    end
   end
  end
 end
endmodule

// 冷暖选色：每拍并行处理4个RGB888像素，固定两拍延迟。
// CLD/WRM命中像素先增强约12.5%饱和度，再提亮1.125倍；未命中仍为原加权灰度。
// ALL逐位透传；主通路冷色固定CS0/T=16、蓝/绿相对红色判定；暖色沿用亮度相关门限。
// 模块内部模式：0=冷色（蓝/青），1=暖色（红/黄），3=全彩，2也按原色透传。
// 上层界面的0=ALL、1=CLD、2=WRM，由isp_top先转换成这里的模式编号。
// 第1拍判色/灰度/饱和度，第2拍亮度增益/输出，帧首锁存和两拍接口不变。

module before_color_select_96 #(
    parameter integer PIXELS = 4,
    // 兼容旧实例的参数接口；本版RGB判据不引用这些HSV/软过渡参数。
    // SOFT_TRANSITION即使设为1也不会启用软过渡；删除未使用参数不会节省硬件。
    parameter integer COLOR0_H_CENTER_X2 = 240,
    parameter integer COLOR1_H_CENTER_X2 = 480,
    parameter integer COLOR2_H_CENTER_X2 = 720,
    parameter integer H_WIDTH_X2         = 180,
    parameter integer S_MIN_X2           = 24,
    parameter integer V_MIN_X2           = 24,
    parameter integer SOFT_TRANSITION    = 1,
    parameter integer SOFT_H_STEP_X2     = 6,
    parameter integer SOFT_S_STEP_X2     = 4,
    parameter integer SOFT_V_STEP_X2     = 4,
    parameter integer FIXED_COLD_WARM_OPT = 1,
    parameter integer ENHANCE_SELECTED = 1,
    parameter integer COLD_SENSITIVITY_ENABLE = 0, // production ISP enables the fixed strict cold rule
    // 编译期选色门限：T=clamp(Y>>3,6,14)；降低暗部漏选，最低6限制小色差噪声。
    // 亮度用增强前已计算的Y，不添加亮度下限，不计算HSV或自适应统计。
    parameter integer LUMA_DIFF_ENABLE = 1, // 0仅用于历史固定14/8位回绕回归
    parameter integer COLOR_DIFF_MIN = 6,
    parameter integer COLOR_DIFF_MAX = 14,
    parameter integer COLOR_DIFF_LUMA_SHIFT = 3
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [PIXELS*24-1:0] I_tdata, // 从高到低为像素0~3，每个像素依次为R、G、B
    input  wire        I_tvalid,
    input  wire        I_tready,
    input wire [3:0] I_cold_sensitivity,
    input  wire [1:0]  I_color_sel, // 3=全彩，0=冷色，1=暖色；一帧内固定

    output reg         O_tlast,
    output reg         O_tuser,
    output reg  [PIXELS*24-1:0] O_tdata,
    output reg         O_tvalid,
    output wire        O_tready
);

    // ready仅透传；内部寄存器每拍推进，不支持通过ready暂停流水线。
    // 当前上层将I_tready固定为1；若接入可反压链路，需要同时改数据/控制推进规则。
    assign O_tready = I_tready;

    // Csat=clip(C+floor((C-Y)/8))。先显式扩展为有符号数，避免负差变成大正数。
    // 10位足以表示保守范围-32..286，之后钳位到8位；移位为常量，不推导通用乘法器。
    function [7:0] saturate_channel(input [7:0] channel,input [7:0] gray_value);
        reg signed [8:0] difference;
        reg signed [9:0] adjusted;
        begin
            difference=$signed({1'b0,channel})-$signed({1'b0,gray_value});
            adjusted=$signed({2'b0,channel})+($signed({difference[8],difference}) >>> 3);
            saturate_channel=adjusted[9]?8'd0:(adjusted[8]?8'd255:adjusted[7:0]);
        end
    endfunction
    // Cbright=clip(Csat+floor(Csat/8))。9位防溢出；超过255时饱和而非回绕。
    function [7:0] brighten_channel(input [7:0] channel);
        reg [8:0] boosted;
        begin
            boosted={1'b0,channel}+{4'd0,channel[7:3]};
            brighten_channel=boosted[8]?8'd255:boosted[7:0];
        end
    endfunction

    reg [1:0] color_active;
    reg       sof_pending;
        // 帧首可早于有效数据到来：先记住tuser，等首个有效像素组再应用新选色模式。
    // 首组直接使用I_color_sel，避免color_active的非阻塞赋值造成首组仍用旧模式。
    wire      sof = I_tvalid && (I_tuser || sof_pending);
    wire [4:0] cold_threshold=5'd16; // fixed CS0; compatibility input is ignored
    wire [1:0] current_sel = sof ? I_color_sel : color_active;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            color_active <= 2'd3;
            sof_pending  <= 1'b0;
        end else begin
            if (sof) begin
                color_active <= I_color_sel;
                sof_pending  <= 1'b0;
            end else if (I_tuser) begin
                sof_pending  <= 1'b1;
            end
        end
    end

    // 第1拍：复用已有灰度，完成判色和饱和度；仅增加每像素一个增强标志。
    // 数据、valid、帧首user、行末last必须保持同拍对应；空拍仍会经过寄存器。
    reg [PIXELS*24-1:0] s1_data;
    reg        s1_valid, s1_user, s1_last;
    reg [PIXELS-1:0] s1_enhance;

    integer p;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            s1_valid   <= 1'b0;
            s1_user    <= 1'b0;
            s1_last    <= 1'b0;
            s1_data    <= 96'd0;
            s1_enhance <= 4'd0;
        end else begin
            s1_valid <= I_tvalid;
            s1_user  <= I_tuser;
            s1_last  <= I_tlast;

            for (p = 0; p < PIXELS; p = p + 1) begin
                begin : calc_metric
                    reg [7:0] pr, pg, pb;
                    reg [7:0] gray, luma_scaled, color_diff;
                    reg is_warm, is_cold, keep_color;
                    pr = I_tdata[PIXELS*24-1-24*p -: 8];
                    pg = I_tdata[PIXELS*24-9-24*p -: 8];
                    pb = I_tdata[PIXELS*24-17-24*p -: 8];

                    // 灰度=floor(R/4)+floor(G/2)+floor(B/4)，只需移位和加法。
                    // 各通道先截断，和floor((R+2G+B)/4)并不完全相同；白色结果为253。
                    gray = {2'b00, pr[7:2]} + {1'b0, pg[7:1]} + {2'b00, pb[7:2]};

                    // T随亮度变化，复用本像素的Y；默认Y<=55时T=6，Y>=112时T=14。
                    // 编译期参数范围：0<=MIN<=MAX<=255，0<=SHIFT<=7。
                    luma_scaled=gray >> COLOR_DIFF_LUMA_SHIFT;
                    color_diff=(luma_scaled<COLOR_DIFF_MIN)?COLOR_DIFF_MIN:
                               ((luma_scaled>COLOR_DIFF_MAX)?COLOR_DIFF_MAX:luma_scaled);
                    if(LUMA_DIFF_ENABLE)begin
                        // +T先扩到9位，禁止高亮回绕；暖色第二条件保持原式。
                        is_warm=({1'b0,pr}>{1'b0,pb}+{1'b0,color_diff}) &&
                                ({1'b0,pr}+{1'b0,pg}>{pb,1'b0});
                        // 以下冷色公式仅供COLD_SENSITIVITY_ENABLE=0历史回归；主通路在后面覆盖。
                        // B+16>R的青色辅助条件不变，不另加亮度/饱和度下限。
                        is_cold=({1'b0,pb}>{1'b0,pr}+{1'b0,color_diff}) ||
                                (({1'b0,pg}>{1'b0,pr}+{1'b0,color_diff}) &&
                                 ({1'b0,pb}+9'd16>{1'b0,pr}));
                    end else begin
                        // 历史回归专用：固定14并保留原8位加法回绕。
                        is_warm=(pr>(pb+8'd14))&&({1'b0,pr}+{1'b0,pg}>{pb,1'b0});
                        is_cold=(pb>(pr+8'd14))||((pg>(pr+8'd14))&&({1'b0,pb}+9'd16>{1'b0,pr}));
                    end
                    if(COLD_SENSITIVITY_ENABLE)begin
                        // Single threshold for blue/green; strict > excludes all neutral grays.
                        is_cold=({1'b0,pb}>{1'b0,pr}+{4'd0,cold_threshold}) ||
                                ({1'b0,pg}>{1'b0,pr}+{4'd0,cold_threshold});
                    end
                    keep_color = (current_sel == 2'd0) ? is_cold :
                                 (current_sel == 2'd1) ? is_warm : 1'b1;
                    s1_enhance[p] <= ENHANCE_SELECTED && current_sel<2 && keep_color;
                    if(ENHANCE_SELECTED && current_sel<2 && keep_color)
                        s1_data[PIXELS*24-1-24*p -: 24] <= {saturate_channel(pr,gray),
                            saturate_channel(pg,gray),saturate_channel(pb,gray)};
                    else s1_data[PIXELS*24-1-24*p -: 24] <= keep_color ? {pr,pg,pb} : {gray,gray,gray};
                end
            end
        end
    end

    integer q;
    // 第2拍：只为上拍命中像素做1.125倍增益，ALL和未命中灰度不增强。
    // ALL也经过这两拍，保证切换模式时的延迟和帧标记一致。
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_tvalid <= 1'b0;
            O_tuser  <= 1'b0;
            O_tlast  <= 1'b0;
            O_tdata  <= 96'd0;
        end else begin
            O_tvalid <= s1_valid;
            O_tuser  <= s1_user;
            O_tlast  <= s1_last;

            for(q=0;q<PIXELS;q=q+1) begin
                if(s1_enhance[q])
                    O_tdata[PIXELS*24-1-24*q-:24] <= {brighten_channel(s1_data[PIXELS*24-1-24*q-:8]),
                        brighten_channel(s1_data[PIXELS*24-9-24*q-:8]),brighten_channel(s1_data[PIXELS*24-17-24*q-:8])};
                else O_tdata[PIXELS*24-1-24*q-:24] <= s1_data[PIXELS*24-1-24*q-:24];
            end
        end
    end

endmodule


// BEGIN GENERATED MODE GAMMA
// Exact 512-entry table, paired synchronous read ports per ROM.
// PIXELS=2 requests three dual-read BRAMs using TD rom_style="bram".
// Confirm actual mapping in TD: a source directive is not an area measurement.
// USE_ERAM=0 retains the logic implementation for isolated A/B comparison.
// One registered cycle, same valid/user/last and invalid zero as both originals.
// I_style is stable for the complete frame; runtime drains/resets on mode change.
module before_final1_mode_gamma96 #(parameter PIXELS=4, USE_ERAM=1)(input clk,rst_n,style,valid,user,last,
    input [PIXELS*24-1:0] data,output wire [PIXELS*24-1:0] out_data,
    output reg out_valid,out_user,out_last);
    function [7:0] map;
        input [8:0] address;
        begin case(address)
            9'd0: map=8'd0;
            9'd1: map=8'd2;
            9'd2: map=8'd5;
            9'd3: map=8'd7;
            9'd4: map=8'd9;
            9'd5: map=8'd12;
            9'd6: map=8'd14;
            9'd7: map=8'd16;
            9'd8: map=8'd19;
            9'd9: map=8'd21;
            9'd10: map=8'd23;
            9'd11: map=8'd25;
            9'd12: map=8'd28;
            9'd13: map=8'd30;
            9'd14: map=8'd32;
            9'd15: map=8'd35;
            9'd16: map=8'd37;
            9'd17: map=8'd38;
            9'd18: map=8'd40;
            9'd19: map=8'd41;
            9'd20: map=8'd43;
            9'd21: map=8'd44;
            9'd22: map=8'd46;
            9'd23: map=8'd47;
            9'd24: map=8'd49;
            9'd25: map=8'd50;
            9'd26: map=8'd51;
            9'd27: map=8'd53;
            9'd28: map=8'd54;
            9'd29: map=8'd56;
            9'd30: map=8'd57;
            9'd31: map=8'd59;
            9'd32: map=8'd60;
            9'd33: map=8'd61;
            9'd34: map=8'd62;
            9'd35: map=8'd64;
            9'd36: map=8'd65;
            9'd37: map=8'd66;
            9'd38: map=8'd67;
            9'd39: map=8'd68;
            9'd40: map=8'd70;
            9'd41: map=8'd71;
            9'd42: map=8'd72;
            9'd43: map=8'd73;
            9'd44: map=8'd74;
            9'd45: map=8'd75;
            9'd46: map=8'd77;
            9'd47: map=8'd78;
            9'd48: map=8'd79;
            9'd49: map=8'd80;
            9'd50: map=8'd81;
            9'd51: map=8'd82;
            9'd52: map=8'd84;
            9'd53: map=8'd85;
            9'd54: map=8'd86;
            9'd55: map=8'd87;
            9'd56: map=8'd88;
            9'd57: map=8'd89;
            9'd58: map=8'd90;
            9'd59: map=8'd91;
            9'd60: map=8'd93;
            9'd61: map=8'd94;
            9'd62: map=8'd95;
            9'd63: map=8'd96;
            9'd64: map=8'd97;
            9'd65: map=8'd98;
            9'd66: map=8'd99;
            9'd67: map=8'd100;
            9'd68: map=8'd101;
            9'd69: map=8'd102;
            9'd70: map=8'd103;
            9'd71: map=8'd104;
            9'd72: map=8'd105;
            9'd73: map=8'd106;
            9'd74: map=8'd107;
            9'd75: map=8'd108;
            9'd76: map=8'd109;
            9'd77: map=8'd110;
            9'd78: map=8'd111;
            9'd79: map=8'd112;
            9'd80: map=8'd113;
            9'd81: map=8'd114;
            9'd82: map=8'd115;
            9'd83: map=8'd116;
            9'd84: map=8'd117;
            9'd85: map=8'd118;
            9'd86: map=8'd119;
            9'd87: map=8'd120;
            9'd88: map=8'd121;
            9'd89: map=8'd122;
            9'd90: map=8'd123;
            9'd91: map=8'd124;
            9'd92: map=8'd125;
            9'd93: map=8'd126;
            9'd94: map=8'd127;
            9'd95: map=8'd128;
            9'd96: map=8'd129;
            9'd97: map=8'd130;
            9'd98: map=8'd131;
            9'd99: map=8'd132;
            9'd100: map=8'd133;
            9'd101: map=8'd133;
            9'd102: map=8'd134;
            9'd103: map=8'd135;
            9'd104: map=8'd136;
            9'd105: map=8'd137;
            9'd106: map=8'd138;
            9'd107: map=8'd139;
            9'd108: map=8'd140;
            9'd109: map=8'd140;
            9'd110: map=8'd141;
            9'd111: map=8'd142;
            9'd112: map=8'd143;
            9'd113: map=8'd144;
            9'd114: map=8'd145;
            9'd115: map=8'd146;
            9'd116: map=8'd147;
            9'd117: map=8'd147;
            9'd118: map=8'd148;
            9'd119: map=8'd149;
            9'd120: map=8'd150;
            9'd121: map=8'd151;
            9'd122: map=8'd152;
            9'd123: map=8'd153;
            9'd124: map=8'd154;
            9'd125: map=8'd154;
            9'd126: map=8'd155;
            9'd127: map=8'd156;
            9'd128: map=8'd157;
            9'd129: map=8'd158;
            9'd130: map=8'd159;
            9'd131: map=8'd160;
            9'd132: map=8'd161;
            9'd133: map=8'd161;
            9'd134: map=8'd162;
            9'd135: map=8'd163;
            9'd136: map=8'd164;
            9'd137: map=8'd165;
            9'd138: map=8'd166;
            9'd139: map=8'd167;
            9'd140: map=8'd168;
            9'd141: map=8'd168;
            9'd142: map=8'd169;
            9'd143: map=8'd170;
            9'd144: map=8'd171;
            9'd145: map=8'd172;
            9'd146: map=8'd173;
            9'd147: map=8'd173;
            9'd148: map=8'd174;
            9'd149: map=8'd175;
            9'd150: map=8'd176;
            9'd151: map=8'd177;
            9'd152: map=8'd178;
            9'd153: map=8'd178;
            9'd154: map=8'd179;
            9'd155: map=8'd180;
            9'd156: map=8'd181;
            9'd157: map=8'd182;
            9'd158: map=8'd182;
            9'd159: map=8'd183;
            9'd160: map=8'd184;
            9'd161: map=8'd185;
            9'd162: map=8'd186;
            9'd163: map=8'd186;
            9'd164: map=8'd187;
            9'd165: map=8'd188;
            9'd166: map=8'd189;
            9'd167: map=8'd190;
            9'd168: map=8'd191;
            9'd169: map=8'd191;
            9'd170: map=8'd192;
            9'd171: map=8'd193;
            9'd172: map=8'd194;
            9'd173: map=8'd195;
            9'd174: map=8'd195;
            9'd175: map=8'd196;
            9'd176: map=8'd197;
            9'd177: map=8'd198;
            9'd178: map=8'd199;
            9'd179: map=8'd199;
            9'd180: map=8'd200;
            9'd181: map=8'd201;
            9'd182: map=8'd202;
            9'd183: map=8'd202;
            9'd184: map=8'd203;
            9'd185: map=8'd204;
            9'd186: map=8'd205;
            9'd187: map=8'd205;
            9'd188: map=8'd206;
            9'd189: map=8'd207;
            9'd190: map=8'd208;
            9'd191: map=8'd208;
            9'd192: map=8'd209;
            9'd193: map=8'd210;
            9'd194: map=8'd211;
            9'd195: map=8'd211;
            9'd196: map=8'd212;
            9'd197: map=8'd213;
            9'd198: map=8'd214;
            9'd199: map=8'd214;
            9'd200: map=8'd215;
            9'd201: map=8'd216;
            9'd202: map=8'd217;
            9'd203: map=8'd217;
            9'd204: map=8'd218;
            9'd205: map=8'd219;
            9'd206: map=8'd220;
            9'd207: map=8'd220;
            9'd208: map=8'd221;
            9'd209: map=8'd222;
            9'd210: map=8'd223;
            9'd211: map=8'd223;
            9'd212: map=8'd224;
            9'd213: map=8'd225;
            9'd214: map=8'd226;
            9'd215: map=8'd226;
            9'd216: map=8'd227;
            9'd217: map=8'd228;
            9'd218: map=8'd229;
            9'd219: map=8'd229;
            9'd220: map=8'd230;
            9'd221: map=8'd231;
            9'd222: map=8'd232;
            9'd223: map=8'd232;
            9'd224: map=8'd233;
            9'd225: map=8'd234;
            9'd226: map=8'd234;
            9'd227: map=8'd235;
            9'd228: map=8'd236;
            9'd229: map=8'd236;
            9'd230: map=8'd237;
            9'd231: map=8'd238;
            9'd232: map=8'd239;
            9'd233: map=8'd239;
            9'd234: map=8'd240;
            9'd235: map=8'd241;
            9'd236: map=8'd241;
            9'd237: map=8'd242;
            9'd238: map=8'd243;
            9'd239: map=8'd243;
            9'd240: map=8'd244;
            9'd241: map=8'd245;
            9'd242: map=8'd245;
            9'd243: map=8'd246;
            9'd244: map=8'd247;
            9'd245: map=8'd247;
            9'd246: map=8'd248;
            9'd247: map=8'd249;
            9'd248: map=8'd250;
            9'd249: map=8'd250;
            9'd250: map=8'd251;
            9'd251: map=8'd252;
            9'd252: map=8'd252;
            9'd253: map=8'd253;
            9'd254: map=8'd254;
            9'd255: map=8'd255;
            9'd256: map=8'd0;
            9'd257: map=8'd4;
            9'd258: map=8'd7;
            9'd259: map=8'd11;
            9'd260: map=8'd14;
            9'd261: map=8'd18;
            9'd262: map=8'd21;
            9'd263: map=8'd25;
            9'd264: map=8'd28;
            9'd265: map=8'd32;
            9'd266: map=8'd35;
            9'd267: map=8'd39;
            9'd268: map=8'd42;
            9'd269: map=8'd46;
            9'd270: map=8'd49;
            9'd271: map=8'd53;
            9'd272: map=8'd56;
            9'd273: map=8'd58;
            9'd274: map=8'd59;
            9'd275: map=8'd61;
            9'd276: map=8'd62;
            9'd277: map=8'd64;
            9'd278: map=8'd65;
            9'd279: map=8'd67;
            9'd280: map=8'd69;
            9'd281: map=8'd70;
            9'd282: map=8'd72;
            9'd283: map=8'd73;
            9'd284: map=8'd75;
            9'd285: map=8'd76;
            9'd286: map=8'd78;
            9'd287: map=8'd79;
            9'd288: map=8'd81;
            9'd289: map=8'd82;
            9'd290: map=8'd84;
            9'd291: map=8'd85;
            9'd292: map=8'd86;
            9'd293: map=8'd88;
            9'd294: map=8'd89;
            9'd295: map=8'd90;
            9'd296: map=8'd92;
            9'd297: map=8'd93;
            9'd298: map=8'd94;
            9'd299: map=8'd95;
            9'd300: map=8'd97;
            9'd301: map=8'd98;
            9'd302: map=8'd99;
            9'd303: map=8'd101;
            9'd304: map=8'd102;
            9'd305: map=8'd103;
            9'd306: map=8'd104;
            9'd307: map=8'd105;
            9'd308: map=8'd106;
            9'd309: map=8'd107;
            9'd310: map=8'd108;
            9'd311: map=8'd109;
            9'd312: map=8'd111;
            9'd313: map=8'd112;
            9'd314: map=8'd113;
            9'd315: map=8'd114;
            9'd316: map=8'd115;
            9'd317: map=8'd116;
            9'd318: map=8'd117;
            9'd319: map=8'd118;
            9'd320: map=8'd119;
            9'd321: map=8'd120;
            9'd322: map=8'd121;
            9'd323: map=8'd122;
            9'd324: map=8'd123;
            9'd325: map=8'd124;
            9'd326: map=8'd125;
            9'd327: map=8'd126;
            9'd328: map=8'd127;
            9'd329: map=8'd128;
            9'd330: map=8'd129;
            9'd331: map=8'd130;
            9'd332: map=8'd131;
            9'd333: map=8'd132;
            9'd334: map=8'd133;
            9'd335: map=8'd134;
            9'd336: map=8'd135;
            9'd337: map=8'd136;
            9'd338: map=8'd137;
            9'd339: map=8'd138;
            9'd340: map=8'd139;
            9'd341: map=8'd139;
            9'd342: map=8'd140;
            9'd343: map=8'd141;
            9'd344: map=8'd142;
            9'd345: map=8'd143;
            9'd346: map=8'd144;
            9'd347: map=8'd145;
            9'd348: map=8'd146;
            9'd349: map=8'd146;
            9'd350: map=8'd147;
            9'd351: map=8'd148;
            9'd352: map=8'd149;
            9'd353: map=8'd150;
            9'd354: map=8'd151;
            9'd355: map=8'd151;
            9'd356: map=8'd152;
            9'd357: map=8'd153;
            9'd358: map=8'd154;
            9'd359: map=8'd155;
            9'd360: map=8'd156;
            9'd361: map=8'd156;
            9'd362: map=8'd157;
            9'd363: map=8'd158;
            9'd364: map=8'd159;
            9'd365: map=8'd160;
            9'd366: map=8'd160;
            9'd367: map=8'd161;
            9'd368: map=8'd162;
            9'd369: map=8'd163;
            9'd370: map=8'd164;
            9'd371: map=8'd164;
            9'd372: map=8'd165;
            9'd373: map=8'd166;
            9'd374: map=8'd167;
            9'd375: map=8'd168;
            9'd376: map=8'd169;
            9'd377: map=8'd169;
            9'd378: map=8'd170;
            9'd379: map=8'd171;
            9'd380: map=8'd172;
            9'd381: map=8'd173;
            9'd382: map=8'd173;
            9'd383: map=8'd174;
            9'd384: map=8'd175;
            9'd385: map=8'd176;
            9'd386: map=8'd176;
            9'd387: map=8'd177;
            9'd388: map=8'd178;
            9'd389: map=8'd178;
            9'd390: map=8'd179;
            9'd391: map=8'd180;
            9'd392: map=8'd181;
            9'd393: map=8'd181;
            9'd394: map=8'd182;
            9'd395: map=8'd183;
            9'd396: map=8'd183;
            9'd397: map=8'd184;
            9'd398: map=8'd185;
            9'd399: map=8'd185;
            9'd400: map=8'd186;
            9'd401: map=8'd187;
            9'd402: map=8'd187;
            9'd403: map=8'd188;
            9'd404: map=8'd189;
            9'd405: map=8'd189;
            9'd406: map=8'd190;
            9'd407: map=8'd191;
            9'd408: map=8'd192;
            9'd409: map=8'd192;
            9'd410: map=8'd193;
            9'd411: map=8'd194;
            9'd412: map=8'd194;
            9'd413: map=8'd195;
            9'd414: map=8'd196;
            9'd415: map=8'd196;
            9'd416: map=8'd197;
            9'd417: map=8'd198;
            9'd418: map=8'd198;
            9'd419: map=8'd199;
            9'd420: map=8'd200;
            9'd421: map=8'd200;
            9'd422: map=8'd201;
            9'd423: map=8'd202;
            9'd424: map=8'd203;
            9'd425: map=8'd203;
            9'd426: map=8'd204;
            9'd427: map=8'd205;
            9'd428: map=8'd205;
            9'd429: map=8'd206;
            9'd430: map=8'd207;
            9'd431: map=8'd207;
            9'd432: map=8'd208;
            9'd433: map=8'd209;
            9'd434: map=8'd209;
            9'd435: map=8'd210;
            9'd436: map=8'd211;
            9'd437: map=8'd211;
            9'd438: map=8'd212;
            9'd439: map=8'd212;
            9'd440: map=8'd213;
            9'd441: map=8'd214;
            9'd442: map=8'd214;
            9'd443: map=8'd215;
            9'd444: map=8'd216;
            9'd445: map=8'd216;
            9'd446: map=8'd217;
            9'd447: map=8'd217;
            9'd448: map=8'd218;
            9'd449: map=8'd219;
            9'd450: map=8'd219;
            9'd451: map=8'd220;
            9'd452: map=8'd221;
            9'd453: map=8'd221;
            9'd454: map=8'd222;
            9'd455: map=8'd222;
            9'd456: map=8'd223;
            9'd457: map=8'd224;
            9'd458: map=8'd224;
            9'd459: map=8'd225;
            9'd460: map=8'd226;
            9'd461: map=8'd226;
            9'd462: map=8'd227;
            9'd463: map=8'd227;
            9'd464: map=8'd228;
            9'd465: map=8'd229;
            9'd466: map=8'd229;
            9'd467: map=8'd230;
            9'd468: map=8'd230;
            9'd469: map=8'd231;
            9'd470: map=8'd231;
            9'd471: map=8'd232;
            9'd472: map=8'd233;
            9'd473: map=8'd233;
            9'd474: map=8'd234;
            9'd475: map=8'd234;
            9'd476: map=8'd235;
            9'd477: map=8'd235;
            9'd478: map=8'd236;
            9'd479: map=8'd236;
            9'd480: map=8'd237;
            9'd481: map=8'd238;
            9'd482: map=8'd238;
            9'd483: map=8'd239;
            9'd484: map=8'd240;
            9'd485: map=8'd240;
            9'd486: map=8'd241;
            9'd487: map=8'd241;
            9'd488: map=8'd242;
            9'd489: map=8'd243;
            9'd490: map=8'd243;
            9'd491: map=8'd244;
            9'd492: map=8'd245;
            9'd493: map=8'd245;
            9'd494: map=8'd246;
            9'd495: map=8'd246;
            9'd496: map=8'd247;
            9'd497: map=8'd248;
            9'd498: map=8'd248;
            9'd499: map=8'd249;
            9'd500: map=8'd249;
            9'd501: map=8'd250;
            9'd502: map=8'd250;
            9'd503: map=8'd251;
            9'd504: map=8'd251;
            9'd505: map=8'd252;
            9'd506: map=8'd252;
            9'd507: map=8'd253;
            9'd508: map=8'd253;
            9'd509: map=8'd254;
            9'd510: map=8'd254;
            9'd511: map=8'd255;
            default:map=8'hxx;
        endcase end
    endfunction
    localparam CHANNELS=PIXELS*3;
    wire [PIXELS*24-1:0] mapped;
    genvar pair;
    generate if(USE_ERAM) begin:g_eram
        for(pair=0;pair<(CHANNELS+1)/2;pair=pair+1) begin:g_pair
            // No reset on ROM/read data; validity masks reset and invalid data.
            (* rom_style="bram" *) reg [7:0] table_data[0:511];
            integer address;
            initial for(address=0;address<512;address=address+1)
                table_data[address]=map(address[8:0]);
            reg [7:0] qa;
            always @(posedge clk) qa<=table_data[{style,data[pair*16+:8]}];
            assign mapped[pair*16+:8]=qa;
            if(pair*2+1<CHANNELS) begin:g_second
                reg [7:0] qb;
                always @(posedge clk) qb<=table_data[{style,data[pair*16+8+:8]}];
                assign mapped[pair*16+8+:8]=qb;
            end
        end
    end else begin:g_logic
        reg [PIXELS*24-1:0] data_q;
        integer channel;
        always @(posedge clk)
            for(channel=0;channel<CHANNELS;channel=channel+1)
                data_q[channel*8+:8]<=map({style,data[channel*8+:8]});
        assign mapped=data_q;
    end endgenerate
    assign out_data=out_valid ? mapped : {PIXELS*24{1'b0}};
    always @(posedge clk or negedge rst_n)
        if(!rst_n) begin out_valid<=0;out_user<=0;out_last<=0;end
        else begin out_valid<=valid;out_user<=user;out_last<=last;end
endmodule
// END GENERATED MODE GAMMA
