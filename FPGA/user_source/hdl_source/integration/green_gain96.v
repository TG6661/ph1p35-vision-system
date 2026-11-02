// 中心减绿：AWB之后、Gamma之前。Q8中心增益固定224/256（0.875）。
// 横向保留3/8画宽半径；纵向固定576行平台，上下各64行渐变；R/B透传。
// PIXELS个RGB888/拍、三拍流水（生产2px）：空间权重 -> 绿色乘法 -> 输出，无行/帧缓存。
module green_gain96 #(parameter integer IMG_WIDTH=1280,IMG_HEIGHT=720,PIXELS=4)(
    input I_clk,I_rst_n,I_tvalid,I_tuser,I_tlast,
    input I_style_enable,
    input [PIXELS*24-1:0] I_tdata,input [8:0] I_gain,
    output reg O_tvalid,O_tuser,O_tlast,output reg [PIXELS*24-1:0] O_tdata
);
    localparam integer XB=(IMG_WIDTH>1)?$clog2(IMG_WIDTH):1;
    localparam integer YB=(IMG_HEIGHT>1)?$clog2(IMG_HEIGHT):1;
    // 横向作用半径为3/8画宽，左右至少1/8边框保持原色。
    // 全部半径/阈值只在编译期计算，不引入实时除法器。
    localparam integer RX=(IMG_WIDTH*3/8>0)?IMG_WIDTH*3/8:1;
    // STYLE深度固定；非STYLE保留原增益接口，两个模式共用绿色乘法。
    localparam [6:0] FIXED_DEPTH=7'd32;
    reg pending_user;
    reg [XB-1:0] next_x;
    reg [YB-1:0] next_y;
    wire frame_start=I_tvalid&&(I_tuser||pending_user);

    wire [XB-1:0] pixel_x=frame_start?{XB{1'b0}}:next_x;
    wire [YB-1:0] pixel_y=frame_start?{YB{1'b0}}:next_y;
    wire [YB:0] y_twice={pixel_y,1'b0};
    wire [YB:0] dy=(y_twice>IMG_HEIGHT-1)?y_twice-(IMG_HEIGHT-1):(IMG_HEIGHT-1)-y_twice;
    reg valid_d,user_d,last_d,valid_mult_d,user_mult_d,last_mult_d;
    reg [PIXELS*24-1:0] rgb_d,rgb_mult_d;
    wire [6:0] depth_d=FIXED_DEPTH;
    // STYLE uses the teammate's fixed spatial coefficient. Non-STYLE keeps
    // the old frame-latched gain contract; production RED/MOTION submit 256.
    reg [8:0] gain_meta,gain_sync,gain_d,gain_stable,gain_active,gain_s1;
    reg style_active,style_s1;
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n) begin
            gain_meta<=256;gain_sync<=256;gain_d<=256;gain_stable<=256;gain_active<=256;gain_s1<=256;
            style_active<=0;style_s1<=0;
        end else begin
            gain_meta<=I_gain;gain_sync<=gain_meta;gain_d<=gain_sync;
            if(gain_sync==gain_d) gain_stable<=(gain_sync>=128&&gain_sync<=384)?gain_sync:9'd256;
            if(frame_start) begin gain_active<=gain_stable;style_active<=I_style_enable;end
            gain_s1<=frame_start?gain_stable:gain_active;
            style_s1<=frame_start?I_style_enable:style_active;
        end
    // 倍坐标以(W-1,H-1)为中心，奇偶尺寸均镜像对称。
    function [4:0] axis_weight;
        input integer distance2,radius;
        integer k;
        begin
            axis_weight=0;
            for(k=16;k>=1;k=k-1)
                if(distance2 < (2*radius*k)/16) axis_weight=17-k;
        end
    endfunction
    function [4:0] height_weight;
        input integer distance2,height;
        begin
            if(distance2<height) height_weight=16;
            else if(distance2>=height+128) height_weight=0;
            else height_weight=(height+128-distance2)>>3;
        end
    endfunction
    wire [4:0] height_wy=height_weight(dy,576);
    function [4:0] combine_axes;
        input [4:0] x,y;
        reg [9:0] total;
        integer k;
        begin
            total=10'd8;
            for(k=0;k<5;k=k+1) if(y[k]) total=total+({5'd0,x}<<k);
            combine_axes=total[8:4];
        end
    endfunction
    // 明确展开小权重的移位加法，避免另推导四路通用depth*weight乘法器。
    function [6:0] scaled_depth;
        input [6:0] d;
        input [4:0] w;
        reg [11:0] total;
        integer bit_index;
        begin
            total=12'd8;
            for(bit_index=0;bit_index<5;bit_index=bit_index+1)
                if(w[bit_index]) total=total+({5'd0,d}<<bit_index);
            scaled_depth=total[10:4];
        end
    endfunction
    genvar p;
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n) begin
            pending_user<=0;next_x<=0;next_y<=0;
            valid_d<=0;user_d<=0;last_d<=0;rgb_d<=0;
            valid_mult_d<=0;user_mult_d<=0;last_mult_d<=0;rgb_mult_d<=0;
            O_tvalid<=0;O_tuser<=0;O_tlast<=0;
        end else begin
            if(frame_start) begin pending_user<=0;end
            else if(I_tuser) pending_user<=1;
            // 空拍不移动坐标；早到SOF在首个有效组归零；短帧后的新SOF重新定位。
            if(I_tvalid) begin
                if(I_tlast || pixel_x>=IMG_WIDTH-PIXELS) begin
                    next_x<=0;
                    next_y<=(pixel_y>=IMG_HEIGHT-1)?{YB{1'b0}}:pixel_y+1'b1;
                end else begin next_x<=pixel_x+PIXELS;next_y<=pixel_y;end
            end
            valid_d<=I_tvalid;user_d<=frame_start;last_d<=I_tlast;rgb_d<=I_tdata;
            // RGB与空间权重保持原三拍对应；固定强度不再经过运行时参数路径。
            rgb_mult_d<=rgb_d;
            valid_mult_d<=valid_d;user_mult_d<=user_d;last_mult_d<=last_d;
            O_tvalid<=valid_mult_d;O_tuser<=user_mult_d;O_tlast<=last_mult_d;
        end
    generate for(p=0;p<PIXELS;p=p+1) begin:g_pixel
        // 高位像素在最左，四个像素分别取自己的位置权重。
        wire [XB:0] x_twice={pixel_x,1'b0}+2*p;
        wire [XB:0] dx=(x_twice>IMG_WIDTH-1)?x_twice-(IMG_WIDTH-1):(IMG_WIDTH-1)-x_twice;
        wire [4:0] wx=axis_weight(dx,RX);
        wire [4:0] weight=combine_axes(wx,height_wy);
        reg [4:0] weight_d;
        wire [8:0] local_gain=style_s1 ? 9'd256-scaled_depth(depth_d,weight_d) : gain_s1;
        reg [16:0] product;
        wire [16:0] rounded=product+17'd128;
        always @(posedge I_clk or negedge I_rst_n)
            if(!I_rst_n) begin weight_d<=0;product<=0;O_tdata[PIXELS*24-1-24*p -: 24]<=0;end
            else begin
                weight_d<=weight;
                product<=rgb_d[PIXELS*24-9-24*p -: 8]*local_gain;
                if(!valid_mult_d) O_tdata[PIXELS*24-1-24*p -: 24]<=0;
                else O_tdata[PIXELS*24-1-24*p -: 24]<={rgb_mult_d[PIXELS*24-1-24*p -: 8],
                    (rounded[16]?8'd255:rounded[15:8]),rgb_mult_d[PIXELS*24-17-24*p -: 8]};
            end
    end endgenerate
endmodule
