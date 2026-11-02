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
@Time        :   2025/8 
version:     :   2.0
@Description :   由于RGGB和GBRG的Bayer格式中的三元操作符的条件判断分支是颠倒的，
                 导致在需要插值的地方使用了原始值，在有原始值的地方进行了错误的
                 平均，现在重写修改了此处，让其正确的去进行平均。
*****************************************************************/

/*
 * bilinear_interpolation：Bayer RAW 双线性去马赛克模块。
 *
 * 输入不是原始串行像素，而是 raw_matrix_3x3_buffer 已经准备好的三行邻域。
 * 本模块一拍并行处理中心行上的 4 个像素，根据 BAYER_MODE、行奇偶以及
 * 4 个像素各自的列奇偶，判断中心点原本是 R、G 还是 B，然后补齐缺失分量：
 *
 *   中心点为 R：R 取原值，G 取十字方向平均，B 取四个对角方向平均；
 *   中心点为 B：B 取原值，G 取十字方向平均，R 取四个对角方向平均；
 *   中心点为 G：G 取原值，R/B 分别取水平方向或垂直方向两个同色点的平均。
 *
 * 加法、平均、限幅和 RGB 打包被拆成多级寄存器，以降低组合逻辑路径。
 * 输出一拍共 4 个 32-bit 像素，每个像素格式为 {8'b0, R8, G8, B8}。
 */

module bilinear_interpolation #(
    // 传感器 Bayer 排列，只能取 "RGGB"、"BGGR"、"GBRG"、"GRBG" 之一。
    parameter BAYER_MODE = "BGGR"
)(
    input             I_clk            , // 像素流处理时钟
    input             I_rst_n          , // 异步复位，低有效

    // 输入流控制信号，均应与三行邻域数据对齐
    input             I_tlast          , // 当前拍为一行最后一组像素
    input             I_tuser          , // 当前拍为一帧第一组像素
    input             I_tvalid         , // 输入邻域有效
    output            I_tready         , // 向上游返回的就绪信号
  
    input             bayer_ypos       , // 中心行的奇偶相位，由窗口模块产生
    input   [95:0]    matrix_last_line , // 上一行横向邻域缓存
    input   [95:0]    matrix_cur_line  , // 中心行横向邻域缓存
    input   [95:0]    matrix_next_line , // 下一行横向邻域缓存
  
    // 输出：一拍 4 个 RGB888 像素，每个像素占 32 bit
    output            O_tlast         , // 与输出 RGB 数据对齐的行结束标志
    output            O_tuser         , // 与输出 RGB 数据对齐的帧开始标志
    output [127 : 0]  O_tdata         , // {pixel3, pixel2, pixel1, pixel0}
    output            O_tvalid        , // 输出 RGB 数据有效
    input             O_tready          // 下游就绪信号

);

/*********************************************************
                  function 声明
*********************************************************/
// 计算表示 depth 所需的位数；当前版本没有调用，属于原工程保留函数。
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
                      RAW格式
*********************************************************/
// 四种常见的 2×2 Bayer 颜色排列。
localparam RGGB = "RGGB";
localparam BGGR = "BGGR";
localparam GBRG = "GBRG";
localparam GRBG = "GRBG";



/*********************************************************
                       reg 信号声明
*********************************************************/
// 行奇偶相位延迟两拍，与后面的加法结果保持一致。
reg         bayer_ypos_r0,  bayer_ypos_r1;

// 每个颜色最终最多累加 4 个 8-bit 邻居，故使用 10 bit 防止溢出。
// 名称中的 0~3 表示本拍并行处理的第 0~3 个输出像素。
reg [9:0]   r0_matrix_plus, g0_matrix_plus, b0_matrix_plus ;
reg [9:0]   r1_matrix_plus, g1_matrix_plus, b1_matrix_plus ;
reg [9:0]   r2_matrix_plus, g2_matrix_plus, b2_matrix_plus ;
reg [9:0]   r3_matrix_plus, g3_matrix_plus, b3_matrix_plus ;
// -----------------------------------------------------------------

// 第一级局部和：每项最多为两个 8-bit 像素之和，因此需要 9 bit。
reg [8:0]   r0_sum_part0, r0_sum_part1 ;
reg [8:0]   r1_sum_part0, r1_sum_part1 ;
reg [8:0]   r2_sum_part0, r2_sum_part1 ;
reg [8:0]   r3_sum_part0, r3_sum_part1 ;

reg [8:0]   g0_sum_part0, g0_sum_part1 ;
reg [8:0]   g1_sum_part0, g1_sum_part1 ;
reg [8:0]   g2_sum_part0, g2_sum_part1 ;
reg [8:0]   g3_sum_part0, g3_sum_part1 ;

reg [8:0]   b0_sum_part0, b0_sum_part1 ;
reg [8:0]   b1_sum_part0, b1_sum_part1 ;
reg [8:0]   b2_sum_part0, b2_sum_part1 ;
reg [8:0]   b3_sum_part0, b3_sum_part1 ;

// -----------------------------------------------------------------
// 移位除以 2 或 4 后的插值结果，保留第 9 位用于后续饱和判断。
reg [8:0]   r0_mean, g0_mean, b0_mean ;
reg [8:0]   r1_mean, g1_mean, b1_mean ;
reg [8:0]   r2_mean, g2_mean, b2_mean ;
reg [8:0]   r3_mean, g3_mean, b3_mean ;
// -----------------------------------------------------------------
// 四个已经打包的 32-bit RGB 输出像素。
reg [31:0] rgb_data0 ;
reg [31:0] rgb_data1 ;
reg [31:0] rgb_data2 ;
reg [31:0] rgb_data3 ;

// 流控制信号延迟链，用来匹配插值数据的多级流水线。
reg   [4:0]   I_tlast_r ;
reg   [4:0]   I_tuser_r ;
reg   [4:0]   I_tvalid_r;
/*********************************************************
                    wire 信号声明
*********************************************************/

// 三行 × 六列有效邻域像素。
// 命名 matrixRC 中：R=0/1/2 分别代表上一/中心/下一行；
// C=3~8 表示连续六列。四个输出中心依次为 matrix14、15、16、17，
// matrix13 和 matrix18 分别提供最左、最右的额外邻居：
//
//            左邻居   输出0   输出1   输出2   输出3   右邻居
// 上一行： matrix03 matrix04 matrix05 matrix06 matrix07 matrix08
// 中心行： matrix13 matrix14 matrix15 matrix16 matrix17 matrix18
// 下一行： matrix23 matrix24 matrix25 matrix26 matrix27 matrix28
wire    [7:0]   matrix03, matrix04, matrix05, matrix06, matrix07, matrix08 ;
wire    [7:0]   matrix13, matrix14, matrix15, matrix16, matrix17, matrix18 ;
wire    [7:0]   matrix23, matrix24, matrix25, matrix26, matrix27, matrix28 ;


wire    [127:0] rgb_data;
wire            rgb_data_valid ; // 原工程预留，当前版本未使用
/*********************************************************
                        信号描述
*********************************************************/
// 窗口模块每行提供 96 bit 历史数据；这里只取中间 48 bit，即计算所需的六列。
assign {matrix03, matrix04, matrix05, matrix06, matrix07, matrix08} = matrix_last_line[71:24];
assign {matrix13, matrix14, matrix15, matrix16, matrix17, matrix18} = matrix_cur_line[71:24];
assign {matrix23, matrix24, matrix25, matrix26, matrix27, matrix28} = matrix_next_line[71:24];



/*********************************************************
                        信号延迟
*********************************************************/
// 行相位同步流水线。具体颜色分支的平均除法发生在两拍之后，因此同步延迟两拍。
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin 
        bayer_ypos_r0 <= 'b0 ;
        bayer_ypos_r1 <= 'b0 ;
    end
    else begin
        bayer_ypos_r0 <= bayer_ypos ;
        bayer_ypos_r1 <= bayer_ypos_r0 ;
    end
end

/*****************************************************************
                        BAYER_MODE_BGGR                                        
*****************************************************************/

/*
 * 双线性插值的硬件实现规律：
 *   两点平均：(a+b)/2，先加法，再右移 1 bit；
 *   四点平均：(a+b+c+d)/4，先分两组相加，再汇总并右移 2 bit；
 *   原始分量：直接取中心像素，不做平均。
 * 移位代替除法，不需要除法器，适合 FPGA 流水线实现。
 */
generate if(BAYER_MODE == BGGR) begin : BAYER_MODE_BGGR
    // Stage14: store geometry once, then select RGB in stage two.
    // Only the two non-green centers need diagonals in a Bayer row. Select
    // their columns before adding, instead of building both phase variants.
    // 4 horizontal + 4 vertical + 4 diagonal partial sums + 4 native values:
    // 140 declared bits versus the former 20 x 9 = 180 in this BGGR stage.
    reg [8:0] h0,h1,h2,h3,v0,v1,v2,v3,d0t,d0b,d1t,d1b;
    reg [7:0] c0,c1,c2,c3;
    wire [7:0] dt_left0=bayer_ypos?matrix04:matrix03;
    wire [7:0] dt_mid=bayer_ypos?matrix06:matrix05;
    wire [7:0] dt_right1=bayer_ypos?matrix08:matrix07;
    wire [7:0] db_left0=bayer_ypos?matrix24:matrix23;
    wire [7:0] db_mid=bayer_ypos?matrix26:matrix25;
    wire [7:0] db_right1=bayer_ypos?matrix28:matrix27;
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            h0<=0;h1<=0;h2<=0;h3<=0;v0<=0;v1<=0;v2<=0;v3<=0;
            d0t<=0;d0b<=0;d1t<=0;d1b<=0;c0<=0;c1<=0;c2<=0;c3<=0;
        end else if(I_tvalid) begin
            h0<={1'b0,matrix13}+{1'b0,matrix15};
            h1<={1'b0,matrix14}+{1'b0,matrix16};
            h2<={1'b0,matrix15}+{1'b0,matrix17};
            h3<={1'b0,matrix16}+{1'b0,matrix18};
            v0<={1'b0,matrix04}+{1'b0,matrix24};
            v1<={1'b0,matrix05}+{1'b0,matrix25};
            v2<={1'b0,matrix06}+{1'b0,matrix26};
            v3<={1'b0,matrix07}+{1'b0,matrix27};
            d0t<={1'b0,dt_left0}+{1'b0,dt_mid};
            d0b<={1'b0,db_left0}+{1'b0,db_mid};
            d1t<={1'b0,dt_mid}+{1'b0,dt_right1};
            d1b<={1'b0,db_mid}+{1'b0,db_right1};
            c0<=matrix14;c1<=matrix15;c2<=matrix16;c3<=matrix17;
        end
    end
    // The original phase pipeline advances even in invalid cycles. Its first
    // stage corresponds to these partial sums on every enabled stage-two edge.
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {r0_matrix_plus,g0_matrix_plus,b0_matrix_plus}<=0;
            {r1_matrix_plus,g1_matrix_plus,b1_matrix_plus}<=0;
            {r2_matrix_plus,g2_matrix_plus,b2_matrix_plus}<=0;
            {r3_matrix_plus,g3_matrix_plus,b3_matrix_plus}<=0;
        end else if(I_tvalid_r[0]) begin
            if(bayer_ypos_r0) begin
                r0_matrix_plus<=h0;r1_matrix_plus<=c1;r2_matrix_plus<=h2;r3_matrix_plus<=c3;
                g0_matrix_plus<=c0;g1_matrix_plus<={1'b0,h1}+{1'b0,v1};
                g2_matrix_plus<=c2;g3_matrix_plus<={1'b0,h3}+{1'b0,v3};
                b0_matrix_plus<=v0;b1_matrix_plus<={1'b0,d0t}+{1'b0,d0b};
                b2_matrix_plus<=v2;b3_matrix_plus<={1'b0,d1t}+{1'b0,d1b};
            end else begin
                r0_matrix_plus<={1'b0,d0t}+{1'b0,d0b};r1_matrix_plus<=v1;
                r2_matrix_plus<={1'b0,d1t}+{1'b0,d1b};r3_matrix_plus<=v3;
                g0_matrix_plus<={1'b0,h0}+{1'b0,v0};g1_matrix_plus<=c1;
                g2_matrix_plus<={1'b0,h2}+{1'b0,v2};g3_matrix_plus<=c3;
                b0_matrix_plus<=c0;b1_matrix_plus<=h1;b2_matrix_plus<=c2;b3_matrix_plus<=h3;
            end
        end
    end

    // 第三级：按当前位置需要的样本数求平均。
    // >>1 相当于除以2，>>2 相当于除以4；不移位表示保留传感器原始分量。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {r0_mean, g0_mean, b0_mean} <= 'd0 ;
            {r1_mean, g1_mean, b1_mean} <= 'd0 ;
            {r2_mean, g2_mean, b2_mean} <= 'd0 ;
            {r3_mean, g3_mean, b3_mean} <= 'd0 ;
        end
        else if(I_tvalid_r[1]) begin
            r0_mean <= bayer_ypos_r1 ? r0_matrix_plus >> 1 : r0_matrix_plus >> 2 ;
            g0_mean <= bayer_ypos_r1 ? g0_matrix_plus      : g0_matrix_plus >> 2 ;
            b0_mean <= bayer_ypos_r1 ? b0_matrix_plus >> 1 : b0_matrix_plus      ;

            r1_mean <= bayer_ypos_r1 ? r1_matrix_plus      : r1_matrix_plus >> 1 ;
            g1_mean <= bayer_ypos_r1 ? g1_matrix_plus >> 2 : g1_matrix_plus ;
            b1_mean <= bayer_ypos_r1 ? b1_matrix_plus >> 2 : b1_matrix_plus >> 1 ;

            r2_mean <= bayer_ypos_r1 ? r2_matrix_plus >> 1 : r2_matrix_plus >> 2;
            g2_mean <= bayer_ypos_r1 ? g2_matrix_plus      : g2_matrix_plus >> 2;   
            b2_mean <= bayer_ypos_r1 ? b2_matrix_plus >> 1 : b2_matrix_plus ;

            r3_mean <= bayer_ypos_r1 ? r3_matrix_plus      : r3_matrix_plus >> 1 ;
            g3_mean <= bayer_ypos_r1 ? g3_matrix_plus >> 2 : g3_matrix_plus ;
            b3_mean <= bayer_ypos_r1 ? b3_matrix_plus >> 2 : b3_matrix_plus >> 1 ;
        end
    end
end


/*****************************************************************
                        BAYER_MODE_GBRG                                             
*****************************************************************/



    else if(BAYER_MODE == GBRG)
    begin:BAYER_MODE_GBRG

    // GBRG 分支：bayer_ypos=1 时中心四点为 R-G-R-G，=0 时为 G-B-G-B。

    // 第一级：选择 R 分量的原值或同色邻居，产生局部和。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {r0_sum_part0, r0_sum_part1} <= 'd0 ; 
            {r1_sum_part0, r1_sum_part1}  <= 'd0 ; 
            r2_sum_part0  <= 'd0 ; 
            {r3_sum_part0, r3_sum_part1}  <= 'd0 ; 
        end
        else if(I_tvalid)begin
            if(bayer_ypos) begin
                r0_sum_part0 <= matrix14 ;
                r0_sum_part1 <= 'd0;

                r1_sum_part0 <= matrix14 + matrix16;
                r1_sum_part1 <= 'd0;

                r2_sum_part0 <= matrix16;

                r3_sum_part0 <= matrix16 + matrix18 ;
                r3_sum_part1 <= 'd0;
            end
            else begin
                r0_sum_part0 <= 'd0;
                r0_sum_part1 <= matrix04 + matrix24;

                r1_sum_part0 <= matrix04 + matrix06 ;
                r1_sum_part1 <= matrix24 + matrix26 ;

                r2_sum_part0 <= matrix06 + matrix26 ;

                r3_sum_part0 <= matrix06 + matrix26 ;
                r3_sum_part1 <= matrix08 + matrix28 ;
            end
        end
    end
    // 第一级：选择 G 分量；G 中心保留原值，R/B 中心取十字方向四点和。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {g0_sum_part0, g0_sum_part1} <= 'b0 ;
            {g1_sum_part0, g1_sum_part1} <= 'b0 ;
            {g2_sum_part0, g2_sum_part1} <= 'b0 ;
            {g3_sum_part0, g3_sum_part1} <= 'b0 ;
        end
        else if(I_tvalid)begin
            if(bayer_ypos) begin
                g0_sum_part0 <= matrix04 + matrix24;
                g0_sum_part1 <= matrix13 + matrix15;

                g1_sum_part0 <= matrix15;
                g1_sum_part1 <= 'd0 ;

                g2_sum_part0 <= matrix06 + matrix26 ;
                g2_sum_part1 <= matrix15 + matrix17 ;

                g3_sum_part0 <= matrix17  ; 
                g3_sum_part1 <= 'd0 ;
            end
            else begin
                g0_sum_part0 <= matrix14 ;
                g0_sum_part1 <= 'd0;

                g1_sum_part0 <= matrix05 + matrix25;
                g1_sum_part1 <= matrix14 + matrix16;

                g2_sum_part0 <= matrix16 ;
                g2_sum_part1 <= 'd0;

                g3_sum_part0 <= matrix07 + matrix27; 
                g3_sum_part1 <= matrix16 + matrix18;
            end
        end
    end
    // 第一级：选择 B 分量；根据中心颜色取原值、两个同色邻居或四个对角邻居。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {b0_sum_part0, b0_sum_part1} <= 'd0 ;
            {b1_sum_part0, b1_sum_part1} <= 'd0 ;
            {b2_sum_part0, b2_sum_part1} <= 'd0 ;
            {b3_sum_part0, b3_sum_part1} <= 'd0 ;
        end
        else if(I_tvalid)begin
            if(bayer_ypos) begin
                b0_sum_part0 <= matrix03 + matrix23 ; // 左上、左下 B 像素之和
                b0_sum_part1 <= matrix05 + matrix25 ; // 右上、右下 B 像素之和

                b1_sum_part0 <= 'd0;
                b1_sum_part1 <= matrix05 + matrix25 ; // 上、下两个 B 像素

                b2_sum_part0 <= matrix05 + matrix25 ;
                b2_sum_part1 <= matrix07 + matrix27 ;

                b3_sum_part0 <= 'd0 ;
                b3_sum_part1 <= matrix07 + matrix27 ; // 上、下两个 B 像素
            end
            else begin
                b0_sum_part0 <= matrix13 + matrix15 ;
                b0_sum_part1 <= 'd0;

                b1_sum_part0 <= matrix15 ;
                b1_sum_part1 <= 'd0 ;

                b2_sum_part0 <= matrix15 +  matrix17;
                b2_sum_part1 <= 'd0;

                b3_sum_part0 <= matrix17 ;
                b3_sum_part1 <= 'd0 ;
            end
        end
    end

    // 第二级：合并两个局部和，得到各颜色的候选总和。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {r0_matrix_plus, g0_matrix_plus, b0_matrix_plus} <= 'd0 ;
            {r1_matrix_plus, g1_matrix_plus, b1_matrix_plus} <= 'd0 ;
            {r2_matrix_plus, g2_matrix_plus, b2_matrix_plus} <= 'd0 ;
            {r3_matrix_plus, g3_matrix_plus, b3_matrix_plus} <= 'd0 ;
        end
        else if(I_tvalid_r[0])begin
            r0_matrix_plus <= r0_sum_part0 + r0_sum_part1 ;
            r1_matrix_plus <= r1_sum_part0 + r1_sum_part1 ;
            r2_matrix_plus <= r2_sum_part0   ;
            r3_matrix_plus <= r3_sum_part0 + r3_sum_part1 ;

            g0_matrix_plus <= g0_sum_part0 + g0_sum_part1 ;
            g1_matrix_plus <= g1_sum_part0 + g1_sum_part1 ;
            g2_matrix_plus <= g2_sum_part0 + g2_sum_part1 ;
            g3_matrix_plus <= g3_sum_part0 + g3_sum_part1 ;

            b0_matrix_plus <= b0_sum_part0 + b0_sum_part1 ;
            b1_matrix_plus <= b1_sum_part0 + b1_sum_part1 ;
            b2_matrix_plus <= b2_sum_part0 + b2_sum_part1 ;
            b3_matrix_plus <= b3_sum_part0 + b3_sum_part1 ;
        end
    end


    // 第三级：根据当前行相位选择原值、二点平均或四点平均。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {r0_mean, g0_mean, b0_mean} <= 'd0 ;
            {r1_mean, g1_mean, b1_mean} <= 'd0 ;
            {r2_mean, g2_mean, b2_mean} <= 'd0 ;
            {r3_mean, g3_mean, b3_mean} <= 'd0 ;
        end
        else if(I_tvalid_r[1])begin
            r0_mean <= bayer_ypos_r1    ? r0_matrix_plus      : r0_matrix_plus >> 1 ;
            g0_mean <= (!bayer_ypos_r1) ? g0_matrix_plus      : g0_matrix_plus >> 2 ;
            b0_mean <= bayer_ypos_r1    ? b0_matrix_plus >> 2 : b0_matrix_plus >> 1 ;

            r1_mean <= bayer_ypos_r1    ? r1_matrix_plus >> 1 : r1_matrix_plus >> 2 ;
            g1_mean <= (!bayer_ypos_r1) ? g1_matrix_plus >> 2 : g1_matrix_plus      ;
            b1_mean <= bayer_ypos_r1 ? b1_matrix_plus >> 1 : b1_matrix_plus      ;

            r2_mean <= bayer_ypos_r1    ? r2_matrix_plus      : r2_matrix_plus >> 1 ;
            g2_mean <= (!bayer_ypos_r1) ? g2_matrix_plus      : g2_matrix_plus >> 2 ;   
            b2_mean <= bayer_ypos_r1    ? b2_matrix_plus >> 2 : b2_matrix_plus >> 1 ;

            r3_mean <= bayer_ypos_r1    ? r3_matrix_plus >> 1 : r3_matrix_plus >> 2 ;
            g3_mean <= (!bayer_ypos_r1) ? g3_matrix_plus >> 2 : g3_matrix_plus      ;
            b3_mean <= bayer_ypos_r1    ? b3_matrix_plus >> 1 : b3_matrix_plus      ;
        end
    end
end

/*****************************************************************
                       BAYER_MODE_RGGB                             
*****************************************************************/

    else if(BAYER_MODE == RGGB)
    begin:BAYER_MODE_RGGB

    // RGGB 分支：bayer_ypos=1 时中心四点为 G-B-G-B，=0 时为 R-G-R-G。

    // 第一级：选择 R 分量的原值或同色邻居，产生局部和。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {r0_sum_part0, r0_sum_part1} <= 'd0 ; 
            {r1_sum_part0, r1_sum_part1}  <= 'd0 ; 
            r2_sum_part0  <= 'd0 ; 
            {r3_sum_part0, r3_sum_part1}  <= 'd0 ; 
        end
        else if(I_tvalid)begin
            if(bayer_ypos) begin
                r0_sum_part0 <= matrix04 + matrix24;//
                r0_sum_part1 <= 'd0;

                r1_sum_part0 <= matrix04 + matrix24;
                r1_sum_part1 <= matrix06 + matrix26;

                r2_sum_part0 <= matrix06 + matrix26;

                r3_sum_part0 <= matrix06 + matrix26;
                r3_sum_part1 <= matrix08 + matrix28;
            end
            else begin
                r0_sum_part0 <= matrix14;
                r0_sum_part1 <= 'd0;

                r1_sum_part0 <= matrix14 + matrix16;
                r1_sum_part1 <= 'd0;

                r2_sum_part0 <= matrix16  ;

                r3_sum_part0 <= matrix16 + matrix18 ;
                r3_sum_part1 <= 'd0 ;
            end
        end
    end
    // 第一级：选择 G 分量；G 中心保留原值，R/B 中心取十字方向四点和。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {g0_sum_part0, g0_sum_part1} <= 'b0 ;
            {g1_sum_part0, g1_sum_part1} <= 'b0 ;
            {g2_sum_part0, g2_sum_part1} <= 'b0 ;
            {g3_sum_part0, g3_sum_part1} <= 'b0 ;
        end
        else if(I_tvalid)begin
            if(bayer_ypos) begin
                g0_sum_part0 <= matrix14 ;
                g0_sum_part1 <= 'd0;

                g1_sum_part0 <= matrix05 + matrix25;
                g1_sum_part1 <= matrix14 + matrix16;

                g2_sum_part0 <= matrix16 ;
                g2_sum_part1 <= 'd0;

                g3_sum_part0 <= matrix07 + matrix27; 
                g3_sum_part1 <= matrix16 + matrix18;
            end
            else begin
                g0_sum_part0 <= matrix04 + matrix24;
                g0_sum_part1 <= matrix13 + matrix15;

                g1_sum_part0 <= matrix15;
                g1_sum_part1 <= 'd0 ;

                g2_sum_part0 <= matrix06 + matrix26 ;
                g2_sum_part1 <= matrix15 + matrix17 ;

                g3_sum_part0 <= matrix17  ; 
                g3_sum_part1 <= 'd0 ;
            end
        end
    end
    // 第一级：选择 B 分量；根据中心颜色取原值、两个同色邻居或四个对角邻居。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {b0_sum_part0, b0_sum_part1} <= 'd0 ;
            {b1_sum_part0, b1_sum_part1} <= 'd0 ;
            {b2_sum_part0, b2_sum_part1} <= 'd0 ;
            {b3_sum_part0, b3_sum_part1} <= 'd0 ;
        end
        else if(I_tvalid)begin
            if(bayer_ypos) begin
                b0_sum_part0 <= matrix13 + matrix15 ;
                b0_sum_part1 <= 'd0;

                b1_sum_part0 <= matrix15 ;
                b1_sum_part1 <= 'd0 ;

                b2_sum_part0 <= matrix15 +  matrix17;
                b2_sum_part1 <= 'd0;

                b3_sum_part0 <= matrix17 ;
                b3_sum_part1 <= 'd0 ;
            end
            else begin
                b0_sum_part0 <= matrix03 + matrix23 ; // 左上、左下 B 像素之和
                b0_sum_part1 <= matrix05 + matrix25 ; // 右上、右下 B 像素之和

                b1_sum_part0 <= 'd0;
                b1_sum_part1 <= matrix05 + matrix25 ; // 上、下两个 B 像素

                b2_sum_part0 <= matrix05 + matrix25 ;
                b2_sum_part1 <= matrix07 + matrix27 ;

                b3_sum_part0 <= 'd0 ;
                b3_sum_part1 <= matrix07 + matrix27 ; // 上、下两个 B 像素
            end
        end
    end

    // 第二级：合并两个局部和，得到各颜色的候选总和。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {r0_matrix_plus, g0_matrix_plus, b0_matrix_plus} <= 'd0 ;
            {r1_matrix_plus, g1_matrix_plus, b1_matrix_plus} <= 'd0 ;
            {r2_matrix_plus, g2_matrix_plus, b2_matrix_plus} <= 'd0 ;
            {r3_matrix_plus, g3_matrix_plus, b3_matrix_plus} <= 'd0 ;
        end
        else if(I_tvalid_r[0])begin
            r0_matrix_plus <= r0_sum_part0 + r0_sum_part1 ;
            r1_matrix_plus <= r1_sum_part0 + r1_sum_part1 ;
            r2_matrix_plus <= r2_sum_part0   ;
            r3_matrix_plus <= r3_sum_part0 + r3_sum_part1 ;

            g0_matrix_plus <= g0_sum_part0 + g0_sum_part1 ;
            g1_matrix_plus <= g1_sum_part0 + g1_sum_part1 ;
            g2_matrix_plus <= g2_sum_part0 + g2_sum_part1 ;
            g3_matrix_plus <= g3_sum_part0 + g3_sum_part1 ;

            b0_matrix_plus <= b0_sum_part0 + b0_sum_part1 ;
            b1_matrix_plus <= b1_sum_part0 + b1_sum_part1 ;
            b2_matrix_plus <= b2_sum_part0 + b2_sum_part1 ;
            b3_matrix_plus <= b3_sum_part0 + b3_sum_part1 ;
        end
    end


    // 第三级：根据当前行相位选择原值、二点平均或四点平均。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {r0_mean, g0_mean, b0_mean} <= 'd0 ;
            {r1_mean, g1_mean, b1_mean} <= 'd0 ;
            {r2_mean, g2_mean, b2_mean} <= 'd0 ;
            {r3_mean, g3_mean, b3_mean} <= 'd0 ;
        end
        else if(I_tvalid_r[1])begin
            r0_mean <= (!bayer_ypos_r1) ? r0_matrix_plus      : r0_matrix_plus >> 1 ;
            g0_mean <= bayer_ypos_r1    ? g0_matrix_plus      : g0_matrix_plus >> 2 ;
            b0_mean <= (!bayer_ypos_r1) ? b0_matrix_plus >> 2 : b0_matrix_plus >> 1 ;

            r1_mean <= (!bayer_ypos_r1) ? r1_matrix_plus >> 1 : r1_matrix_plus >> 2 ;
            g1_mean <= bayer_ypos_r1    ? g1_matrix_plus >> 2 : g1_matrix_plus      ;
            b1_mean <= (!bayer_ypos_r1) ? b1_matrix_plus >> 1 : b1_matrix_plus      ;

            r2_mean <= (!bayer_ypos_r1) ? r2_matrix_plus      : r2_matrix_plus >> 1 ;
            g2_mean <= bayer_ypos_r1    ? g2_matrix_plus      : g2_matrix_plus >> 2 ;   
            b2_mean <= (!bayer_ypos_r1) ? b2_matrix_plus >> 2 : b2_matrix_plus >> 1 ;

            r3_mean <= (!bayer_ypos_r1) ? r3_matrix_plus >> 1 : r3_matrix_plus >> 2 ;
            g3_mean <= bayer_ypos_r1    ? g3_matrix_plus >> 2 : g3_matrix_plus      ;
            b3_mean <= (!bayer_ypos_r1) ? b3_matrix_plus >> 1 : b3_matrix_plus      ;
        end
    end
end


/*****************************************************************
                       BAYER_MODE_GRBG                             
*****************************************************************/


    else if(BAYER_MODE == GRBG)
    begin:BAYER_MODE_GRBG

    // GRBG 分支：bayer_ypos=1 时中心四点为 B-G-B-G，=0 时为 G-R-G-R。

    // 第一级：选择 R 分量的原值或同色邻居，产生局部和。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {r0_sum_part0, r0_sum_part1} <= 'd0 ; 
            {r1_sum_part0, r1_sum_part1}  <= 'd0 ; 
            {r2_sum_part0, r2_sum_part1} <= 'd0 ; 
            {r3_sum_part0, r3_sum_part1}  <= 'd0 ; 
        end
        else if(I_tvalid)begin
            if(bayer_ypos) begin
                r0_sum_part0 <= matrix03 + matrix05 ;
                r0_sum_part1 <= matrix23 + matrix25 ;

                r1_sum_part0 <= matrix05 + matrix25 ;
                r1_sum_part1 <= 'd0;

                r2_sum_part0 <= matrix05 + matrix07 ;
                r2_sum_part1 <= matrix25 + matrix27 ;

                r3_sum_part0 <= matrix07 + matrix27 ;       
                r3_sum_part1 <= 'd0 ;                                                                 
            end
            else begin
                r0_sum_part0 <= matrix13 + matrix15 ;
                r0_sum_part1 <= 'd0 ;

                r1_sum_part0 <= matrix15 ;
                r1_sum_part1 <= 'd0;

                r2_sum_part0 <= matrix15 + matrix17 ;
                r2_sum_part1 <= 'd0 ;

                r3_sum_part0 <= matrix17 ;
                r3_sum_part1 <= 'd0 ;  
            end
        end
    end
    // 第一级：选择 G 分量；G 中心保留原值，R/B 中心取十字方向四点和。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {g0_sum_part0, g0_sum_part1} <= 'b0 ;
            {g1_sum_part0, g1_sum_part1} <= 'b0 ;
            {g2_sum_part0, g2_sum_part1} <= 'b0 ;
            {g3_sum_part0, g3_sum_part1} <= 'b0 ;
        end
        else if(I_tvalid)begin
            if(bayer_ypos) begin
                g0_sum_part0 <= matrix04 + matrix24;
                g0_sum_part1 <= matrix13 + matrix15;

                g1_sum_part0 <= matrix15;
                g1_sum_part1 <= 'd0 ;

                g2_sum_part0 <= matrix06 + matrix26 ;
                g2_sum_part1 <= matrix15 + matrix17 ;

                g3_sum_part0 <= matrix17  ; 
                g3_sum_part1 <= 'd0 ;
            end
            else begin
                g0_sum_part0 <= matrix14 ;
                g0_sum_part1 <= 'd0;

                g1_sum_part0 <= matrix05 + matrix25;
                g1_sum_part1 <= matrix14 + matrix16;

                g2_sum_part0 <= matrix16 ;
                g2_sum_part1 <= 'd0;

                g3_sum_part0 <= matrix07 + matrix27; 
                g3_sum_part1 <= matrix16 + matrix18;
            end
        end
    end
    // 第一级：选择 B 分量；根据中心颜色取原值、两个同色邻居或四个对角邻居。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {b0_sum_part0, b0_sum_part1} <= 'd0 ;
            {b1_sum_part0, b1_sum_part1} <= 'd0 ;
            {b2_sum_part0, b2_sum_part1} <= 'd0 ;
            {b3_sum_part0, b3_sum_part1} <= 'd0 ;
        end
        else if(I_tvalid)begin
            if(bayer_ypos) begin
                b0_sum_part0 <= matrix14 ;
                b0_sum_part1 <= 'd0;

                b1_sum_part0 <= matrix14 + matrix16 ;
                b1_sum_part1 <= 'd0 ;

                b2_sum_part0 <= matrix16 ;
                b2_sum_part1 <= 'd0;

                b3_sum_part0 <= matrix16 + matrix18 ;
                b3_sum_part1 <= 'd0 ;
            end
            else begin
                b0_sum_part0 <= matrix04 + matrix24 ;
                b0_sum_part1 <= 'd0;

                b1_sum_part0 <= matrix04 + matrix06 ;
                b1_sum_part1 <= matrix24 + matrix26 ;

                b2_sum_part0 <= matrix06 + matrix26 ;
                b2_sum_part1 <= 'd0;

                b3_sum_part0 <= matrix06 + matrix08 ;
                b3_sum_part1 <= matrix26 + matrix28 ;
            end
        end
    end

    // 第二级：合并两个局部和，得到各颜色的候选总和。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {r0_matrix_plus, g0_matrix_plus, b0_matrix_plus} <= 'd0 ;
            {r1_matrix_plus, g1_matrix_plus, b1_matrix_plus} <= 'd0 ;
            {r2_matrix_plus, g2_matrix_plus, b2_matrix_plus} <= 'd0 ;
            {r3_matrix_plus, g3_matrix_plus, b3_matrix_plus} <= 'd0 ;
        end
        else if(I_tvalid_r[0])begin
            r0_matrix_plus <= r0_sum_part0 + r0_sum_part1 ;
            r1_matrix_plus <= r1_sum_part0 + r1_sum_part1 ;
            r2_matrix_plus <= r2_sum_part0 + r2_sum_part1 ;
            r3_matrix_plus <= r3_sum_part0 + r3_sum_part1 ;

            g0_matrix_plus <= g0_sum_part0 + g0_sum_part1 ;
            g1_matrix_plus <= g1_sum_part0 + g1_sum_part1 ;
            g2_matrix_plus <= g2_sum_part0 + g2_sum_part1 ;
            g3_matrix_plus <= g3_sum_part0 + g3_sum_part1 ;

            b0_matrix_plus <= b0_sum_part0 + b0_sum_part1 ;
            b1_matrix_plus <= b1_sum_part0 + b1_sum_part1 ;
            b2_matrix_plus <= b2_sum_part0 + b2_sum_part1 ;
            b3_matrix_plus <= b3_sum_part0 + b3_sum_part1 ;
        end
    end


    // 第三级：根据当前行相位选择原值、二点平均或四点平均。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {r0_mean, g0_mean, b0_mean} <= 'd0 ;
            {r1_mean, g1_mean, b1_mean} <= 'd0 ;
            {r2_mean, g2_mean, b2_mean} <= 'd0 ;
            {r3_mean, g3_mean, b3_mean} <= 'd0 ;
        end
        else if(I_tvalid_r[1])begin
            r0_mean <= (!bayer_ypos_r1) ? r0_matrix_plus >> 1 : r0_matrix_plus >> 2 ;
            g0_mean <= (!bayer_ypos_r1) ? g0_matrix_plus      : g0_matrix_plus >> 2 ;
            b0_mean <= (!bayer_ypos_r1) ? b0_matrix_plus >> 1 : b0_matrix_plus      ;

            r1_mean <= (!bayer_ypos_r1) ? r1_matrix_plus      : r1_matrix_plus >> 1 ;
            g1_mean <= (!bayer_ypos_r1) ? g1_matrix_plus >> 2 : g1_matrix_plus      ;
            b1_mean <= (!bayer_ypos_r1) ? b1_matrix_plus >> 2 : b1_matrix_plus >> 1 ;

            r2_mean <= (!bayer_ypos_r1) ? r2_matrix_plus >> 1 : r2_matrix_plus >> 2 ;
            g2_mean <= (!bayer_ypos_r1) ? g2_matrix_plus      : g2_matrix_plus >> 2 ;      
            b2_mean <= (!bayer_ypos_r1) ? b2_matrix_plus >> 1 : b2_matrix_plus      ;

            r3_mean <= (!bayer_ypos_r1) ? r3_matrix_plus      : r3_matrix_plus >> 1 ;
            g3_mean <= (!bayer_ypos_r1) ? g3_matrix_plus >> 2 : g3_matrix_plus      ;
            b3_mean <= (!bayer_ypos_r1) ? b3_matrix_plus >> 2 : b3_matrix_plus >> 1 ;
        end
    end
end

endgenerate 
    


    // 第四级结果：把 9-bit 平均值饱和为 8-bit，防止异常加法结果回绕。
    reg [7:0] r0_mean_d,r1_mean_d,r2_mean_d,r3_mean_d;
    reg [7:0] g0_mean_d,g1_mean_d,g2_mean_d,g3_mean_d;
    reg [7:0] b0_mean_d,b1_mean_d,b2_mean_d,b3_mean_d;
    // 若第 9 位为 1，说明结果超过 255，输出饱和值 255；否则保留低 8 bit。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            {r0_mean_d,r1_mean_d,r2_mean_d,r3_mean_d} <= 'd0 ;
            {g0_mean_d,g1_mean_d,g2_mean_d,g3_mean_d} <= 'd0 ;
            {b0_mean_d,b1_mean_d,b2_mean_d,b3_mean_d} <= 'd0 ;
        end
        else if(I_tvalid_r[2])begin
            r0_mean_d <= r0_mean[8]?255:r0_mean[7:0];
            g0_mean_d <= g0_mean[8]?255:g0_mean[7:0];
            b0_mean_d <= b0_mean[8]?255:b0_mean[7:0];

            r1_mean_d <= r1_mean[8]?255:r1_mean[7:0];
            g1_mean_d <= g1_mean[8]?255:g1_mean[7:0];
            b1_mean_d <= b1_mean[8]?255:b1_mean[7:0];

            r2_mean_d <= r2_mean[8]?255:r2_mean[7:0];
            g2_mean_d <= g2_mean[8]?255:g2_mean[7:0];
            b2_mean_d <= b2_mean[8]?255:b2_mean[7:0];

            r3_mean_d <= r3_mean[8]?255:r3_mean[7:0];
            g3_mean_d <= g3_mean[8]?255:g3_mean[7:0];
            b3_mean_d <= b3_mean[8]?255:b3_mean[7:0];
        end
    end

    // 第五级：将每个 RGB888 像素扩展成 32 bit，最高 8 bit 固定补 0。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            rgb_data0 <= 'd0 ;
            rgb_data1 <= 'd0 ;
            rgb_data2 <= 'd0 ;
            rgb_data3 <= 'd0 ;
        end
        else if(I_tvalid_r[3])begin
            rgb_data0 <= {8'b0, r0_mean_d, g0_mean_d, b0_mean_d};
            rgb_data1 <= {8'b0, r1_mean_d, g1_mean_d, b1_mean_d};
            rgb_data2 <= {8'b0, r2_mean_d, g2_mean_d, b2_mean_d};
            rgb_data3 <= {8'b0, r3_mean_d, g3_mean_d, b3_mean_d};
        end
    end

    // 128-bit 总线从高到低依次放置像素 3、2、1、0。
    assign rgb_data = {rgb_data3, rgb_data2, rgb_data1, rgb_data0};
/*****************************************************************
                          信号同步                                        
*****************************************************************/

    // tlast/tuser/tvalid 与数据经过相同深度的移位寄存器，保证控制信号和 RGB 对齐。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n)
            {I_tlast_r,I_tuser_r,I_tvalid_r} <= 0;
        else begin
            I_tlast_r  <= {I_tlast_r[3:0],I_tlast};
            I_tuser_r  <= {I_tuser_r[3:0],I_tuser};
            I_tvalid_r <= {I_tvalid_r[3:0],I_tvalid};
        end
    end

    assign  O_tlast  = I_tlast_r[4];   
    assign  O_tuser  = I_tuser_r[4];   
    assign  O_tvalid = I_tvalid_r[4];

    
    assign O_tdata  = rgb_data;

    // ready 直接向上传递。本实现内部没有在 O_tready=0 时冻结流水线，
    // 因此工程按连续视频流使用，通常要求下游保持 ready 有效。
    assign I_tready = O_tready;

endmodule
