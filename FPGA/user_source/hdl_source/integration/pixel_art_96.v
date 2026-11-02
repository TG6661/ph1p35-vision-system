// 8x8块平均 + 每通道8级，匹配pixel_art_core(rgb,8,8)。
// 输入/输出均为每拍PIXELS像素，生产用2；最高24位为最左像素。
// 累加160个方块的RGB和，两个颜色库交替读写，无需保存原始8行。
// 先收齐8行再输出该条带；按输入行周期逐行输出，保留行间空拍。
// 输出重新生成SOF/EOL，最后条带自动排空，避免连续吐8行冲击DDR写FIFO。
// I_tready沿用本工程含义：下游ready；输入摄像头流不支持无限反压。
// 可吸收短暂输出暂停，持续暂停导致输入追上输出时需要上游系统限流。
module pixel_art_96 #(
    parameter IMG_WIDTH=1280, PIXELS=4,
    parameter IMG_HEIGHT=720,
    // DDR回放行可有等待；固定输出节拍避免上一行的长等待拖慢下一条带。
    // 输入行周期需不短于该值；0保留摄像头直接流的原周期测量方式。
    parameter FIXED_LINE_PERIOD=0
)(
    input I_clk, I_rst_n, I_tlast, I_tuser,
    input [PIXELS*24-1:0] I_tdata,
    input I_tvalid, I_tready,
    output O_tlast, O_tuser,
    output [PIXELS*24-1:0] O_tdata,
    output O_tvalid, O_tready
);
localparam BLOCKS=IMG_WIDTH/8;
localparam BEATS=IMG_WIDTH/PIXELS;
localparam BAND_BEATS=BEATS*8;
localparam BLOCK_SHIFT=$clog2(8/PIXELS);
localparam COUNT_BITS=$clog2(BAND_BEATS);
// 64*255=16320，需要14位累加器。同步读写有利于映射ERAM。
localparam BLOCK_ADDR_BITS=(BLOCKS>1)?$clog2(BLOCKS):1;
wire [41:0] sum_read;
reg [10:0] first_r,first_g,first_b;
reg [10:0] in_x;
reg [10:0] in_y;
reg write_bank;
reg [1:0] full;
reg [1:0] first_band;
wire [10:0] x = I_tuser ? 11'd0 : in_x;
wire [10:0] y = I_tuser ? 11'd0 : in_y;
wire bank = I_tuser ? 1'b0 : write_bank;
reg [9:0] four_r,four_g,four_b;
integer lane;
always @* begin
    four_r=0;four_g=0;four_b=0;
    for(lane=0;lane<PIXELS;lane=lane+1) begin
        four_r=four_r+{2'b0,I_tdata[lane*24+16+:8]};
        four_g=four_g+{2'b0,I_tdata[lane*24+8+:8]};
        four_b=four_b+{2'b0,I_tdata[lane*24+:8]};
    end
end
wire block_first=(x[BLOCK_SHIFT-1:0]==0);
wire block_last=(&x[BLOCK_SHIFT-1:0]);
wire [13:0] total_r = ((y[2:0]==0) ? 14'd0 : sum_read[41:28])+
                             {3'b0,first_r}+{4'b0,four_r};
wire [13:0] total_g = ((y[2:0]==0) ? 14'd0 : sum_read[27:14])+
                             {3'b0,first_g}+{4'b0,four_g};
wire [13:0] total_b = ((y[2:0]==0) ? 14'd0 : sum_read[13:0])+
                             {3'b0,first_b}+{4'b0,four_b};
// floor(sum/64)再除32，相当于sum[13:11]；输出round(index*255/7)。
function [7:0] palette;
    input [2:0] index;
    begin
        case(index)
            0:palette=0; 1:palette=36; 2:palette=73; 3:palette=109;
            4:palette=146; 5:palette=182; 6:palette=219; 7:palette=255;
        endcase
    end
endfunction
wire [23:0] block_color={palette(total_r[13:11]),palette(total_g[13:11]),palette(total_b[13:11])};
wire band_done=I_tvalid && (x==BEATS-1) && (y[2:0]==7);

reg reading, read_bank;
reg [COUNT_BITS-1:0] read_count;
reg [10:0] read_x;
wire [23:0] color_read;
reg valid_q,last_q,user_q;
// 用相邻输入行尾测量行周期，输出BEATS个有效字后等待剩余行间隔。
// 帧首只重置测量相位，不清除上一个输出帧仍需使用的行周期。
reg line_seen;
reg [15:0] line_ticks,line_period,output_gap;
wire input_line_end=I_tvalid && I_tlast;
wire [15:0] measured_period=(line_ticks==16'hffff)?16'hffff:line_ticks+1'b1;
always @(posedge I_clk or negedge I_rst_n) begin
    if(!I_rst_n) begin line_seen<=0;line_ticks<=0;line_period<=BEATS;end
    else if(I_tvalid && I_tuser) begin line_seen<=0;line_ticks<=0;end
    else if(input_line_end) begin
        if(line_seen && measured_period>=BEATS) line_period<=measured_period;
        line_seen<=1;line_ticks<=0;
    end else if(line_ticks!=16'hffff) line_ticks<=line_ticks+1'b1;
end
wire advance=!valid_q || I_tready;
wire launch=reading && advance && (output_gap==0);
wire release_bank=launch && (read_count==BAND_BEATS-1);
assign O_tready=I_tready;
assign O_tvalid=valid_q;
assign O_tlast=last_q;
assign O_tuser=user_q;
assign O_tdata={PIXELS{color_read}};

// Explicit synchronous ERAM. The two color banks share one address space.
// Read-address holding keeps output data stable during downstream stalls.
wire [BLOCK_ADDR_BITS-1:0] sum_address=x[BLOCK_ADDR_BITS+BLOCK_SHIFT-1:BLOCK_SHIFT];
reg [BLOCK_ADDR_BITS:0] color_address_hold;
wire [BLOCK_ADDR_BITS:0] color_address=launch ?
    {read_bank,read_x[BLOCK_ADDR_BITS+BLOCK_SHIFT-1:BLOCK_SHIFT]}:color_address_hold;
always @(posedge I_clk or negedge I_rst_n)
    if(!I_rst_n) color_address_hold<=0;
    else if(launch) color_address_hold<=color_address;
isp_line_ram #(.DATA_WIDTH_A(42),.DATA_WIDTH_B(42),
    .ADDR_WIDTH_A(BLOCK_ADDR_BITS),.ADDR_WIDTH_B(BLOCK_ADDR_BITS),
    .DATA_DEPTH_A(1<<BLOCK_ADDR_BITS),.DATA_DEPTH_B(1<<BLOCK_ADDR_BITS),
    .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("READBEFOREWRITE")) u_sum_eram(
    .clka(I_clk),.wea(I_tvalid && block_last),.addra(sum_address),.dia({total_r,total_g,total_b}),.doa(sum_read),
    .clkb(I_clk),.web(1'b0),.addrb({BLOCK_ADDR_BITS{1'b0}}),.dib(42'd0),.dob());
isp_line_ram #(.DATA_WIDTH_A(24),.DATA_WIDTH_B(24),
    .ADDR_WIDTH_A(BLOCK_ADDR_BITS+1),.ADDR_WIDTH_B(BLOCK_ADDR_BITS+1),
    .DATA_DEPTH_A(2<<BLOCK_ADDR_BITS),.DATA_DEPTH_B(2<<BLOCK_ADDR_BITS),
    .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_B("READBEFOREWRITE")) u_color_eram(
    .clka(I_clk),.wea(I_tvalid && block_last && y[2:0]==7),.addra({bank,sum_address}),.dia(block_color),.doa(),
    .clkb(I_clk),.web(1'b0),.addrb(color_address),.dib(24'd0),.dob(color_read));
// 输入每8/PIXELS拍组成8个横向像素；最后一拍写回，之前各拍累加局部和。
always @(posedge I_clk) begin
    if (I_tvalid) begin
        if(block_first) begin first_r<=four_r;first_g<=four_g;first_b<=four_b;end
        else if(!block_last) begin
            first_r<=first_r+four_r;first_g<=first_g+four_g;first_b<=first_b+four_b;
        end
    end
end

always @(posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        in_x<=0; in_y<=0; write_bank<=0;
        full<=0; first_band<=0;
        reading<=0; read_bank<=0; read_count<=0; read_x<=0;
        valid_q<=0; last_q<=0; user_q<=0;
        output_gap<=0;
    end else begin
        if(launch && read_x==BEATS-1)
            output_gap<=FIXED_LINE_PERIOD!=0 ?
                ((FIXED_LINE_PERIOD>BEATS)?FIXED_LINE_PERIOD-BEATS:0) :
                ((line_period>BEATS)?line_period-BEATS:0);
        else if(output_gap!=0) output_gap<=output_gap-1'b1;
        if (I_tvalid) begin
            if (x==BEATS-1) begin
                in_x<=0;
                in_y<=(y==IMG_HEIGHT-1) ? 11'd0 : y+11'd1;
                write_bank<=(y==IMG_HEIGHT-1) ? 1'b0 : ((y[2:0]==7) ? ~bank : bank);
            end else begin
                in_x<=x+11'd1; in_y<=y; write_bank<=bank;
            end
        end
        // 完整条带发布后才允许读出。内存无需复位，首行覆盖旧累加值。
        if (release_bank) full[read_bank]<=0;
        if (band_done) begin
            full[bank]<=1;
            first_band[bank]<=(y==7);
        end
        if (advance) begin
            valid_q<=launch;
            last_q<=launch && (read_x==BEATS-1);
            user_q<=launch && first_band[read_bank] && (read_count==0);
        end
        if (!reading) begin
            if (full[read_bank]) begin
                reading<=1; read_count<=0; read_x<=0;
            end
        end else if (launch) begin
            read_x<=(read_x==BEATS-1) ? 11'd0 : read_x+11'd1;
            if (read_count==BAND_BEATS-1) begin
                read_count<=0; read_bank<=~read_bank;
                // 对连续输入直接切下一个库，避免条带间空拍累积。
                reading<=full[~read_bank] || (band_done && bank!=read_bank);
            end else read_count<=read_count+1'b1;
        end
    end
end
endmodule
