// 卡通：同步ERAM行缓存 -> 两拍高斯 -> 同步模糊行缓存 -> 三拍Sobel -> 轮廓融合。
// 填色：中心对齐 -> 两拍纯延迟 -> 一行一列对齐 -> 亮度分级；PIXELS像素/拍，12拍延迟。
// 生产PIXELS=2；按实际像素保留原四像素分组的左边界回退，不能改为仅跳过首对。
// 两支路统一对齐到原图(y-2,x-2)，边界邻域不足时使用确定的原色/中心回退。
// 与队友新版一致：无彩色高斯，灰度高斯仅用于描边。
module cartoon_96 #(parameter IMG_WIDTH=1280,IMG_HEIGHT=720,PIXELS=4,parameter EDGE_TH=11'd60)(
    input I_clk,I_rst_n,I_tlast,I_tuser,input [PIXELS*24-1:0] I_tdata,
    input I_tvalid,I_tready,
    output reg O_tlast,O_tuser,output reg [PIXELS*24-1:0] O_tdata,
    output reg O_tvalid,output O_tready
);
    assign O_tready=I_tready;
    reg [10:0] valid_pipe,user_pipe,last_pipe;

    function [7:0] gray8(input [23:0] rgb);
        begin gray8={2'b0,rgb[23:18]}+{1'b0,rgb[15:9]}+{2'b0,rgb[7:2]};end
    endfunction
    wire [PIXELS*8-1:0] gray_word;
    genvar gp;
    generate for(gp=0;gp<PIXELS;gp=gp+1) begin:g_gray
        assign gray_word[gp*8+:8]=gray8(I_tdata[gp*24+:24]);
    end endgenerate
    wire [(PIXELS+2)*8-1:0] rt,rm,rb;wire rv,ru,rl,raw_ok;
    isp_window_3x3_4px #(.PIXELS(PIXELS),.PIXEL_BITS(8),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT)) u_gray_window(
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_tvalid(I_tvalid),.I_tuser(I_tuser),.I_tlast(I_tlast),.I_word(gray_word),
        .O_top6(rt),.O_mid6(rm),.O_bot6(rb),.O_current(),.O_tvalid(rv),.O_tuser(ru),.O_tlast(rl),
        .O_window_valid(raw_ok),.O_x(),.O_y());
    wire [PIXELS*8-1:0] blur;wire bv,bu,bl;
    isp_gaussian_4px_pipe #(.PIXELS(PIXELS)) u_gaussian_gray(.I_clk(I_clk),.I_rst_n(I_rst_n),.I_tvalid(rv),.I_tuser(ru),.I_tlast(rl),
        .I_window_valid(raw_ok),.I_top6(rt),.I_mid6(rm),.I_bot6(rb),.O_blur4(blur),.O_tvalid(bv),.O_tuser(bu),.O_tlast(bl));
    wire [(PIXELS+2)*8-1:0] bt,bm,bb;wire wv,wu,wl;wire [10:0] wx,wy;
    isp_window_3x3_4px #(.PIXELS(PIXELS),.PIXEL_BITS(8),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT)) u_blur_window(
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_tvalid(bv),.I_tuser(bu),.I_tlast(bl),.I_word(blur),
        .O_top6(bt),.O_mid6(bm),.O_bot6(bb),.O_current(),.O_tvalid(wv),.O_tuser(wu),.O_tlast(wl),
        .O_window_valid(),.O_x(wx),.O_y(wy));
    // 两次3x3需要5x5邻域：前4行不判轮廓，out0/out1还需跳过前6列。
    wire [PIXELS-1:0] edge_enable;
    genvar ep;
    generate for(ep=0;ep<PIXELS;ep=ep+1) begin:g_boundary
        assign edge_enable[PIXELS-1-ep]=(wy>=4)&&(wx*PIXELS+ep>=6)&&!wu;
    end endgenerate
    wire [PIXELS-1:0] edges;
    cartoon_sobel_edge_4px #(.PIXELS(PIXELS),.EDGE_TH(EDGE_TH)) u_sobel(
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_top6(bt),.I_mid6(bm),.I_bot6(bb),
        .I_window_enable(edge_enable),.O_edge4(edges));
    wire [PIXELS*24-1:0] center_rgb;wire cv,cu,clast;
    cartoon_color_align_4px #(.PIXELS(PIXELS),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT)) u_color_center(
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_tvalid(I_tvalid),.I_tuser(I_tuser),.I_tlast(I_tlast),.I_rgb4(I_tdata),
        .O_rgb4(center_rgb),.O_tvalid(cv),.O_tuser(cu),.O_tlast(clast));
    // Preserve the teammate's two delay stages and 12-clock external latency.
    reg [PIXELS*24-1:0] smooth_pipe_0,smooth_pipe_1;
    reg [1:0] fv_pipe,fu_pipe,fl_pipe;
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n) begin
            smooth_pipe_0<=0;smooth_pipe_1<=0;fv_pipe<=0;fu_pipe<=0;fl_pipe<=0;
        end else begin
            smooth_pipe_0<=center_rgb;smooth_pipe_1<=smooth_pipe_0;
            fv_pipe<={fv_pipe[0],cv};fu_pipe<={fu_pipe[0],cu};fl_pipe<={fl_pipe[0],clast};
        end
    wire [PIXELS*24-1:0] smooth_rgb=smooth_pipe_1;
    wire fv=fv_pipe[1],fu=fu_pipe[1],fl=fl_pipe[1];
    // 删除独立RGB硬量化及9位色号投票，避免单通道跨档产生明显假颜色。
    // 保留完整RGB到分级阶段；这里只存一行，并不是再次做邻域滤波。
    wire [PIXELS*24-1:0] aligned_rgb;wire av,au,al;
    cartoon_color_align_4px #(.PIXELS(PIXELS),.IMG_WIDTH(IMG_WIDTH),.IMG_HEIGHT(IMG_HEIGHT)) u_color_align(
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_tvalid(fv),.I_tuser(fu),.I_tlast(fl),.I_rgb4(smooth_rgb),
        .O_rgb4(aligned_rgb),.O_tvalid(av),.O_tuser(au),.O_tlast(al));
    wire [PIXELS*24-1:0] graded_rgb;
    cartoon_luma_quant_4px #(.PIXELS(PIXELS)) u_luma_quant(
        .I_clk(I_clk),.I_rst_n(I_rst_n),.I_tvalid(av),.I_tuser(au),.I_tlast(al),.I_rgb4(aligned_rgb),
        .O_rgb4(graded_rgb),.O_tvalid(),.O_tuser(),.O_tlast());
    // Color: center(2)+delay(2)+align(2)+quant(2)=8 clocks.
    // Three delay clocks align it with the 11-clock edge path before fusion.
    // The teammate version had only two here, advancing color by one beat.
    reg [PIXELS*24-1:0] color_d0,color_d1,color_d2;
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n)begin color_d0<=0;color_d1<=0;color_d2<=0;end
        else begin color_d0<=graded_rgb;color_d1<=color_d0;color_d2<=color_d1;end
    // Sobel为9拍、填色分级为8拍；分别补2/3拍后，在第12拍融合。
    // 队友原版填色少延迟一拍；这里补齐，保持像素与描边/帧行标记一致。
    // 不再延迟一行一列，删除原描边对齐窗口，防止轮廓与色块错位。
    reg [PIXELS-1:0] edge_d0,edge_d1;
    genvar pixel;
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n)begin edge_d0<=0;edge_d1<=0;end
        else begin edge_d0<=edges;edge_d1<=edge_d0;end
    generate for(pixel=0;pixel<PIXELS;pixel=pixel+1)begin:g_output
        always @(posedge I_clk or negedge I_rst_n)
            if(!I_rst_n)O_tdata[PIXELS*24-1-pixel*24-:24]<=0;
            else if(!valid_pipe[10])O_tdata[PIXELS*24-1-pixel*24-:24]<=0;
            else O_tdata[PIXELS*24-1-pixel*24-:24]<=edge_d1[PIXELS-1-pixel]?24'd0:color_d2[PIXELS*24-1-pixel*24-:24];
    end endgenerate
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n)begin valid_pipe<=0;user_pipe<=0;last_pipe<=0;O_tvalid<=0;O_tuser<=0;O_tlast<=0;end
        else begin
            valid_pipe<={valid_pipe[9:0],I_tvalid};user_pipe<={user_pipe[9:0],I_tuser};last_pipe<={last_pipe[9:0],I_tlast};
            O_tvalid<=valid_pipe[10];O_tuser<=user_pipe[10];O_tlast<=last_pipe[10];
        end
endmodule

// 单行RGB空间对齐，两拍延迟：输出上一行、左移一个像素的PIXELS像素组。
// 与原色号窗口采用相同边界回退：首行/首组输出当前组，禁止读出上一帧残留。
// 模块放在cartoon_96.v中，TD原有源文件登记即可覆盖，避免新增文件漏登记黑盒。
module cartoon_color_align_4px #(
    parameter IMG_WIDTH=1280,IMG_HEIGHT=720,PIXELS=4,
    parameter GROUPS=IMG_WIDTH/PIXELS,
    parameter ADDRESS_BITS=(GROUPS>1)?$clog2(GROUPS):1
)(
    input I_clk,I_rst_n,I_tvalid,I_tuser,I_tlast,
    input [PIXELS*24-1:0] I_rgb4,
    output reg [PIXELS*24-1:0] O_rgb4,output reg O_tvalid,O_tuser,O_tlast
);
    reg [10:0] x,y,x_d,y_d;
    reg [ADDRESS_BITS-1:0] address_d;
    reg [PIXELS*24-1:0] current_d;
    reg valid_d,user_d,last_d;
    reg [23:0] previous_pixel;
    wire [PIXELS*24-1:0] history;
    // 延迟一拍写入，读写地址分开；输入有空拍时不推进坐标或横向历史。
    isp_line_ram #(.DATA_WIDTH_A(PIXELS*24),.DATA_WIDTH_B(PIXELS*24),
        .ADDR_WIDTH_A(ADDRESS_BITS),.ADDR_WIDTH_B(ADDRESS_BITS),
        .DATA_DEPTH_A(1<<ADDRESS_BITS),.DATA_DEPTH_B(1<<ADDRESS_BITS),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("READBEFOREWRITE")) u_history_eram(
        .clka(I_clk),.wea(valid_d&&I_rst_n),.addra(address_d),.dia(current_d),.doa(),
        .clkb(I_clk),.web(1'b0),.addrb(x[ADDRESS_BITS-1:0]),.dib({(PIXELS*24){1'b0}}),.dob(history));
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n)begin
            x<=0;y<=0;x_d<=0;y_d<=0;address_d<=0;current_d<=0;
            valid_d<=0;user_d<=0;last_d<=0;
        end else begin
            x_d<=x;y_d<=y;address_d<=x[ADDRESS_BITS-1:0];current_d<=I_rgb4;
            valid_d<=I_tvalid;user_d<=I_tuser;last_d<=I_tlast;
            if(I_tvalid)begin
                if(I_tuser)begin x<=1;y<=0;end
                else if(x==GROUPS-1)begin x<=0;y<=(y==IMG_HEIGHT-1)?0:y+1'b1;end
                else x<=x+1'b1;
            end
        end
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n)begin
            O_rgb4<=0;O_tvalid<=0;O_tuser<=0;O_tlast<=0;previous_pixel<=0;
        end else begin
            O_rgb4<=(y_d>=1&&x_d>=4/PIXELS&&!user_d)?{previous_pixel,history[PIXELS*24-1:24]}:current_d;
            O_tvalid<=valid_d;O_tuser<=user_d;O_tlast<=last_d;
            if(valid_d)begin
                if(x_d==GROUPS-1&&!user_d)previous_pixel<=0;
                else previous_pixel<=history[23:0];
            end
        end
endmodule

// 只对亮度分8档，两拍延迟；同一个有符号差值作用于RGB，保留原颜色差。
// Y=floor((R+2G+B)/4)，Yq=32*floor(Y/32)+16，delta=Yq-Y=16-(Y mod 32)。
// 未发生0/255限幅时，R-G和B-G严格不变；不需要色域转换、乘法器或除法器。
module cartoon_luma_quant_4px #(parameter PIXELS=4)(
    input I_clk,I_rst_n,I_tvalid,I_tuser,I_tlast,input [PIXELS*24-1:0] I_rgb4,
    output reg [PIXELS*24-1:0] O_rgb4,output reg O_tvalid,O_tuser,O_tlast
);
    reg valid_d,user_d,last_d;
    function [7:0] add_clip(input [7:0] channel,input signed [5:0] delta);
        reg signed [9:0] adjusted;
        begin
            // 必须用10位有符号加法，既能表示负数，也能表示255+16=271。
            adjusted=$signed({2'b0,channel})+$signed({{4{delta[5]}},delta});
            add_clip=adjusted[9]?8'd0:(adjusted[8]?8'd255:adjusted[7:0]);
        end
    endfunction
    genvar p;
    generate for(p=0;p<PIXELS;p=p+1)begin:g_pixel
        wire [23:0] rgb=I_rgb4[PIXELS*24-1-p*24-:24];
        wire [8:0] rb_sum={1'b0,rgb[23:16]}+{1'b0,rgb[7:0]};
        wire [9:0] luma_sum={1'b0,rb_sum}+{1'b0,rgb[15:8],1'b0};
        reg [23:0] rgb_d;
        reg signed [5:0] delta_d;
        always @(posedge I_clk or negedge I_rst_n)
            if(!I_rst_n)begin rgb_d<=0;delta_d<=0;O_rgb4[PIXELS*24-1-p*24-:24]<=0;end
            else begin
                rgb_d<=rgb;
                // 只用Y的低5位，综合器可删掉不参与delta计算的高位加法。
                delta_d<=6'sd16-$signed({1'b0,luma_sum[6:2]});
                O_rgb4[PIXELS*24-1-p*24-:24]<={add_clip(rgb_d[23:16],delta_d),
                    add_clip(rgb_d[15:8],delta_d),add_clip(rgb_d[7:0],delta_d)};
            end
    end endgenerate
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n)begin valid_d<=0;user_d<=0;last_d<=0;O_tvalid<=0;O_tuser<=0;O_tlast<=0;end
        else begin
            valid_d<=I_tvalid;user_d<=I_tuser;last_d<=I_tlast;
            O_tvalid<=valid_d;O_tuser<=user_d;O_tlast<=last_d;
        end
endmodule

// Three-stage threshold-only Sobel, adapted from teammate ABI1.14.
module cartoon_sobel_edge_4px #(parameter PIXELS=4,parameter EDGE_TH=11'd60)(
    input I_clk,I_rst_n,
    input [(PIXELS+2)*8-1:0] I_top6,I_mid6,I_bot6,
    input [PIXELS-1:0] I_window_enable,
    output reg [PIXELS-1:0] O_edge4
);
    // 11位输入阈值最大2047，折半向上取整为1024，需12位有符号常量才能正确表示。
    localparam signed [11:0] EDGE_LIMIT=(EDGE_TH+1)/2;
    localparam signed [11:0] EDGE_NEG_LIMIT=-EDGE_LIMIT;
    reg [PIXELS-1:0] enable_d0,enable_d1;
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n)begin enable_d0<=0;enable_d1<=0;end
        else begin enable_d0<=I_window_enable;enable_d1<=enable_d0;end
    genvar p;
    generate for(p=0;p<PIXELS;p=p+1)begin:g_pixel
        wire [7:0] a=I_top6[(PIXELS+2)*8-1-8*p-:8],b=I_top6[(PIXELS+1)*8-1-8*p-:8],c=I_top6[PIXELS*8-1-8*p-:8];
        wire [7:0] d=I_mid6[(PIXELS+2)*8-1-8*p-:8],f=I_mid6[PIXELS*8-1-8*p-:8];
        wire [7:0] g=I_bot6[(PIXELS+2)*8-1-8*p-:8],h=I_bot6[(PIXELS+1)*8-1-8*p-:8],i=I_bot6[PIXELS*8-1-8*p-:8];
        reg signed [8:0] diag_ia,diag_cg,diff_fd,diff_hb;
        // 两个旋转坐标均为3个8位通道差相加，范围-765~765，11位有符号足够。
        reg signed [10:0] diagonal_sum,diagonal_difference;
        always @(posedge I_clk or negedge I_rst_n)
            if(!I_rst_n)begin
                diag_ia<=0;diag_cg<=0;diff_fd<=0;diff_hb<=0;
                diagonal_sum<=0;diagonal_difference<=0;O_edge4[PIXELS-1-p]<=0;
            end else begin
                // 第1拍：4个9位有符号差，供两个方向共享。
                diag_ia<=$signed({1'b0,i})-$signed({1'b0,a});
                diag_cg<=$signed({1'b0,c})-$signed({1'b0,g});
                diff_fd<=$signed({1'b0,f})-$signed({1'b0,d});
                diff_hb<=$signed({1'b0,h})-$signed({1'b0,b});
                // 第2拍：计算(Gx+Gy)/2与(Gx-Gy)/2，显式符号扩展避免溢出。
                diagonal_sum<=$signed({{2{diag_ia[8]}},diag_ia})+$signed({{2{diff_fd[8]}},diff_fd})+
                    $signed({{2{diff_hb[8]}},diff_hb});
                diagonal_difference<=$signed({{2{diag_cg[8]}},diag_cg})+$signed({{2{diff_fd[8]}},diff_fd})-
                    $signed({{2{diff_hb[8]}},diff_hb});
                // 第3拍：任一旋转坐标越过正/负阈值即为边缘，0阈值也保持原先全命中。
                O_edge4[PIXELS-1-p]<=enable_d1[PIXELS-1-p]&&((diagonal_sum>=EDGE_LIMIT)||(diagonal_sum<=EDGE_NEG_LIMIT)||
                    (diagonal_difference>=EDGE_LIMIT)||(diagonal_difference<=EDGE_NEG_LIMIT));
            end
    end endgenerate
endmodule
