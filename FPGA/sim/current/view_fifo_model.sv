`timescale 1ns/1ps
// Test-only model of the existing 512x128 dual-clock FIFO. Two-clock pointer
// synchronization and a registered read match its externally used contract.
module w128_d512_fifo(input rst,clkw,we,input [127:0] di,
    output afull,full_flag,output [8:0] wrusedw,
    input clkr,re,output reg [127:0] dout,output [8:0] rdusedw,
    output reg valid,output empty_flag,aempty);
    reg [127:0] mem[0:511];
    reg [9:0] wp=0,rp=0,rs1=0,rs2=0,ws1=0,ws2=0;
    wire [9:0] wu=wp-rs2,ru=ws2-rp;
    assign wrusedw=wu[8:0];assign rdusedw=ru[8:0];
    assign full_flag=wu>=511;assign afull=wu>=480;
    assign empty_flag=ru==0;assign aempty=ru<=4;
    always @(posedge clkw or posedge rst)
        if(rst) begin wp<=0;rs1<=0;rs2<=0;end
        else begin
            rs1<=rp;rs2<=rs1;
            if(we) begin
                if(full_flag) $fatal(1,"write FIFO overflow");
                mem[wp[8:0]]<=di;wp<=wp+1'b1;
            end
        end
    always @(posedge clkr or posedge rst)
        if(rst) begin rp<=0;ws1<=0;ws2<=0;dout<=0;valid<=0;end
        else begin
            ws1<=wp;ws2<=ws1;valid<=re;
            if(re) begin
                if(empty_flag) $fatal(1,"read FIFO underflow");
                dout<=mem[rp[8:0]];rp<=rp+1'b1;
            end
        end
endmodule
