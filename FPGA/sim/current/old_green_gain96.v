// AWB之后的手动绿色校正。Q8系数256=1.00倍，128..384=0.50..1.50倍。
// 不改变R/B；G乘法分两拍、四舍五入并饱和到255。整帧固定，避免帧中变色。
// PIXELS=2为生产配置，4为原接口兼容配置。
module old_green_gain96 #(parameter PIXELS=4)(
    input I_clk,I_rst_n,I_tvalid,I_tuser,I_tlast,
    input [PIXELS*24-1:0] I_tdata,input [8:0] I_gain,
    output reg O_tvalid,O_tuser,O_tlast,output reg [PIXELS*24-1:0] O_tdata
);
    reg [8:0] gain_meta,gain_sync,gain_d,gain_stable,gain_active;
    reg pending_user;
    wire frame_start=I_tvalid&&(I_tuser||pending_user);
    wire [8:0] frame_gain=frame_start?gain_stable:gain_active;
    reg valid_d,user_d,last_d;
    reg [PIXELS*24-1:0] rgb_d;
    genvar p;
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n) begin
            gain_meta<=256;gain_sync<=256;gain_d<=256;gain_stable<=256;gain_active<=256;
            pending_user<=0;valid_d<=0;user_d<=0;last_d<=0;rgb_d<=0;
            O_tvalid<=0;O_tuser<=0;O_tlast<=0;
        end else begin
            gain_meta<=I_gain;gain_sync<=gain_meta;gain_d<=gain_sync;
            if(gain_sync==gain_d) gain_stable<=(gain_sync>=128&&gain_sync<=384)?gain_sync:9'd256;
            if(frame_start) begin gain_active<=gain_stable;pending_user<=0;end
            else if(I_tuser) pending_user<=1;
            valid_d<=I_tvalid;user_d<=frame_start;last_d<=I_tlast;rgb_d<=I_tdata;
            O_tvalid<=valid_d;O_tuser<=user_d;O_tlast<=last_d;
        end
    generate for(p=0;p<PIXELS;p=p+1) begin:g_pixel
        reg [16:0] product;
        wire [16:0] rounded=product+17'd128;
        always @(posedge I_clk or negedge I_rst_n)
            if(!I_rst_n) begin product<=0;O_tdata[PIXELS*24-1-24*p -: 24]<=0;end
            else begin
                product<=I_tdata[PIXELS*24-9-24*p -: 8]*frame_gain;
                if(!valid_d) O_tdata[PIXELS*24-1-24*p -: 24]<=0;
                else O_tdata[PIXELS*24-1-24*p -: 24]<={rgb_d[PIXELS*24-1-24*p -: 8],
                    (rounded[16]?8'd255:rounded[15:8]),rgb_d[PIXELS*24-17-24*p -: 8]};
            end
    end endgenerate
endmodule
