// 当前卡通使用本文件中的rgb_gaussian_3x3_4px普通高斯。
// 下面保边模块保留供旧算法参考/独立测试，当前卡通不再例化。
// 四像素RGB保边平滑，独立于行缓存，固定三拍延迟。
// 3x3空间权重为[1 2 1;2 4 2;1 2 1]。邻居任一通道与中心相差超过
// RANGE_TH时，用中心替换该邻居；分母始终16，不需要可变除法或乘法器。
// 四个像素共用同一颜色距离判定原则，R/G/B一起保留或替换，避免单通道串色。
module rgb_edge_smooth_4px #(parameter integer RANGE_TH=24)(
    input I_clk,I_rst_n,I_tvalid,I_tuser,I_tlast,
    input [3:0] I_window_enable,
    input [143:0] I_top6,I_mid6,I_bot6,
    output reg [95:0] O_rgb4,
    output reg O_tvalid,O_tuser,O_tlast
);
    reg [1:0] valid_d,user_d,last_d;
    localparam [8:0] RANGE_LIMIT=(RANGE_TH>=255)?9'd255:RANGE_TH;
    localparam [8:0] RANGE_SPAN={RANGE_LIMIT[7:0],1'b0};
    function [23:0] choose_neighbor(input [23:0] neighbor,center,input [26:0] bias);
        reg [8:0] dr,dg,db;
        begin
            // (邻居+TH-中心) mod 512 <= 2TH，与绝对差门限等价。
            // 中心偏置在外部算一次，供9个邻居共用；9位避免0/255回绕误判。
            dr={1'b0,neighbor[23:16]}+bias[26:18];
            dg={1'b0,neighbor[15:8]}+bias[17:9];
            db={1'b0,neighbor[7:0]}+bias[8:0];
            choose_neighbor=((dr<=RANGE_SPAN)&&(dg<=RANGE_SPAN)&&
                             (db<=RANGE_SPAN))?neighbor:center;
        end
    endfunction
    genvar p,n,c;
    generate for(p=0;p<4;p=p+1) begin:g_pixel
        wire [23:0] center=I_mid6[119-24*p -: 24];
        wire [8:0] bias_r=RANGE_LIMIT-{1'b0,center[23:16]};
        wire [8:0] bias_g=RANGE_LIMIT-{1'b0,center[15:8]};
        wire [8:0] bias_b=RANGE_LIMIT-{1'b0,center[7:0]};
        wire [215:0] taps={I_top6[143-24*p -: 72],I_mid6[143-24*p -: 72],I_bot6[143-24*p -: 72]};
        reg [215:0] neighbors;
        for(n=0;n<9;n=n+1) begin:g_neighbor
            always @(posedge I_clk or negedge I_rst_n)
                if(!I_rst_n) neighbors[215-24*n -: 24]<=0;
                else neighbors[215-24*n -: 24]<=I_window_enable[3-p]?
                    choose_neighbor(taps[215-24*n -: 24],center,{bias_r,bias_g,bias_b}):center;
        end
        for(c=0;c<3;c=c+1) begin:g_channel
            reg [9:0] top_sum,mid_sum,bot_sum;
            wire [11:0] total={2'b0,top_sum}+{1'b0,mid_sum,1'b0}+{2'b0,bot_sum}+12'd8;
            always @(posedge I_clk or negedge I_rst_n) begin
                if(!I_rst_n) begin top_sum<=0;mid_sum<=0;bot_sum<=0;O_rgb4[95-24*p-8*c -: 8]<=0;end
                else begin
                    top_sum<={2'b0,neighbors[215-8*c -: 8]}+{1'b0,neighbors[191-8*c -: 8],1'b0}+{2'b0,neighbors[167-8*c -: 8]};
                    mid_sum<={2'b0,neighbors[143-8*c -: 8]}+{1'b0,neighbors[119-8*c -: 8],1'b0}+{2'b0,neighbors[95-8*c -: 8]};
                    bot_sum<={2'b0,neighbors[71-8*c -: 8]}+{1'b0,neighbors[47-8*c -: 8],1'b0}+{2'b0,neighbors[23-8*c -: 8]};
                    O_rgb4[95-24*p-8*c -: 8]<=total[11:4];
                end
            end
        end
    end endgenerate
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n) begin valid_d<=0;user_d<=0;last_d<=0;O_tvalid<=0;O_tuser<=0;O_tlast<=0;end
        else begin
            valid_d<={valid_d[0],I_tvalid};user_d<={user_d[0],I_tuser};last_d<={last_d[0],I_tlast};
            O_tvalid<=valid_d[1];O_tuser<=user_d[1];O_tlast<=last_d[1];
        end
endmodule

// 普通3x3 RGB高斯：核[1 2 1;2 4 2;1 2 1]，权重和16，四像素/拍。
// 与保边模块相同的窗口/使能接口和三拍延迟，但没有颜色差比较和9邻居RGB寄存。
// 第一拍：三行各算一次横向[1 2 1]；第二拍：纵向加权、舍入；第三拍：输出对齐。
// 邻域不足时将三行和都置为4*中心，最后仍精确返回中心，不使用无效历史数据。
// 定义在原已登记的源文件中，TD无需新增源文件。
module rgb_gaussian_3x3_4px #(parameter PIXELS=4)(
    input I_clk,I_rst_n,I_tvalid,I_tuser,I_tlast,
    input [PIXELS-1:0] I_window_enable,
    input [(PIXELS+2)*24-1:0] I_top6,I_mid6,I_bot6,
    output reg [PIXELS*24-1:0] O_rgb4,
    output reg O_tvalid,O_tuser,O_tlast
);
    reg [1:0] valid_d,user_d,last_d;
    // BEGIN STAGE11_GAUSSIAN_DSP
    // Three independent RGB sums are packed in carry-isolated fields. Row
    // maxima are 1020 (10 bits); final maxima incl rounding are 4088 (12 bits).
    // Four DSPs per pixel: three horizontal sums and one vertical sum.
    genvar p,c,row;
    generate for(p=0;p<PIXELS;p=p+1) begin:g_pixel
        reg window_d;
        reg [23:0] center_d;
        wire [29:0] rows[0:2];
        wire [53:0] final_a,final_b,final_sum;
        always @(posedge I_clk or negedge I_rst_n)
            if(!I_rst_n) begin window_d<=0;center_d<=0;end
            else begin window_d<=I_window_enable[PIXELS-1-p];
                center_d<=I_mid6[(PIXELS+1)*24-1-p*24-:24];end
        for(row=0;row<3;row=row+1) begin:g_row
            wire [(PIXELS+2)*24-1:0] taps=(row==0)?I_top6:((row==1)?I_mid6:I_bot6);
            wire [29:0] outside_packed,middle_packed;
            wire [53:0] sum;
            for(c=0;c<3;c=c+1) begin:g_channel
                wire [7:0] a=taps[(PIXELS+2)*24-1-p*24-c*8-:8];
                wire [7:0] b=taps[(PIXELS+1)*24-1-p*24-c*8-:8];
                wire [7:0] d=taps[PIXELS*24-1-p*24-c*8-:8];
                wire [8:0] outside={1'b0,a}+{1'b0,d};
                assign outside_packed[c*10+:10]={1'b0,outside};
                assign middle_packed[c*10+:10]={1'b0,b,1'b0};
            end
            final1_gaussian_dsp_add #(.OUTPUT_REG("1")) u_sum(
                .clk(I_clk),.reset_n(I_rst_n),.a({24'd0,outside_packed}),
                .b({24'd0,middle_packed}),.sum(sum));
            assign rows[row]=sum[29:0];
        end
        for(c=0;c<3;c=c+1) begin:g_channel
            wire [11:0] outside={2'b0,rows[0][c*10+:10]}+{2'b0,rows[2][c*10+:10]}+12'd8;
            assign final_a[c*12+:12]=outside;
            assign final_b[c*12+:12]={1'b0,rows[1][c*10+:10],1'b0};
            reg [7:0] filtered_d;
            always @(posedge I_clk or negedge I_rst_n)
                if(!I_rst_n) begin filtered_d<=0;O_rgb4[PIXELS*24-1-p*24-c*8-:8]<=0;end
                else begin
                    filtered_d<=window_d?final_sum[c*12+4+:8]:center_d[23-c*8-:8];
                    O_rgb4[PIXELS*24-1-p*24-c*8-:8]<=filtered_d;
                end
        end
        assign final_a[53:36]=0;assign final_b[53:36]=0;
        final1_gaussian_dsp_add #(.OUTPUT_REG("0")) u_vertical(
            .clk(I_clk),.reset_n(I_rst_n),.a(final_a),.b(final_b),.sum(final_sum));
    end endgenerate
    // END STAGE11_GAUSSIAN_DSP
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n)begin valid_d<=0;user_d<=0;last_d<=0;O_tvalid<=0;O_tuser<=0;O_tlast<=0;end
        else begin
            valid_d<={valid_d[0],I_tvalid};user_d<={user_d[0],I_tuser};last_d<={last_d[0],I_tlast};
            O_tvalid<=valid_d[1];O_tuser<=user_d[1];O_tlast<=last_d[1];
        end
endmodule

// 5x5保边高斯：空间核为[1 4 6 4 1]的外积，总权重256。
// 门限规则与3x3版相同：有一通道差值超限就用中心替换整个邻居。
// 三拍为邻居选择、五行加权和、纵向加权和；所有乘权用移位加法。
module rgb_edge_smooth_5x5_4px #(parameter integer RANGE_TH=24)(
    input I_clk,I_rst_n,I_tvalid,I_tuser,I_tlast,
    input [191:0] I_row0,I_row1,I_row2,I_row3,I_row4,
    input [95:0] I_center4,input [3:0] I_enable,
    output reg [95:0] O_rgb4,output reg O_tvalid,O_tuser,O_tlast
);
    reg [1:0] valid_d,user_d,last_d;
    // |邻居-中心|<=TH 等价于 (邻居+TH-中心) mod 512 <= 2*TH。
    // 每个中心的TH-中心只算一次，供25个邻居共用；每通道只需一次门限比较。
    // 9位保留负差的回绕信息，不能直接改成8位，否则0/255附近会误判。
    localparam [8:0] RANGE_LIMIT=(RANGE_TH>=255)?9'd255:RANGE_TH;
    localparam [8:0] RANGE_SPAN={RANGE_LIMIT[7:0],1'b0};
    function [23:0] choose_neighbor(input [23:0] neighbor,center,input [26:0] bias);
        reg [8:0] dr,dg,db;
        begin
            dr={1'b0,neighbor[23:16]}+bias[26:18];
            dg={1'b0,neighbor[15:8]}+bias[17:9];
            db={1'b0,neighbor[7:0]}+bias[8:0];
            choose_neighbor=((dr<=RANGE_SPAN)&&(dg<=RANGE_SPAN)&&
                             (db<=RANGE_SPAN))?neighbor:center;
        end
    endfunction
    function [11:0] weighted_row(input [7:0] a,b,c,d,e);
        reg [8:0] outer_pair,inner_pair;
        reg [9:0] triple_center;
        reg [10:0] middle;
        begin
            // a+4b+6c+4d+e = (a+e)+2*(2*(b+d)+3*c)。
            // 先做对称配对，按实际最大值确定宽度，减少串接的宽位加法器。
            outer_pair={1'b0,a}+{1'b0,e};
            inner_pair={1'b0,b}+{1'b0,d};
            triple_center={1'b0,c,1'b0}+{2'b0,c};
            middle={1'b0,inner_pair,1'b0}+{1'b0,triple_center};
            weighted_row={3'b0,outer_pair}+{middle,1'b0};
        end
    endfunction
    function [15:0] weighted_column(input [11:0] a,b,c,d,e);
        reg [12:0] outer_pair,inner_pair;
        reg [13:0] triple_center;
        reg [14:0] middle;
        reg [15:0] weighted;
        begin
            outer_pair={1'b0,a}+{1'b0,e};
            inner_pair={1'b0,b}+{1'b0,d};
            triple_center={1'b0,c,1'b0}+{2'b0,c};
            middle={1'b0,inner_pair,1'b0}+{1'b0,triple_center};
            weighted={3'b0,outer_pair}+{middle,1'b0};
            weighted_column=weighted+16'd128; // 与原版相同，最终右移8位前四舍五入。
        end
    endfunction
    genvar p,n,c,r;
    generate for(p=0;p<4;p=p+1)begin:g_pixel
        wire [23:0] center=I_center4[95-p*24-:24];
        wire [8:0] bias_r=RANGE_LIMIT-{1'b0,center[23:16]};
        wire [8:0] bias_g=RANGE_LIMIT-{1'b0,center[15:8]};
        wire [8:0] bias_b=RANGE_LIMIT-{1'b0,center[7:0]};
        wire [599:0] taps={I_row0[191-p*24-:120],I_row1[191-p*24-:120],
            I_row2[191-p*24-:120],I_row3[191-p*24-:120],I_row4[191-p*24-:120]};
        reg [599:0] neighbors;
        for(n=0;n<25;n=n+1)begin:g_neighbor
            always @(posedge I_clk or negedge I_rst_n)
                if(!I_rst_n)neighbors[599-n*24-:24]<=0;
                else neighbors[599-n*24-:24]<=I_enable[3-p]?
                    choose_neighbor(taps[599-n*24-:24],center,{bias_r,bias_g,bias_b}):center;
        end
        for(c=0;c<3;c=c+1)begin:g_channel
            wire [59:0] rows;
            for(r=0;r<5;r=r+1)begin:g_row
                reg [11:0] row_sum;
                always @(posedge I_clk or negedge I_rst_n)
                    if(!I_rst_n)row_sum<=0;
                    else row_sum<=weighted_row(neighbors[599-r*120-c*8-:8],neighbors[575-r*120-c*8-:8],
                        neighbors[551-r*120-c*8-:8],neighbors[527-r*120-c*8-:8],neighbors[503-r*120-c*8-:8]);
                assign rows[59-r*12-:12]=row_sum;
            end
            wire [15:0] total=weighted_column(rows[59:48],rows[47:36],rows[35:24],rows[23:12],rows[11:0]);
            always @(posedge I_clk or negedge I_rst_n)
                if(!I_rst_n)O_rgb4[95-p*24-c*8-:8]<=0;
                else O_rgb4[95-p*24-c*8-:8]<=total[15:8];
        end
    end endgenerate
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n)begin valid_d<=0;user_d<=0;last_d<=0;O_tvalid<=0;O_tuser<=0;O_tlast<=0;end
        else begin
            valid_d<={valid_d[0],I_tvalid};user_d<={user_d[0],I_tuser};last_d<={last_d[0],I_tlast};
            O_tvalid<=valid_d[1];O_tuser<=user_d[1];O_tlast<=last_d[1];
        end
endmodule

// PH1P35 SIOU_V2 + TU, UG1310_1.2 sections 52/54. Legal fabric inputs
// enter via SIOU; never drive the TU hardwire inputs directly from fabric.
// TU computes {xa,xb}+z. Rounding stays in fabric because the installed
// model and UG1310 disagree on the RND mux encoding. All controls bypass registers; optional P register.
module final1_gaussian_dsp_add #(parameter OUTPUT_REG="1")(
    input clk,reset_n,input [53:0] a,b,output [53:0] sum);
    wire [53:0] ta,tb,tc,ts;
    wire ci,co,ov,un;wire [6:0] op;wire [5:0] over;
    PH1P_PHY_DSPSIOU_V2 #(.XAREG("0"),.XBREG("0"),.YREG("0"),.ZREG("0"),
        .INCTRLREG("0"),.MUXCTRLREG("0"),.OPCTRLREG("0"),.CINCTRLREG("0"),
        .CXAREG("0"),.CXBREG("0"),.CYREG("0"),.XABREG("0"),.MREG("0"),
        .POUWREG(OUTPUT_REG),.CCOREG("0"),.USER_GSRN("DISABLE"),.RND(54'd0),
        .CE0("1"),.CE1("0"),.CE2("0"),.CE3("0"),
        .RST0("SIG"),.RST1("0"),.RST2("0"),.RST3("0")) u_siou(
        .clk(clk),.ce(4'b0001),.rst({3'b0,!reset_n}),
        .xa(a[53:27]),.xb(a[26:0]),.y(18'd0),.z(b),
        .inctrl(7'b0010111),.muxctrl(7'b0010001),.cinctrl(3'b000),.opctrl(11'h408),
        // Dedicated AU/MU/LU return ports accept only their matching
        // primitive outputs or dangling connections (TD SYN-8134).
        // These units are unused: TU selects {xa,xb}+z, so leave them open.
        .add_sum(),.mult_p(),.logic_p(),.logic_wxor(),
        .tadd_a(ta),.tadd_b(tb),.tadd_c(tc),.tadd_ci(ci),.tadd_opctrl(op),.tadd_oversel(over),
        .tadd_sum(ts),.tadd_co(co),.tadd_overflow(ov),.tadd_underflow(un),.p(sum),
        .cxai(),.cxbi(),.cxabi(),.cyi(),.cpi(),.cci(),
        .cxao(),.cxbo(),.cxabo(),.cyo(),.cpo(),.cco(),.overflow(),.underflow(),.wxor(),
        .add_a(),.add_b(),.add_opctrl(),.mul9_mode(),.mul9_signed(),
        .mult_x(),.mult_y(),.mult_opctrl(),.logic_a(),.logic_b(),.logic_c(),.logic_opctrl());
    PH1P_PHY_DSPTADD u_tadd(.a(ta),.b(tb),.c(tc),.ci(ci),.opctrl(op),.oversel(over),
        .sum(ts),.co(co),.overflow(ov),.underflow(un));
endmodule
