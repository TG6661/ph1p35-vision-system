// Test-only GG224/576 arithmetic oracle; not a frozen old-version reference.
// 中心减绿：AWB之后、Gamma之前。Q8中心增益固定224/256（0.875）。
// 外围严格为1倍，中心向外用16级权重恢复；R/B逐位透传。
// 四RGB888/拍、三拍流水：空间权重 -> 绿色乘法 -> 输出，无行/帧缓存。
module ref_green_gain96 #(parameter integer IMG_WIDTH=1280,IMG_HEIGHT=720)(
    input I_clk,I_rst_n,I_tvalid,I_tuser,I_tlast,
    input [95:0] I_tdata,input [8:0] I_gain,
    output reg O_tvalid,O_tuser,O_tlast,output reg [95:0] O_tdata
);
    localparam integer XB=(IMG_WIDTH>1)?$clog2(IMG_WIDTH):1;
    localparam integer YB=(IMG_HEIGHT>1)?$clog2(IMG_HEIGHT):1;
    // 横向半径3/8画宽；纵向576行平台、上下64行渐变。
    // 全部半径/阈值只在编译期计算，不引入实时除法器。
    localparam integer RX=(IMG_WIDTH*3/8>0)?IMG_WIDTH*3/8:1;
    // I_gain仅保留端口兼容；编译期固定深度，移除运行时增益同步和帧锁存。
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
    reg [95:0] rgb_d,rgb_mult_d;
    wire [6:0] depth_d=FIXED_DEPTH;
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
    wire [4:0] wy=dy<576 ? 16 : dy>=704 ? 0 : (704-dy)/8;
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
                if(I_tlast || pixel_x>=IMG_WIDTH-4) begin
                    next_x<=0;
                    next_y<=(pixel_y>=IMG_HEIGHT-1)?{YB{1'b0}}:pixel_y+1'b1;
                end else begin next_x<=pixel_x+4;next_y<=pixel_y;end
            end
            valid_d<=I_tvalid;user_d<=frame_start;last_d<=I_tlast;rgb_d<=I_tdata;
            // RGB与空间权重保持原三拍对应；固定强度不再经过运行时参数路径。
            rgb_mult_d<=rgb_d;
            valid_mult_d<=valid_d;user_mult_d<=user_d;last_mult_d<=last_d;
            O_tvalid<=valid_mult_d;O_tuser<=user_mult_d;O_tlast<=last_mult_d;
        end
    generate for(p=0;p<4;p=p+1) begin:g_pixel
        // 高位像素在最左，四个像素分别取自己的位置权重。
        wire [XB:0] x_twice={pixel_x,1'b0}+2*p;
        wire [XB:0] dx=(x_twice>IMG_WIDTH-1)?x_twice-(IMG_WIDTH-1):(IMG_WIDTH-1)-x_twice;
        wire [4:0] wx=axis_weight(dx,RX);
        wire [4:0] weight=(wx*wy+8)/16;
        reg [4:0] weight_d;
        wire [8:0] local_gain=9'd256-scaled_depth(depth_d,weight_d);
        reg [16:0] product;
        wire [16:0] rounded=product+17'd128;
        always @(posedge I_clk or negedge I_rst_n)
            if(!I_rst_n) begin weight_d<=0;product<=0;O_tdata[95-24*p -: 24]<=0;end
            else begin
                weight_d<=weight;
                product<=rgb_d[87-24*p -: 8]*local_gain;
                if(!valid_mult_d) O_tdata[95-24*p -: 24]<=0;
                else O_tdata[95-24*p -: 24]<={rgb_mult_d[95-24*p -: 8],
                    rounded[15:8],rgb_mult_d[79-24*p -: 8]};
            end
    end endgenerate
endmodule
