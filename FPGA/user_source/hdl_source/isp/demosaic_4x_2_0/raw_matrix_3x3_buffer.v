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
@Description :   该模块主要是用于3x3矩阵的形成，以及对图像边界像素的处理
                 在原基础上优化了时序，把原来的一些未完全对齐的信号进行对齐。
*****************************************************************/

/*
 * raw_matrix_3x3_buffer：Bayer 邻域生成模块。
 *
 * 数据通路：
 *   40 bit RAW10（每拍 4 像素）
 *     -> mipi_to_raw_converter：每个 10 bit 样本保留高 8 bit
 *     -> zhenghe：用 BRAM 整理一行内的数据有效时序
 *     -> 两级 line_buffer_demosaic：得到相隔 0、1、2 行的三路数据
 *     -> 延迟对齐与横向移位：形成上一行、中心行、下一行的邻域数据
 *     -> bilinear_interpolation：利用邻域完成 Bayer 双线性插值
 *
 * 注意：接口每拍并行输入 4 个像素，所以这里不是只为一个像素输出普通的
 * 3×3 窗口。每个 matrix_*_line 均为 96 bit，可保存 12 个 8-bit 样本；
 * 后级从三行数据的中间部分各取 6 个样本，同时计算 4 个相邻中心像素。
 */

module raw_matrix_3x3_buffer #(
    parameter IMG_HEIGHT = 1080,  // 有效图像高度，单位：行；当前工程实例化时改写为 720
    parameter IMG_WIDTH  = 1920,  // 有效图像宽度，单位：像素；当前工程实例化时改写为 1280
    parameter data_complete_delay = 50 // zhenghe 读 BRAM 时使用的行间时序补偿量
)
(
    input           I_clk   ,   // 像素流处理时钟
    input           I_rst_n ,   // 异步复位，低有效

    input [39:0]                         axi4s_video_tdata ,  // 4 个 RAW10 Bayer 样本，共 40 bit
    input [9:0]                          axi4s_video_tdest ,  // 随输入传入转换模块，本模块不直接解析
    input                                axi4s_video_tlast ,  // 一行最后一个数据拍标志
    input                                axi4s_video_tvalid,  // 输入数据有效
    input                                axi4s_video_tuser ,  // 一帧第一个数据拍标志
    output                               axi4s_video_tready,  // 向上游返回的就绪信号

    output                               O_tlast         ,   // 与邻域数据对齐的行结束标志
    output                               O_tuser         ,   // 与邻域数据对齐的帧开始标志
    output                               O_tvalid        ,   // 三行邻域数据有效
    input                                O_tready        ,   // 下游 bilinear_interpolation 的就绪信号

    output                               bayer_ypos      ,   // 中心行的奇偶相位，用于判断 Bayer 颜色排列
    output  [95:0]                       matrix_last_line,   // 垂直邻域的上一行横向移位数据
    output  [95:0]                       matrix_cur_line ,   // 垂直邻域的中心行横向移位数据
    output  [95:0]                       matrix_next_line    // 垂直邻域的下一行横向移位数据
);


/*********************************************************
******************1.功能声明*******************************
*********************************************************/
// 返回表示 depth 所需的位数。当前版本未调用，属于原工程保留的工具函数。
function integer clog2b(
    input integer depth
);
    begin
        for(clog2b=0; depth>0; clog2b=clog2b+1)begin
            depth = depth >> 1;
        end
    end    
endfunction

/*********************************************************
******************2.常数声明*******************************
*********************************************************/
localparam N = 3;  // 三路行数据：当前输入、延迟一行、延迟两行

localparam DATA_WIDTH   = 32;  // 每拍 4 个 8-bit Bayer 样本

// 水平计数以“4 像素数据组”为单位。1280 宽时，每行共有 1280/4=320 拍有效数据。
localparam IMG_WIDTH_4x = (IMG_WIDTH >> 2);

/*********************************************************
******************3.信号声明*******************************
*********************************************************/
wire                        zhenghe_tlast ;    // zhenghe 输出的行结束标志
wire                        zhenghe_tuser ;    // zhenghe 输出的帧开始标志
wire  [31:0]                zhenghe_tdata ;    // zhenghe 整理后的 4×8-bit Bayer 数据
wire                        zhenghe_tvalid;    // zhenghe 输出有效

wire  [DATA_WIDTH-1:0]      raw_data        ;  // RAW10 截取高 8 bit 后的 4 像素数据
wire                        raw_data_valid  ;  // raw_data 有效标志

// data[0]/[1]/[2] 分别对应原始行、延迟一行、延迟两行；
// 每路为 33 bit，其中 data[*][32] 保存帧开始标志，data[*][31:0] 保存像素。
wire                valid   [0:N-1] ;
wire [DATA_WIDTH:0] data    [0:N-1] ;

wire                O_raw_tlast_d0;            // RAW10 转换后对齐的行结束标志
wire                O_raw_tuser_d0;            // RAW10 转换后对齐的帧开始标志
wire                I_raw_tready;              // 转换模块返回的 ready（当前版本未继续使用）
wire [32:0]         next_line_data;            // 原工程预留，当前版本未使用
wire [32:0]         data_d2;                   // 两级行缓存的输出，直接作为最早一行数据
wire                next_line_start;           // 原工程预留，当前版本未使用
wire                bayer_ypos_d0;             // 与输出有效同步的中心行奇偶标志

/*********************************************************
******************4.寄存器信号声明*************************
*********************************************************/
// 三个 96-bit 寄存器分别对三行做横向滑动缓存，每次移入 4 个新像素。
reg [95:0]      matrix_cur_line_buffer       ; // 中心行滑动缓存
reg [95:0]      matrix_last_line_buffer      ; // 上一行滑动缓存
reg [95:0]      matrix_next_line_buffer      ; // 下一行滑动缓存
reg             tlast_d0,tlast_d1,tlast_d2;    // 流控制信号的三级延迟
reg             tuser_d0,tuser_d1,tuser_d2;
reg             ch_valid;                      // 与矩阵输出同步的数据有效标志
reg [13:0]      h_cnt;                         // 行内数据组计数，单位为 4 像素/拍
reg [13:0]      v_cnt,v_cnt_d;                 // 行号及其一拍延迟值
reg             next_line_data_valid;          // 原工程预留，当前版本未使用
reg             valid_d0,valid_d1;             // 输入有效的两级延迟
reg             bayer_ypos_d;                  // 原工程预留，当前版本未使用
reg  [32:0]     data_d0_d,data_d0;             // 最新一行数据的两级延迟
reg  [32:0]     data_d1;                       // 延迟一行数据的一级延迟

/*********************************************************
******************5.组合逻辑******************************
*********************************************************/
// 第 0 路是未经“行延迟”的数据。把 tuser 一同送入行缓存，便于各级地址在帧首复位。
assign data[0]  = {zhenghe_tuser, zhenghe_tdata};
assign valid[0] = zhenghe_tvalid;

// ready 仅作组合直通：下游是否就绪直接反馈给输入端。
assign axi4s_video_tready = O_tready;

/*********************************************************/
// 输出当前保存的三行横向邻域。
assign matrix_last_line = matrix_last_line_buffer;
assign matrix_cur_line  = matrix_cur_line_buffer ;
assign matrix_next_line = matrix_next_line_buffer;

// v_cnt_d[0] 表示行号奇偶。
// 当前定义中，偶数行且输出有效时 bayer_ypos=1，供后级选择对应的 Bayer 插值公式。
assign bayer_ypos_d0 = !v_cnt_d[0] & ch_valid;

/*********************************************************
******************6.模块实例化*****************************
*********************************************************/
// RAW10 -> 8 bit：输入一拍含 4 个 10-bit Bayer 样本，转换模块分别取 [9:2]。
// 也就是丢弃每个样本最低 2 bit，降低后续行缓存和计算所需的位宽。
mipi_to_raw_converter mipi_to_raw_converter_r0(
    .I_clk       (I_clk  ),              // 时钟信号
    .I_rst_n     (I_rst_n),              // 复位信号，低有效
    .I_raw_tdata (axi4s_video_tdata ),   // 输入原始数据
    .I_raw_tdest (axi4s_video_tdest ),   // 输入目的地地址
    .I_raw_tlast (axi4s_video_tlast ),   // 输入行结束信号
    .I_raw_tvalid(axi4s_video_tvalid),   // 输入数据有效信号
    .I_raw_tuser (axi4s_video_tuser),    // 输入帧开始信号
    .I_raw_tready(I_raw_tready  ),       // 转换模块向本级输入侧返回的 ready
    .O_raw_tdata (raw_data      ),       // 4×8-bit Bayer 数据
    .O_raw_tlast (O_raw_tlast_d0),       // 输出行结束信号
    .O_raw_tvalid(raw_data_valid),       // 输出数据有效信号
    .O_raw_tuser (O_raw_tuser_d0),       // 输出帧开始信号
    .O_raw_tready(1'b1)                  // 本级固定声明可以接收转换结果
);

// zhenghe 使用 BRAM 对输入流重新定时：把一行有效数据连续读出，
// 消除前级行间时序形式对后续固定行宽计数和行缓存的影响。
zhenghe#(
    .IMG_WIDTH ( IMG_WIDTH ),
    .IMG_HEIGHT( IMG_HEIGHT),
    .DATA_WIDTH( 32),
    .data_complete_delay (data_complete_delay)
) 
zhenghe_d(
    .I_clk    (I_clk   ),               // 时钟信号
    .I_rst_n  (I_rst_n ),               // 复位信号，低有效

    .I_tlast  (O_raw_tlast_d0 ),        // 输入行结束信号
    .I_tuser  (O_raw_tuser_d0 ),        // 输入帧开始信号
    .I_tdata  (raw_data ),              // 输入原始数据
    .I_tvalid (raw_data_valid),         // 输入数据有效信号

    .O_tlast  (zhenghe_tlast ),         // 输出合并后的行结束信号
    .O_tuser  (zhenghe_tuser ),         // 输出合并后的帧开始信号
    .O_tdata  (zhenghe_tdata ),         // 输出合并后的数据
    .O_tvalid (zhenghe_tvalid)          // 输出合并后的数据有效信号
);

// 串联两个单行 BRAM 缓冲器：
//   data[0]：最新到达的一行；
//   data[1]：比 data[0] 早一行；
//   data[2]：比 data[0] 早两行。
// 流式图像只能直接看到当前输入和历史数据，缓存两行后才能同时取得三行垂直邻域。
genvar i;
generate
    for(i=1; i<3; i=i+1)
    begin: two_line_buffer  // 模块命名为two_line_buffer
        line_buffer_demosaic #(
            .IMG_HEIGHT (IMG_HEIGHT),
            .IMG_WIDTH  (IMG_WIDTH )
        ) line_buffer_demosaic_r1 (
            .I_clk     ( I_clk      ),    // 时钟信号
            .I_rst_n   ( I_rst_n    ),    // 复位信号，低有效
            .I_tuser   ( data[i-1][32] & valid[i-1]), // 输入帧开始信号
            .I_valid   ( valid[i-1] ),    // 输入有效信号
            .I_data    ( data[i-1]  ),    // 输入数据
            .O_valid   ( valid[i]   ),    // 输出有效信号
            .O_data    ( data[i]    )     // 输出数据
        );           
    end        
endgenerate

// 两级 line_buffer 的 BRAM 各引入一拍读延迟。为让三路表示同一列位置：
//   data[0] 再延迟 2 拍 -> data_d0（最新行，窗口语义上的下一行）
//   data[1] 再延迟 1 拍 -> data_d1（中心行）
//   data[2] 不再延迟   -> data_d2（最早行，窗口语义上的上一行）
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        data_d0_d <= 0;
        data_d0   <= 0;
        data_d1   <= 0;
        valid_d0  <= 0;
        valid_d1  <= 0;
    end
    else begin
        valid_d0  <= valid[0];
        valid_d1  <= valid_d0;
        data_d0_d <= data[0];
        data_d0   <= data_d0_d;
        data_d1   <= data[1];
    end
end

assign data_d2 = data[2];
/*********************************************************
***********3x3矩阵的形成，以及对边界元素的补充处理***********
*********************************************************/

/*
 * 横向窗口的更新方式：{旧缓存低 64 bit, 本拍新到的 32 bit}。
 * 因而缓存中始终保留连续 12 个 8-bit Bayer 样本。bilinear_interpolation
 * 实际使用每行的 [71:24]，即 6 个连续样本：4 个待处理中心像素，加上
 * 左右各 1 个邻居，从而并行形成四组 3×3 邻域。
 *
 * 图像边界没有完整邻居，下面针对首行、第二行以及第三行以后分别处理：
 *   - 顶边：复制已有行，代替不存在的上一行；
 *   - 左边：复制首个有效像素，并在未使用的高位补 0；
 *   - 右边：复制末端像素，并在未使用的低位补 0。
 */

always @(posedge I_clk or negedge I_rst_n) begin 
    if(!I_rst_n) begin
        matrix_last_line_buffer <= 'b0 ;
        matrix_cur_line_buffer  <= 'b0 ;
        matrix_next_line_buffer <= 'b0 ;
    end else if(valid_d1) begin
        if(v_cnt == 0) begin  // 首行：三路都复制首行，避免引用尚不存在的历史行
            if(h_cnt == 0) begin  // 行首数据组：构造左边界
                matrix_last_line_buffer <= {{24{1'b0}}, data_d0[31:24], data_d0[31:0], data_d0[31:0]} ;
                matrix_cur_line_buffer  <= {{24{1'b0}}, data_d0[31:24], data_d0[31:0], data_d0[31:0]} ;
                matrix_next_line_buffer <= {{24{1'b0}}, data_d0[31:24], data_d0[31:0], data_d0[31:0]} ;
            end else if(h_cnt == (IMG_WIDTH_4x - 1)) begin  // 行尾数据组：构造右边界
                matrix_last_line_buffer <= {matrix_next_line_buffer [63:0], matrix_next_line_buffer[7:0], {24{1'b0}}} ;
                matrix_cur_line_buffer  <= {matrix_next_line_buffer [63:0], matrix_next_line_buffer[7:0], {24{1'b0}}} ;
                matrix_next_line_buffer <= {matrix_next_line_buffer [63:0], matrix_next_line_buffer[7:0], {24{1'b0}}} ;
            end else begin  // 中间数据组：左移旧数据并移入本拍 4 像素
                matrix_last_line_buffer <= {matrix_next_line_buffer[63:0], data_d0[31:0]} ;
                matrix_cur_line_buffer  <= {matrix_next_line_buffer[63:0], data_d0[31:0]} ;
                matrix_next_line_buffer <= {matrix_next_line_buffer[63:0], data_d0[31:0]} ;
            end
        end
        else if(v_cnt == 1) begin  // 第二行：上一行与中心行均取首行，下一行取第二行
            if(h_cnt == 0) begin  // 行首数据组：构造左边界
                matrix_last_line_buffer <= {{24{1'b0}}, data_d1[31:24], data_d1[31:0], data_d1[31:0]} ;
                matrix_cur_line_buffer  <= {{24{1'b0}}, data_d1[31:24], data_d1[31:0], data_d1[31:0]} ;
                matrix_next_line_buffer <= {{24{1'b0}}, data_d0[31:24], data_d0[31:0], data_d0[31:0]} ;
            end else if(h_cnt == (IMG_WIDTH_4x - 1)) begin  // 行尾数据组：构造右边界
                matrix_last_line_buffer <= {matrix_cur_line_buffer [63:0], matrix_cur_line_buffer[7:0], {24{1'b0}}} ;
                matrix_cur_line_buffer  <= {matrix_cur_line_buffer [63:0], matrix_cur_line_buffer[7:0], {24{1'b0}}} ;
                matrix_next_line_buffer <= {matrix_next_line_buffer [63:0], matrix_next_line_buffer[7:0], {24{1'b0}}} ;
            end else begin  // 中间数据组：三行缓存继续横向滑动
                matrix_last_line_buffer <= {matrix_cur_line_buffer[63:0],  data_d1[31:0]} ;
                matrix_cur_line_buffer  <= {matrix_cur_line_buffer[63:0],  data_d1[31:0]} ;
                matrix_next_line_buffer <= {matrix_next_line_buffer[63:0], data_d0[31:0]} ;
            end
        end
        else begin  // 第三行及以后：三路分别使用 data_d2、data_d1、data_d0
            if(h_cnt == 0) begin  // 行首数据组：构造左边界
                matrix_last_line_buffer <= {{24{1'b0}}, data_d2[31:24], data_d2[31:0], data_d2[31:0]} ;
                matrix_cur_line_buffer  <= {{24{1'b0}}, data_d1[31:24], data_d1[31:0], data_d1[31:0]} ;
                matrix_next_line_buffer <= {{24{1'b0}}, data_d0[31:24], data_d0[31:0], data_d0[31:0]} ;
            end else if(h_cnt == (IMG_WIDTH_4x - 1)) begin  // 行尾数据组：构造右边界
                matrix_last_line_buffer <= {matrix_last_line_buffer[63:0], matrix_last_line_buffer[7:0], {24{1'b0}}} ;
                matrix_cur_line_buffer  <= {matrix_cur_line_buffer [63:0], matrix_cur_line_buffer [7:0], {24{1'b0}}} ;
                matrix_next_line_buffer <= {matrix_next_line_buffer[63:0], matrix_next_line_buffer[7:0], {24{1'b0}}} ;
            end else begin  // 中间数据组：每条缓存移入对应行的 4 个新像素
                matrix_last_line_buffer <= {matrix_last_line_buffer[63:0], data_d2[31:0]} ;
                matrix_cur_line_buffer  <= {matrix_cur_line_buffer [63:0], data_d1[31:0]} ;
                matrix_next_line_buffer <= {matrix_next_line_buffer[63:0], data_d0[31:0]} ;
            end  
        end
    end
    else begin
        // 矩阵仅在有效拍保留有意义的数据；无效期间清零，避免旧窗口被误用。
        matrix_last_line_buffer <= 'b0 ;
        matrix_cur_line_buffer  <= 'b0 ;
        matrix_next_line_buffer <= 'b0 ;
    end 
end

// 图像位置计数：
// h_cnt 每个有效拍加 1，范围 0~IMG_WIDTH/4-1；到达行尾后清零并令 v_cnt 加 1。
// v_cnt 以行为单位，范围 0~IMG_HEIGHT-1；tuser 到来时两个计数器同时回到帧首。
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n || zhenghe_tuser) begin
        h_cnt <= 0;
        v_cnt <= 0;
    end else begin
        h_cnt    <= valid_d1 ? ((h_cnt == IMG_WIDTH_4x - 1) ? 0 : h_cnt + 1) : h_cnt;
        v_cnt    <= valid_d1 && (h_cnt == IMG_WIDTH_4x - 1) ? ((v_cnt == IMG_HEIGHT - 1) ? 0 : v_cnt + 1) : v_cnt;
    end
end

// 再寄存一拍，使有效标志、行号奇偶信息与上面时序 always 块产生的矩阵数据对齐。
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin
        ch_valid <= 0;
        v_cnt_d <= 0;
    end else begin
        ch_valid <= valid_d1 ;
        v_cnt_d  <= v_cnt;
    end
end

assign bayer_ypos = bayer_ypos_d0 ;

// zhenghe 的 tuser/tlast 再延迟三级，与邻域生成通路的固定流水线延迟对齐。
// 这样后级在 O_tvalid=1 时，可同时使用矩阵数据及对应的帧首/行尾标志。
always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        tlast_d0 <= 0;
        tlast_d1 <= 0;
        tlast_d2 <= 0;
        tuser_d0 <= 0;
        tuser_d1 <= 0;
        tuser_d2 <= 0;
    end
    else begin
        tlast_d0 <= zhenghe_tlast;
        tlast_d1 <= tlast_d0;
        tlast_d2 <= tlast_d1;
        tuser_d0 <= zhenghe_tuser;
        tuser_d1 <= tuser_d0;
        tuser_d2 <= tuser_d1;
    end
end

// 输出已对齐的流控制信号。
assign O_tuser  = tuser_d2;
assign O_tlast  = tlast_d2;
assign O_tvalid = ch_valid;


endmodule


