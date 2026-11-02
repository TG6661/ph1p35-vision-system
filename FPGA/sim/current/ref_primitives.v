// 四像素流的同步行缓存及分拍计算，参考例程的时钟RAM读写/数据延迟结构。
// 每拍可接收4像素，空拍只延迟控制标记，不推进横向窗口。
module ref_isp_window_3x3_4px #(
    parameter PIXEL_BITS=8, IMG_WIDTH=1280, IMG_HEIGHT=720,
    parameter GROUPS=IMG_WIDTH/4,
    parameter ADDRESS_BITS=(GROUPS>1)?$clog2(GROUPS):1
)(
    input I_clk,I_rst_n,I_tvalid,I_tuser,I_tlast,
    input [4*PIXEL_BITS-1:0] I_word,
    output reg [6*PIXEL_BITS-1:0] O_top6,O_mid6,O_bot6,
    output reg [4*PIXEL_BITS-1:0] O_current,
    output reg O_tvalid,O_tuser,O_tlast,O_window_valid,
    output reg [10:0] O_x,O_y
);
    localparam WORD_BITS=4*PIXEL_BITS;
    reg [10:0] x,y;
    reg [10:0] x_d,y_d;
    reg [ADDRESS_BITS-1:0] address_d;
    reg [WORD_BITS-1:0] current_d;
    reg valid_d,user_d,last_d;
    wire [2*WORD_BITS-1:0] history;
    wire [WORD_BITS-1:0] top_word=history[2*WORD_BITS-1:WORD_BITS];
    wire [WORD_BITS-1:0] mid_word=history[WORD_BITS-1:0];
    reg [2*PIXEL_BITS-1:0] top_prev,mid_prev,bot_prev;

    // B口本拍同步读取旧的两行，A口下一拍回写{上一行,当前行}。
    // 当前读取地址和延迟写入地址分离，切断“地址->RAM->算法”的组合长路径。
    // 两行打包存在同一个ERAM中，延迟一拍回写；连续输入仍每拍一个地址。
    isp_line_ram #(
        .DATA_WIDTH_A(2*WORD_BITS),.DATA_WIDTH_B(2*WORD_BITS),
        .ADDR_WIDTH_A(ADDRESS_BITS),.ADDR_WIDTH_B(ADDRESS_BITS),
        .DATA_DEPTH_A(1<<ADDRESS_BITS),.DATA_DEPTH_B(1<<ADDRESS_BITS),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("READBEFOREWRITE")
    ) u_history_eram(
        .clka(I_clk),.wea(valid_d && I_rst_n),.addra(address_d),
        .dia({mid_word,current_d}),.doa(),
        .clkb(I_clk),.web(1'b0),.addrb(x[ADDRESS_BITS-1:0]),
        .dib({(2*WORD_BITS){1'b0}}),.dob(history)
    );
    // 第1拍：地址/当前像素与RAM读出的历史像素保持对应。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            x<=0;y<=0;x_d<=0;y_d<=0;address_d<=0;current_d<=0;
            valid_d<=0;user_d<=0;last_d<=0;
        end else begin
            x_d<=x;y_d<=y;address_d<=x[ADDRESS_BITS-1:0];current_d<=I_word;
            valid_d<=I_tvalid;user_d<=I_tuser;last_d<=I_tlast;
            if(I_tvalid) begin
                if(I_tuser) begin x<=1;y<=0;end
                else if(x==GROUPS-1) begin x<=0;y<=(y==IMG_HEIGHT-1)?0:y+1'b1;end
                else x<=x+1'b1;
            end
        end
    end
    // 第2拍：注册横向窗口。prev只在有效输入时更新，行末清零。
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            O_top6<=0;O_mid6<=0;O_bot6<=0;O_current<=0;
            O_tvalid<=0;O_tuser<=0;O_tlast<=0;O_window_valid<=0;O_x<=0;O_y<=0;
            top_prev<=0;mid_prev<=0;bot_prev<=0;
        end else begin
            O_top6<={top_prev,top_word};O_mid6<={mid_prev,mid_word};O_bot6<={bot_prev,current_d};
            O_current<=current_d;O_x<=x_d;O_y<=y_d;
            O_tvalid<=valid_d;O_tuser<=user_d;O_tlast<=last_d;
            O_window_valid<=(y_d>=2)&&(x_d!=0)&&!user_d;
            if(valid_d) begin
                if(x_d==GROUPS-1 && !user_d) begin top_prev<=0;mid_prev<=0;bot_prev<=0;end
                else begin
                    top_prev<=top_word[2*PIXEL_BITS-1:0];
                    mid_prev<=mid_word[2*PIXEL_BITS-1:0];
                    bot_prev<=current_d[2*PIXEL_BITS-1:0];
                end
            end
        end
    end
endmodule

// 四像素5x5窗口：四行历史打包进ERAM，八列由上一组4像素和当前组拼成。
// 两拍接口与3x3窗口一致；行首清横向历史，空拍不推进像素坐标。
module ref_isp_window_5x5_4px #(
    parameter PIXEL_BITS=24,IMG_WIDTH=1280,IMG_HEIGHT=720,
    parameter GROUPS=IMG_WIDTH/4,
    parameter ADDRESS_BITS=(GROUPS>1)?$clog2(GROUPS):1
)(
    input I_clk,I_rst_n,I_tvalid,I_tuser,I_tlast,
    input [4*PIXEL_BITS-1:0] I_word,
    output reg [8*PIXEL_BITS-1:0] O_row0,O_row1,O_row2,O_row3,O_row4,
    output reg [4*PIXEL_BITS-1:0] O_current,
    output reg O_tvalid,O_tuser,O_tlast,
    output reg [10:0] O_x,O_y
);
    localparam WB=4*PIXEL_BITS;
    reg [10:0] x,y,x_d,y_d;
    reg [ADDRESS_BITS-1:0] address_d;
    reg [WB-1:0] current_d;
    reg valid_d,user_d,last_d;
    wire [4*WB-1:0] history;
    reg [WB-1:0] prev0,prev1,prev2,prev3,prev4;
    isp_line_ram #(.DATA_WIDTH_A(4*WB),.DATA_WIDTH_B(4*WB),
        .ADDR_WIDTH_A(ADDRESS_BITS),.ADDR_WIDTH_B(ADDRESS_BITS),
        .DATA_DEPTH_A(1<<ADDRESS_BITS),.DATA_DEPTH_B(1<<ADDRESS_BITS),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("READBEFOREWRITE")) u_history_eram(
        .clka(I_clk),.wea(valid_d&&I_rst_n),.addra(address_d),
        .dia({history[3*WB-1:0],current_d}),.doa(),
        .clkb(I_clk),.web(1'b0),.addrb(x[ADDRESS_BITS-1:0]),
        .dib({(4*WB){1'b0}}),.dob(history));
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n) begin
            x<=0;y<=0;x_d<=0;y_d<=0;address_d<=0;current_d<=0;
            valid_d<=0;user_d<=0;last_d<=0;
        end else begin
            x_d<=x;y_d<=y;address_d<=x[ADDRESS_BITS-1:0];current_d<=I_word;
            valid_d<=I_tvalid;user_d<=I_tuser;last_d<=I_tlast;
            if(I_tvalid)begin
                if(I_tuser)begin x<=1;y<=0;end
                else if(x==GROUPS-1)begin x<=0;y<=(y==IMG_HEIGHT-1)?0:y+1'b1;end
                else x<=x+1'b1;
            end
        end
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n) begin
            O_row0<=0;O_row1<=0;O_row2<=0;O_row3<=0;O_row4<=0;O_current<=0;
            O_tvalid<=0;O_tuser<=0;O_tlast<=0;O_x<=0;O_y<=0;
            prev0<=0;prev1<=0;prev2<=0;prev3<=0;prev4<=0;
        end else begin
            O_row0<={prev0,history[4*WB-1:3*WB]};
            O_row1<={prev1,history[3*WB-1:2*WB]};
            O_row2<={prev2,history[2*WB-1:WB]};
            O_row3<={prev3,history[WB-1:0]};O_row4<={prev4,current_d};O_current<=current_d;
            O_tvalid<=valid_d;O_tuser<=user_d;O_tlast<=last_d;O_x<=x_d;O_y<=y_d;
            if(valid_d)begin
                if(x_d==GROUPS-1&&!user_d)begin prev0<=0;prev1<=0;prev2<=0;prev3<=0;prev4<=0;end
                else begin
                    prev0<=history[4*WB-1:3*WB];prev1<=history[3*WB-1:2*WB];
                    prev2<=history[2*WB-1:WB];prev3<=history[WB-1:0];prev4<=current_d;
                end
            end
        end
endmodule

// 9bit量化色的孤立点替换：中心色最多2票，另一色至少4票且唯一最高才替换。
// 保留现有模块名/两拍接口。三行各取一个重复候选，随后按完整RGB编号核实票数。
// 4票颜色必在至少一行重复，因此不用为9个位置分别生成一套完整计票逻辑。
module ref_isp_majority9_4px(
    input I_clk,I_rst_n,I_tvalid,I_tuser,I_tlast,
    input [53:0] I_top6,I_mid6,I_bot6,
    input [35:0] I_center4,input [3:0] I_enable,
    output reg [35:0] O_color4,output reg O_tvalid,O_tuser,O_tlast
);
    reg valid_d,user_d,last_d;
    function [3:0] frequency(input [80:0] colors,input [8:0] candidate);
        integer k;
        reg [8:0] equal_bits;
        reg [1:0] pair0,pair1,pair2,pair3;
        reg [2:0] half0,half1;
        begin
            for(k=0;k<9;k=k+1) equal_bits[k]=(colors[80-k*9-:9]==candidate);
            // 平衡计数树，避免9个连续的加法器拉长组合路径。
            pair0={1'b0,equal_bits[0]}+{1'b0,equal_bits[1]};
            pair1={1'b0,equal_bits[2]}+{1'b0,equal_bits[3]};
            pair2={1'b0,equal_bits[4]}+{1'b0,equal_bits[5]};
            pair3={1'b0,equal_bits[6]}+{1'b0,equal_bits[7]};
            half0={1'b0,pair0}+{1'b0,pair1};
            half1={1'b0,pair2}+{1'b0,pair3};
            frequency={1'b0,half0}+{1'b0,half1}+{3'd0,equal_bits[8]};
        end
    endfunction
    function [9:0] repeated_in_row(input [26:0] row);
        reg [8:0] a,b,c;
        begin
            a=row[26:18];b=row[17:9];c=row[8:0];
            if(a==b || a==c) repeated_in_row={1'b1,a};
            else if(b==c) repeated_in_row={1'b1,b};
            else repeated_in_row=10'd0;
        end
    endfunction
    genvar p;
    generate for(p=0;p<4;p=p+1)begin:g_pixel
        wire [80:0] colors={I_top6[53-p*9-:27],I_mid6[53-p*9-:27],I_bot6[53-p*9-:27]};
        reg [80:0] colors_d;
        reg [9:0] candidate0_d,candidate1_d,candidate2_d;
        reg [8:0] center_d;reg enable_d;
        wire [3:0] count0=candidate0_d[9]?frequency(colors_d,candidate0_d[8:0]):4'd0;
        wire [3:0] count1=candidate1_d[9]?frequency(colors_d,candidate1_d[8:0]):4'd0;
        wire [3:0] count2=candidate2_d[9]?frequency(colors_d,candidate2_d[8:0]):4'd0;
        wire isolated=frequency(colors_d,center_d)<=4'd2;
        // 同色候选可在多行出现，不算平票；不同色同票则保持中心，避免任意选色。
        wire win0=(count0>=4'd4) && (candidate0_d[8:0]==candidate1_d[8:0] || count0>count1) &&
                                   (candidate0_d[8:0]==candidate2_d[8:0] || count0>count2);
        wire win1=(count1>=4'd4) && (candidate1_d[8:0]==candidate0_d[8:0] || count1>count0) &&
                                   (candidate1_d[8:0]==candidate2_d[8:0] || count1>count2);
        wire win2=(count2>=4'd4) && (candidate2_d[8:0]==candidate0_d[8:0] || count2>count0) &&
                                   (candidate2_d[8:0]==candidate1_d[8:0] || count2>count1);
        wire [8:0] winner=win0?candidate0_d[8:0]:(win1?candidate1_d[8:0]:candidate2_d[8:0]);
        always @(posedge I_clk or negedge I_rst_n)
            if(!I_rst_n)begin
                colors_d<=0;candidate0_d<=0;candidate1_d<=0;candidate2_d<=0;
                center_d<=0;enable_d<=0;O_color4[35-p*9-:9]<=0;
            end
            else begin
                colors_d<=colors;
                candidate0_d<=repeated_in_row(colors[80:54]);
                candidate1_d<=repeated_in_row(colors[53:27]);
                candidate2_d<=repeated_in_row(colors[26:0]);
                center_d<=I_center4[35-p*9-:9];enable_d<=I_enable[3-p];
                O_color4[35-p*9-:9]<=(enable_d && isolated && (win0||win1||win2))?winner:center_d;
            end
    end endgenerate
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n)begin valid_d<=0;user_d<=0;last_d<=0;O_tvalid<=0;O_tuser<=0;O_tlast<=0;end
        else begin
            valid_d<=I_tvalid;user_d<=I_tuser;last_d<=I_tlast;
            O_tvalid<=valid_d;O_tuser<=user_d;O_tlast<=last_d;
        end
endmodule

// 3x3高斯分成“各行横向加权和”“纵向加权和”两拍，整数取整与原核相同。
module ref_isp_gaussian_4px_pipe(
    input I_clk,I_rst_n,I_tvalid,I_tuser,I_tlast,I_window_valid,
    input [47:0] I_top6,I_mid6,I_bot6,
    output reg [31:0] O_blur4,
    output reg O_tvalid,O_tuser,O_tlast
);
    reg [39:0] row_top,row_mid,row_bot;
    reg valid_d,user_d,last_d,window_d;
    genvar pixel;
    generate for(pixel=0;pixel<4;pixel=pixel+1) begin:g_gaussian
        wire [7:0] t0=I_top6[47-8*pixel -: 8],t1=I_top6[39-8*pixel -: 8],t2=I_top6[31-8*pixel -: 8];
        wire [7:0] m0=I_mid6[47-8*pixel -: 8],m1=I_mid6[39-8*pixel -: 8],m2=I_mid6[31-8*pixel -: 8];
        wire [7:0] b0=I_bot6[47-8*pixel -: 8],b1=I_bot6[39-8*pixel -: 8],b2=I_bot6[31-8*pixel -: 8];
        wire [11:0] acc={2'b0,row_top[39-10*pixel -: 10]}+
            {1'b0,row_mid[39-10*pixel -: 10],1'b0}+{2'b0,row_bot[39-10*pixel -: 10]};
        always @(posedge I_clk or negedge I_rst_n) begin
            if(!I_rst_n) begin
                row_top[39-10*pixel -: 10]<=0;row_mid[39-10*pixel -: 10]<=0;row_bot[39-10*pixel -: 10]<=0;
                O_blur4[31-8*pixel -: 8]<=0;
            end else begin
                row_top[39-10*pixel -: 10]<={2'b0,t0}+{1'b0,t1,1'b0}+{2'b0,t2};
                row_mid[39-10*pixel -: 10]<={2'b0,m0}+{1'b0,m1,1'b0}+{2'b0,m2};
                row_bot[39-10*pixel -: 10]<={2'b0,b0}+{1'b0,b1,1'b0}+{2'b0,b2};
                O_blur4[31-8*pixel -: 8]<=window_d?acc[11:4]:8'd0;
            end
        end
    end endgenerate
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin valid_d<=0;user_d<=0;last_d<=0;window_d<=0;O_tvalid<=0;O_tuser<=0;O_tlast<=0;end
        else begin
            valid_d<=I_tvalid;user_d<=I_tuser;last_d<=I_tlast;window_d<=I_window_valid;
            O_tvalid<=valid_d;O_tuser<=user_d;O_tlast<=last_d;
        end
    end
endmodule

// Sobel分成3拍：正负加权和 -> 两方向绝对差 -> 幅值相加。
// 幅值最大2040，11bit足够；符号取绝对值后的结果与原计算完全相同。
module ref_isp_sobel_4px_pipe(
    input I_clk,I_rst_n,I_tvalid,I_tuser,I_tlast,
    input [3:0] I_window_enable,
    input [47:0] I_top6,I_mid6,I_bot6,
    output reg [43:0] O_mag4,
    output reg [3:0] O_window_enable,
    output reg O_tvalid,O_tuser,O_tlast
);
    reg [2:0] valid_pipe,user_pipe,last_pipe;
    reg [3:0] enable1,enable2;
    genvar pixel;
    generate for(pixel=0;pixel<4;pixel=pixel+1) begin:g_sobel
        wire [7:0] a=I_top6[47-8*pixel -: 8],b=I_top6[39-8*pixel -: 8],c=I_top6[31-8*pixel -: 8];
        wire [7:0] d=I_mid6[47-8*pixel -: 8],f=I_mid6[31-8*pixel -: 8];
        wire [7:0] g=I_bot6[47-8*pixel -: 8],h=I_bot6[39-8*pixel -: 8],i=I_bot6[31-8*pixel -: 8];
        reg [9:0] xp,xn,yp,yn;
        reg [10:0] xa,ya;
        always @(posedge I_clk or negedge I_rst_n) begin
            if(!I_rst_n) begin xp<=0;xn<=0;yp<=0;yn<=0;xa<=0;ya<=0;O_mag4[43-11*pixel -: 11]<=0;end
            else begin
                xp<={2'b0,c}+{1'b0,f,1'b0}+{2'b0,i};
                xn<={2'b0,a}+{1'b0,d,1'b0}+{2'b0,g};
                yp<={2'b0,g}+{1'b0,h,1'b0}+{2'b0,i};
                yn<={2'b0,a}+{1'b0,b,1'b0}+{2'b0,c};
                xa<=(xp>=xn)?xp-xn:xn-xp;ya<=(yp>=yn)?yp-yn:yn-yp;
                O_mag4[43-11*pixel -: 11]<=xa+ya;
            end
        end
    end endgenerate
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            valid_pipe<=0;user_pipe<=0;last_pipe<=0;enable1<=0;enable2<=0;
            O_window_enable<=0;O_tvalid<=0;O_tuser<=0;O_tlast<=0;
        end else begin
            valid_pipe<={valid_pipe[1:0],I_tvalid};user_pipe<={user_pipe[1:0],I_tuser};last_pipe<={last_pipe[1:0],I_tlast};
            enable1<=I_window_enable;enable2<=enable1;O_window_enable<=enable2;
            O_tvalid<=valid_pipe[1];O_tuser<=user_pipe[1];O_tlast<=last_pipe[1];
        end
    end
endmodule
