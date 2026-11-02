/*****************************************************************
Company : MiLianKe Electronic Technology Co., Ltd.
WebSite:https://www.milianke.com
TechWeb:https://www.uisrc.com
tmall-shop:https://milianke.tmall.com
jd-shop:https://milianke.jd.com
taobao-shop: https://milianke.taobao.com
Description: 
The reference demo provided by Milianke is only used for learning. 
We cannot ensure that the demo itself is free of bugs, so users 
should be responsible for the technical problems and consequences
caused by the use of their own products.
@Author      :   XiaoQingquan 
@Time        :   2024/10 
version:     :   
@Description :   在原基础上删去了一些赘余的代码，并且优化了时序，加入BRAM IP核，
                 让从除法器出来的每一个数据都可以对上相应的像素数据进行增益，使
                 得它的适用行更加广泛了。
*****************************************************************/

/*
 * OPFPGA FIXED-only white balance. Module name retained for compatibility.
 * Legacy mode input is ignored; fixed calibration is always applied.
 * No automatic estimator, accumulators or divider instances remain.
 * Existing input/BRAM/output delay is retained to preserve the early frame-reset
 * lead required by video_in. This fixed-rate legacy stream requires blanking;
 * O_tready does not stall the pipeline. Four RGB888 pixels per cycle.
 */
module awb  #(   
    parameter IMG_HEIGHT = 1080, // 有效图像高度；当前工程实例化时改写为 720
    parameter [19:0] FIXED_R_GAIN_Q16=20'd95907,
    parameter [19:0] FIXED_B_GAIN_Q16=20'd100825,
    parameter IMG_WIDTH  = 1920  // 有效图像宽度；当前工程实例化时改写为 1280
) 
(
    input [1:0] I_wb_mode, // Reserved legacy test interface; ignored in FIXED-only RTL
    output wire [1:0] O_wb_mode,
    output wire [19:0] O_r_gain_q16, O_b_gain_q16,
    input                   I_clk  , // 像素流处理时钟
    input                   I_rst_n, // 异步复位，低有效


    input                   I_tlast  , // 输入行结束标志；当前实现未直接使用
    input                   I_tuser  , // 一帧第一个数据拍标志；白平衡固定为 FIXED
    input [95:0]            I_tdata  , // 4 个 RGB888 像素，共 96 bit
    input                   I_tvalid , // 输入数据有效
    output                  I_tready , // 向上游返回的就绪信号

    output                  O_tlast  , // 由延迟后 valid 的下降沿重建的行结束标志
    output                  O_tuser  , // 帧开始标志；当前代码直接传递 I_tuser
    output [95:0]           O_tdata  , // 4 个白平衡校正后的 RGB888 像素
    output                  O_tvalid , // 输出数据有效
    input                   O_tready   // 下游就绪信号
);

    reg I_tvalid_r0,I_tvalid_r1;
    reg [95:0] I_tdata_d0,I_tdata_d1;
    wire [95:0] data_d0;
    wire valid_d0,I_tuser_r0;
    reg [95:0] data_d1;
    reg valid_d1,I_tuser_r1;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            I_tdata_d0<=0;I_tdata_d1<=0;I_tvalid_r0<=0;I_tvalid_r1<=0;
        end else begin
            I_tdata_d0<=I_tdata;I_tdata_d1<=I_tdata_d0;
            I_tvalid_r0<=I_tvalid;I_tvalid_r1<=I_tvalid_r0;
        end
    end
    // Preserve the proven FIFO-reset lead and pixel latency.
    signal_delay #(
        .IMG_HEIGHT   (IMG_HEIGHT),
        .IMG_WIDTH    (IMG_WIDTH ),
        .DATA_WIDTH   (96  ),
        .DELAY_CYCLE  (50) // 保持已有像素延迟和提前SOF契约
    )signal_delay_d (
        /*input                       */ .I_clk  (I_clk  ),
        /*input                       */ .I_rst_n(I_rst_n),
        /*input                       */ .I_tuser(I_tuser),
        /*input  wire                 */ .I_valid(I_tvalid_r1),
        /*input  wire [DATA_WIDTH-1:0]*/ .I_data (I_tdata_d1 ),
        /*output wire                 */ .O_valid(valid_d0   ),
        /*output wire [DATA_WIDTH-1:0]*/ .O_data (data_d0    ),
        /*output wire                 */ .O_tuser(I_tuser_r0 )
    );

    

    assign O_wb_mode=2'd1;
    assign O_r_gain_q16=FIXED_R_GAIN_Q16;
    assign O_b_gain_q16=FIXED_B_GAIN_Q16;
    // BRAM 延迟结果再寄存一级，使 data、valid 和内部 tuser 信号对齐乘法级。
    always @(posedge I_clk or negedge I_rst_n) begin
      if (!I_rst_n) begin
          valid_d1 <= 0;
          data_d1  <= 0;
          I_tuser_r1 <= 0;
      end else begin
          valid_d1 <= valid_d0;
          data_d1  <= data_d0 ;
          I_tuser_r1 <= I_tuser_r0;
      end
    end
/*****************************************************************
                           像素增益计算
*****************************************************************/

    // Q16增益为20 bit，RGB像素为8 bit，相乘结果使用28 bit保存。
    reg [27:0] R_new_r1;
    reg [27:0] G_new_r1;
    reg [27:0] B_new_r1;

    reg [27:0] R_new_r2;
    reg [27:0] G_new_r2;
    reg [27:0] B_new_r2;

    reg [27:0] R_new_r3;
    reg [27:0] G_new_r3;
    reg [27:0] B_new_r3;

    reg [27:0] R_new_r4;
    reg [27:0] G_new_r4;
    reg [27:0] B_new_r4;


    // 将延迟后的 96-bit 数据重新拆成四个 {R8,G8,B8} 像素。
    wire   [7:0] rgb888_r_d1[0:3];
    wire   [7:0] rgb888_g_d1[0:3];
    wire   [7:0] rgb888_b_d1[0:3];

    assign  rgb888_r_d1[0] = data_d1[16+:8];
    assign  rgb888_g_d1[0] = data_d1[8+:8];
    assign  rgb888_b_d1[0] = data_d1[0+:8];

    assign  rgb888_r_d1[1] = data_d1[40+:8];
    assign  rgb888_g_d1[1] = data_d1[32+:8];
    assign  rgb888_b_d1[1] = data_d1[24+:8];

    assign  rgb888_r_d1[2] = data_d1[64+:8];
    assign  rgb888_g_d1[2] = data_d1[56+:8];
    assign  rgb888_b_d1[2] = data_d1[48+:8];

    assign  rgb888_r_d1[3] = data_d1[88+:8];
    assign  rgb888_g_d1[3] = data_d1[80+:8];
    assign  rgb888_b_d1[3] = data_d1[72+:8];
    // 同一组 R_gain/B_gain 应用于全部四个像素；绿色作为参考通道保持原值：
    //   R_product = R_gain(Q16) × R，G_product = G，B_product = B_gain(Q16) × B。
    always @(posedge I_clk or negedge I_rst_n)begin 
        if(!I_rst_n)begin
            R_new_r1 <= 0;
            G_new_r1 <= 0;
            B_new_r1 <= 0;

            R_new_r2 <= 0;
            G_new_r2 <= 0;
            B_new_r2 <= 0;

            R_new_r3 <= 0;
            G_new_r3 <= 0;
            B_new_r3 <= 0;

            R_new_r4 <= 0;
            G_new_r4 <= 0;
            B_new_r4 <= 0;
        end
        else if(valid_d1) begin
            R_new_r1 <= O_r_gain_q16 * rgb888_r_d1[0];
            G_new_r1 <=           rgb888_g_d1[0];
            B_new_r1 <= O_b_gain_q16 * rgb888_b_d1[0];

            R_new_r2 <= O_r_gain_q16 * rgb888_r_d1[1];
            G_new_r2 <=           rgb888_g_d1[1];
            B_new_r2 <= O_b_gain_q16 * rgb888_b_d1[1];

            R_new_r3 <= O_r_gain_q16 * rgb888_r_d1[2];
            G_new_r3 <=           rgb888_g_d1[2];
            B_new_r3 <= O_b_gain_q16 * rgb888_b_d1[2];

            R_new_r4 <= O_r_gain_q16 * rgb888_r_d1[3];
            G_new_r4 <=           rgb888_g_d1[3];
            B_new_r4 <= O_b_gain_q16 * rgb888_b_d1[3];
        end
    end

/*****************************************************************
                            像素截断与饱和
*****************************************************************/

    // R/B乘积仍带16位Q16小数，因此取[23:16]得到8-bit整数。
    // 若更高位[27:24]非零，说明结果超过255，统一饱和到8'hFF。
    // G未经过定点乘法，赋给8-bit输出时直接保留原始低8位。
    wire [7:0] R_new_x1;
    wire [7:0] G_new_x1;
    wire [7:0] B_new_x1;

    wire [7:0] R_new_x2;
    wire [7:0] G_new_x2;
    wire [7:0] B_new_x2;

    wire [7:0] R_new_x3;
    wire [7:0] G_new_x3;
    wire [7:0] B_new_x3;

    wire [7:0] R_new_x4;
    wire [7:0] G_new_x4;
    wire [7:0] B_new_x4;

    assign R_new_x1 = (R_new_r1[27:24])?255:R_new_r1[23:16];
    assign G_new_x1 =  G_new_r1;
    assign B_new_x1 = (B_new_r1[27:24])?255:B_new_r1[23:16];

    assign R_new_x2 = (R_new_r2[27:24])?255:R_new_r2[23:16];
    assign G_new_x2 =  G_new_r2;
    assign B_new_x2 = (B_new_r2[27:24])?255:B_new_r2[23:16];

    assign R_new_x3 = (R_new_r3[27:24])?255:R_new_r3[23:16];
    assign G_new_x3 =  G_new_r3;
    assign B_new_x3 = (B_new_r3[27:24])?255:B_new_r3[23:16];

    assign R_new_x4 = (R_new_r4[27:24])?255:R_new_r4[23:16];
    assign G_new_x4 =  G_new_r4;
    assign B_new_x4 = (B_new_r4[27:24])?255:B_new_r4[23:16];
/*****************************************************************
                           输出控制信号
*****************************************************************/

    // valid 和内部 tuser 再延迟一拍，与乘法寄存输出对齐。
    // 注意：I_tuser_r2 虽已生成，但下面 O_tuser 实际仍直接连接 I_tuser。
    reg valid_d2,I_tuser_r2;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n)begin
            valid_d2 <= 0;
            I_tuser_r2 <= 0;
        end
        else begin
            valid_d2 <= valid_d1;
            I_tuser_r2 <= I_tuser_r1;
        end
    end


    // 当前实现不使用输入 I_tlast，而以 valid 从1变0的边沿重建行结束标志。
    assign  O_tlast  = (valid_d1 == 0) && (valid_d2 == 1);
    assign  O_tuser  = I_tuser ; // 直接传递，未补偿AWB数据通路延迟
    assign  O_tvalid = valid_d2;

    // 四个校正后RGB888像素重新拼成96 bit；无效拍输出0。
    assign  O_tdata = O_tvalid?{R_new_x4,G_new_x4,B_new_x4,
                       R_new_x3,G_new_x3,B_new_x3,
                       R_new_x2,G_new_x2,B_new_x2,
                       R_new_x1,G_new_x1,B_new_x1}:0;
    // assign O_t_data = {R_new[7-:5],G_new[7-:6],B_new[7-:5]};
    // ready仅组合直通。内部像素计算及BRAM延迟不会因O_tready=0而暂停，
    // 因此当前设计按连续视频流工作，通常要求下游能够持续接收有效数据。
    assign  I_tready = O_tready;
 
endmodule



