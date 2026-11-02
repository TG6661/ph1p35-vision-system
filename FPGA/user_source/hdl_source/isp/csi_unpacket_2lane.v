/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2023/03/23
*Module Name:
*File Name:
*Description: 
*The reference demo provided by Milianke is only used for learning. 
*We cannot ensure that the demo itself is free of bugs, so users 
*should be responsible for the technical problems and consequences
*caused by the use of their own products.
*Copyright: Copyright (c) MiLianKe
*All rights reserved.
*Revision: 1.0
*Signal description
*1) I_ input
*2) O_ output
*3) IO_ input output
*4) S_ system internal signal
*5) _n activ low
*6) _dg debug signal 
*7) _r delay or register
*8) _s state mechine
*********************************************************************/
/*****************************************************************************
 * csi_unpacket_2lane：2-Lane、每 Lane 1 Byte 模式下的 MIPI CSI-2 简易解包器
 * 上游 D-PHY 每拍输出 16 bit；本模块识别 CSI-2 包头，提取 RAW10 负载，
 * 并将两个连续的 16 bit 数据拼成一个 32 bit 数据字。
 * 输出仍处于 I_clk（MIPI 字节时钟）域，供后级 RAW10 解包模块使用。
 *****************************************************************************/

`timescale 1ns / 1ns

module csi_unpacket_2lane 
(
input wire          I_clk,  // MIPI D-PHY 输出的字节时钟
input wire          I_rst_n,// 异步低有效复位

input wire          I_hs_valid,
input wire[15: 0]   I_hs_data, 

output reg           O_csi_frame_start, // 帧开始短包脉冲（DT=0x00）
output reg           O_csi_frame_end,   // 帧结束短包脉冲（DT=0x01）
output reg           O_csi_valid,       
output reg           O_csi_hs,          // I_hs_valid 的延迟/镜像信号
output reg  [31: 0]  O_csi_data        
);


// MIPI CSI-2 数据类型（Data Type，DT）：
// 0x00 帧开始短包（FS），0x01 帧结束短包（FE）；
// 0x02/0x03 分别为行开始/行结束短包；
// 0x2A 为 RAW8 长包，0x2B 为 RAW10 长包。本例只提取 RAW10。

localparam FRAME_DATA_DT  = 8'h2B;   // 当前摄像头输出格式：RAW10
//localparam FRAME_DATA_DT  = 8'h2A; // 若改为 RAW8，可切换到此类型
localparam FRAME_START_DT = 8'h00;   // Frame Start
localparam FRAME_END_DT   = 8'h01;   // Frame End

// 对输入 valid/data 打一拍，便于检测每个 CSI 包的起始边界。
reg        S_hs_valid_1d;      
reg [15:0] S_hs_data_1d;       
wire       S_head_en;          
reg        S_head_en_1d;       
reg [15:0] S_data_length;      
reg        S_data_en;          
reg [15:0] S_data_en_cnt;      

// I_hs_valid 从 0 变 1 时，认为一个 CSI-2 包的第一个 16 bit 到达。
assign  S_head_en  = ~S_hs_valid_1d & I_hs_valid;

// 保存输入数据和包头脉冲。CSI 长包内 valid 通常连续为 1，
// 因此用 valid 的上升沿而不是固定计数判断新包。
always @(posedge I_clk) begin 
    S_hs_valid_1d        <= I_hs_valid;
    S_hs_data_1d         <= I_hs_data;
    S_head_en_1d         <= S_head_en;
end

// 包头 DT=0x00 时产生一个时钟周期的帧开始标志。
always @(posedge I_clk) 
    O_csi_frame_start <= (S_head_en_1d && S_hs_data_1d[15:8] == FRAME_START_DT);


// 包头 DT=0x01 时产生一个时钟周期的帧结束标志。
always @(posedge I_clk) 
    O_csi_frame_end  <= (S_head_en_1d && S_hs_data_1d[15:8] == FRAME_END_DT);

// 读取 RAW10 长包的负载长度。4 字节包头分布在两个 16 bit 输入拍中；
// 组合出负载字节数后右移 1（除以 2），得到需要接收的 16 bit 拍数。
// 1280 像素 RAW10 行为 1600 Byte，对应 800 个输入拍。
always @(posedge I_clk) begin 
    if(I_hs_valid)begin
        if(S_head_en_1d && S_hs_data_1d[15:8] == FRAME_DATA_DT)
            S_data_length <= {I_hs_data[15:8],S_hs_data_1d[7:0]} >> 1;
        else    
            S_data_length <= S_data_length;
    end
    else    
        S_data_length <= 'd0;
end


// 产生 RAW10 负载提取使能。检测到 RAW10 长包头后开始计数，
// 达到包长度后停止，包头和后续非图像数据不会送入输出。
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n)
        S_data_en <= 1'b0;
    else    
        if(S_head_en_1d && S_hs_data_1d[15:8] == FRAME_DATA_DT)
            S_data_en <= 1'b1;
        else if(S_data_en_cnt == S_data_length-1)
            S_data_en <= 1'b0;
        else    
            S_data_en <= S_data_en;
end

// 统计当前 RAW10 长包已经接收的 16 bit 输入拍数；关闭时清零。
always @(posedge I_clk) begin
    if(S_data_en)
        S_data_en_cnt <= S_data_en_cnt + 'd1;
    else
        S_data_en_cnt <= 'd0;
end

// 将 2 Lane 的 16 bit 输入重组成 32 bit 输出。
// csi_valid_r 每收到一个有效 16 bit 拍就翻转一次，因此每两拍产生
// 一个 O_csi_valid 脉冲。
reg  csi_valid_r;

always @(posedge I_clk) begin
    csi_valid_r   <= S_data_en ? ~csi_valid_r : 0; 
    O_csi_valid   <= csi_valid_r;
    O_csi_hs      <= I_hs_valid; // 保留原始高速包有效状态，供调试观察
end

// 在 RAW10 负载期间移位拼接数据；非负载期间输出清零。
// 连续两个 I_hs_data 组成一个 32 bit CSI 数据字。
always @(posedge I_clk) begin
    O_csi_data    <= S_data_en ? {O_csi_data[15:0],I_hs_data} : 0;
end

    
endmodule
