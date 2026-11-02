/*****************************************************************
Company : Nanjing Weiku Robot Technology Co., Ltd.
Brand   : VLKUS
Technical forum:www.uisrc.com
@Author      :   XiaoQingquan 
@Time        :   2024/09/18 
@Description :   将每拍 4 个 32-bit 对齐的 RGB 像素转换为 4 个紧凑的 RGB888 像素
*****************************************************************/

/*
 * data128_96：RGB 数据位宽整理模块。
 *
 * 上游 bilinear_interpolation 每拍输出 4 个 32-bit 像素：
 *   pixelN = {8'b0, R[7:0], G[7:0], B[7:0]}
 * 其中最高 8 bit 只是对齐/保留位，不包含有效颜色信息。
 *
 * 本模块删除四个像素各自的 8-bit 保留位，将：
 *   4 × 32 bit = 128 bit
 * 转换为：
 *   4 × RGB888 = 4 × 24 bit = 96 bit
 *
 * 同时完成像素在总线中的排列调整：输入的 pixel0 位于最低 32 bit，
 * 输出则把 pixel0 的 RGB 放在最高 24 bit，便于后级按高位到低位处理。
 * 模块只有连续赋值，没有时钟、寄存器和状态机，因此属于纯组合逻辑。
 */
module data128_96 (

    input  wire [127:0] I_tdata, // 输入：4×{保留8 bit, R8, G8, B8}
    output wire [ 95:0] O_tdata  // 输出：4×{R8, G8, B8}
);

  /*
   * 输入位段：
   *   I_tdata[ 31:  0] = {保留0, R0, G0, B0}
   *   I_tdata[ 63: 32] = {保留1, R1, G1, B1}
   *   I_tdata[ 95: 64] = {保留2, R2, G2, B2}
   *   I_tdata[127: 96] = {保留3, R3, G3, B3}
   *
   * 只提取各 32-bit 像素的低 24 bit，并按下面的方式输出：
   *   O_tdata[95:72] = {R0, G0, B0}
   *   O_tdata[71:48] = {R1, G1, B1}
   *   O_tdata[47:24] = {R2, G2, B2}
   *   O_tdata[23: 0] = {R3, G3, B3}
   */
  assign O_tdata = {I_tdata[23:0], I_tdata[55:32], I_tdata[87:64], I_tdata[119:96]};

  // 原工程保留的旧写法，当前不参与综合。
  //assign O_tdata = {I_tdata, I_tdata, I_tdata[55:32], I_tdata[23:0]};

endmodule
