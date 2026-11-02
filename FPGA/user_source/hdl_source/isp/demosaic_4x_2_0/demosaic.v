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
@Time        :   2025/01 
version:     :   1.1
@Description :   该模块负责组织 Bayer 去马赛克处理：先形成相邻三行像素窗口并
                 处理图像边界，再通过双线性插值为每个 Bayer 像素补齐 RGB 分量。
*****************************************************************/

/*
 * demosaic：Bayer RAW 图像去马赛克顶层。
 *
 * 彩色摄像头传感器的一个感光点通常只采集 R、G、B 中的一种颜色。
 * 本模块根据 BAYER_MODE 指定的颜色排列，利用周围同色像素进行双线性
 * 插值，为每个位置恢复完整的 R、G、B 三个颜色分量。
 *
 * 数据通路：
 *   4 × RAW10（40 bit）
 *       -> raw_matrix_3x3_buffer：拆分像素、两行缓存、邻域窗口和边界处理
 *       -> bilinear_interpolation：根据 Bayer 行列位置插值 R/G/B
 *       -> 4 × {8 bit 保留位, R8, G8, B8}（128 bit）
 *
 * 该文件本身主要连接两个子模块；实际窗口缓存和插值运算分别位于上述
 * 两个子模块中。
 */
module demosaic #(
    parameter IMG_HEIGHT          = 1080,  // 输入图像有效高度，单位：行
    parameter IMG_WIDTH           = 1920,  // 输入图像有效宽度，单位：像素
    parameter data_complete_delay = 50,    // 窗口缓存内部的数据填充/时序对齐参数
    parameter BAYER_MODE          = "BGGR" // Bayer 阵列格式：RGGB/BGGR/GBRG/GRBG
)
(
    input           I_clk,      // 像素流时钟
    input           I_rst_n,    // 异步低有效复位

    // 输入：类 AXI4-Stream 的 Bayer RAW10 视频流
    input [39:0]            axi4s_video_tdata,  // 每拍 4 个 10 bit Bayer 像素
    input [9:0]             axi4s_video_tdest,  // 附加目的字段，传给窗口模块
    input                   axi4s_video_tlast,  // 当前拍包含一行的最后一组像素
    input                   axi4s_video_tvalid, // 当前输入数据有效
    input                   axi4s_video_tuser,  // 当前拍为一帧的第一组像素
    output                  axi4s_video_tready, // 本模块可以接收上游数据

    // 输出：类 AXI4-Stream 的 RGB 视频流
    output                  O_tlast,   // 与输出 RGB 数据对齐的行结束标志
    output                  O_tuser,   // 与输出 RGB 数据对齐的帧开始标志
    output [127:0]          O_tdata,   // 4 个 32 bit RGB 字：{8'b0,R8,G8,B8}
    output                  O_tvalid,  // 当前输出 RGB 数据有效
    input                   O_tready   // 下游可以接收输出数据
);

// 窗口模块输出的同步和握手信号；它们与三行窗口数据保持对齐。
wire demosaic_tlast;
wire demosaic_tuser;
wire demosaic_tvalid;
wire demosaic_tready;

// Bayer 行奇偶位置以及相邻三行的窗口数据。
// 三个 96 bit 总线分别代表上一行、中心行和下一行的邻域像素。
// 每拍同时处理 4 个相邻像素，因此内部保留了这些像素共同需要的横向邻域。
wire        bayer_ypos;
wire [95:0] matrix_last_line;
wire [95:0] matrix_cur_line;
wire [95:0] matrix_next_line;

// -----------------------------------------------------------------------------
// 第一级：构造插值所需的相邻三行像素窗口
// -----------------------------------------------------------------------------
// 该模块内部完成：
// 1. 将 4×10 bit RAW10 转换为后级使用的 8 bit Bayer 像素；
// 2. 用两级行缓存取得上一行、当前行和下一行数据；
// 3. 拼出每拍 4 个输出像素所需的局部邻域；
// 4. 对第一/最后一行、第一/最后一列进行边界填充；
// 5. 延迟 tuser/tlast/tvalid，使控制信号与窗口数据对齐。
raw_matrix_3x3_buffer #(
    .IMG_HEIGHT         (IMG_HEIGHT         ),
    .IMG_WIDTH          (IMG_WIDTH          ),
    .data_complete_delay(data_complete_delay)
)raw_matrix_3x3_buffer_d
(
    .I_clk               (I_clk               ),
    .I_rst_n             (I_rst_n             ),

    .axi4s_video_tdata   (axi4s_video_tdata   ),
    .axi4s_video_tdest   (axi4s_video_tdest   ),
    .axi4s_video_tlast   (axi4s_video_tlast   ),
    .axi4s_video_tvalid  (axi4s_video_tvalid  ),
    .axi4s_video_tuser   (axi4s_video_tuser   ),
    .axi4s_video_tready  (axi4s_video_tready  ),

    .O_tlast             (demosaic_tlast      ),
    .O_tuser             (demosaic_tuser      ),
    .O_tvalid            (demosaic_tvalid     ),
    .O_tready            (demosaic_tready     ),

    .bayer_ypos          (bayer_ypos           ), // 中心像素所在行的奇偶信息
    .matrix_last_line    (matrix_last_line     ), // 上一行邻域
    .matrix_cur_line     (matrix_cur_line      ), // 中心行邻域
    .matrix_next_line    (matrix_next_line     )  // 下一行邻域
);

// -----------------------------------------------------------------------------
// 第二级：Bayer 双线性插值
// -----------------------------------------------------------------------------
// 根据 BAYER_MODE、当前行奇偶和窗口内的列位置判断中心像素属于 R/G/B
// 哪一种颜色；保留传感器实际采到的颜色分量，对另外两个颜色分量取相邻
// 同色像素的平均值，最终为每个位置生成完整的 RGB888 像素。
bilinear_interpolation #(
    .BAYER_MODE (BAYER_MODE)
)bilinear_interpolation_d(
    .I_clk            (I_clk            ),
    .I_rst_n          (I_rst_n          ),

    .I_tlast          (demosaic_tlast   ),
    .I_tuser          (demosaic_tuser   ),
    .I_tvalid         (demosaic_tvalid  ),
    .I_tready         (demosaic_tready  ),

    .bayer_ypos       (bayer_ypos       ),
    .matrix_last_line (matrix_last_line ),
    .matrix_cur_line  (matrix_cur_line  ),
    .matrix_next_line (matrix_next_line ),

    .O_tlast          (O_tlast          ),
    .O_tuser          (O_tuser          ),
    .O_tdata          (O_tdata          ),
    .O_tvalid         (O_tvalid         ),
    .O_tready         (O_tready         )

);



endmodule
