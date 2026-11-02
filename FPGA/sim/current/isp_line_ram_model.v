`timescale 1ns/1ps
// 仅ModelSim使用：参考RAM IP的A口同步写、B口同步读（NOREG读延迟1拍）。
// TD使用hdl_source/isp/isp_line_ram.v中的PH1P_LOGIC_ERAM实现。
module isp_line_ram #(
    parameter DATA_WIDTH_A=20,ADDR_WIDTH_A=10,DATA_DEPTH_A=1024,
    parameter DATA_WIDTH_B=DATA_WIDTH_A,ADDR_WIDTH_B=ADDR_WIDTH_A,DATA_DEPTH_B=DATA_DEPTH_A,
    parameter REGMODE_A="NOREG",REGMODE_B="OUTREG",WRITEMODE_A="NORMAL",WRITEMODE_B="NORMAL",
    parameter RESETMODE_A="ASYNC",RESETMODE_B="ASYNC",INIT_FILE="NONE",FILL_ALL="NONE",
    parameter RAM_MODE="DP",CLK_MODE="ASYNC"
)(
    input [DATA_WIDTH_A-1:0] dia,
    input [ADDR_WIDTH_A-1:0] addra,input clka,wea,
    output reg [DATA_WIDTH_A-1:0] doa,
    input [DATA_WIDTH_B-1:0] dib,
    input [ADDR_WIDTH_B-1:0] addrb,input clkb,web,
    output reg [DATA_WIDTH_B-1:0] dob
);
    reg [DATA_WIDTH_A-1:0] mem[0:DATA_DEPTH_A-1];
    always @(posedge clka) begin doa<=mem[addra];if(wea) mem[addra]<=dia;end
    always @(posedge clkb) begin dob<=mem[addrb];if(web) mem[addrb]<=dib;end
endmodule
