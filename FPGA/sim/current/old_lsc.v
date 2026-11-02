module old_lsc #(parameter integer IMG_WIDTH=1280,IMG_HEIGHT=720)(
    input I_clk,I_rst_n,input [39:0] I_raw4,input I_valid,I_user,I_last,
    input [1:0] I_level,
    output reg [39:0] O_raw4,output reg O_valid,O_user,O_last
);
    localparam integer GROUPS=IMG_WIDTH/4;
    localparam integer DEN_X=(IMG_WIDTH-1)*(IMG_WIDTH-1);
    localparam integer DEN_Y=(IMG_HEIGHT-1)*(IMG_HEIGHT-1);
    reg [5:0] x_curve[0:GROUPS-1]; /* fehdl force_ram=1, ram_style="bram_fast" */
    reg [5:0] y_curve[0:IMG_HEIGHT-1]; /* fehdl force_ram=1, ram_style="bram_fast" */
    integer i,distance;
    initial begin
        for(i=0;i<GROUPS;i=i+1)begin
            distance=8*i+3-(IMG_WIDTH-1);
            x_curve[i]=(32*distance*distance+DEN_X/2)/DEN_X;
        end
        for(i=0;i<IMG_HEIGHT;i=i+1)begin
            distance=2*i-(IMG_HEIGHT-1);
            y_curve[i]=(32*distance*distance+DEN_Y/2)/DEN_Y;
        end
    end
    reg [10:0] x,y;
    wire [10:0] sample_x=I_user?11'd0:x;
    wire [10:0] sample_y=I_user?11'd0:y;
    reg [1:0] level_meta,level_sync,level_d,level_stable,active_level,level_s1;
    reg [39:0] raw_s1;
    reg [5:0] x_s1,y_s1;
    reg [1:0] valid_pipe,user_pipe,last_pipe;
    wire [6:0] position_gain={1'b0,x_s1}+{1'b0,y_s1};
    wire [8:0] extra_gain=level_s1==0 ? 9'd0 :
        (level_s1==1 ? {2'b0,position_gain} :
        (level_s1==2 ? {1'b0,position_gain,1'b0} :
                       ({1'b0,position_gain,1'b0}+{2'b0,position_gain})));
    wire [8:0] gain_q8=9'd256+extra_gain;
    // 同步ROM不复位存储阵列；无效拍的数据不对外标为有效。
    always @(posedge I_clk)begin x_s1<=x_curve[sample_x];y_s1<=y_curve[sample_y];end
    always @(posedge I_clk or negedge I_rst_n)
        if(!I_rst_n)begin
            x<=0;y<=0;level_meta<=1;level_sync<=1;level_d<=1;level_stable<=1;active_level<=1;level_s1<=1;
            raw_s1<=0;valid_pipe<=0;user_pipe<=0;last_pipe<=0;O_valid<=0;O_user<=0;O_last<=0;
        end else begin
            level_meta<=I_level;level_sync<=level_meta;level_d<=level_sync;
            if(level_d==level_sync)level_stable<=level_sync;
            if(I_user)active_level<=level_stable;
            level_s1<=I_user?level_stable:active_level;
            raw_s1<=I_raw4;
            valid_pipe<={valid_pipe[0],I_valid};user_pipe<={user_pipe[0],I_user};last_pipe<={last_pipe[0],I_last};
            O_valid<=valid_pipe[1];O_user<=user_pipe[1];O_last<=last_pipe[1];
            // 同时兼容空白期SOF脉冲及与首组像素同拍的SOF。
            if(I_user)begin x<=I_valid?11'd1:11'd0;y<=0;end
            else if(I_valid)begin
                if(x==GROUPS-1)begin x<=0;y<=(y==IMG_HEIGHT-1)?0:y+1'b1;end
                else x<=x+1'b1;
            end
        end
    genvar p;
    generate for(p=0;p<4;p=p+1)begin:g_pixel
        reg [18:0] product_s2;
        always @(posedge I_clk or negedge I_rst_n)
            if(!I_rst_n)begin product_s2<=0;O_raw4[p*10+:10]<=0;end
            else begin
                product_s2<=raw_s1[p*10+:10]*gain_q8+19'd128;
                O_raw4[p*10+:10]<=product_s2[18]?10'd1023:product_s2[17:8];
            end
    end endgenerate
endmodule