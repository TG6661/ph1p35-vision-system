`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// 安路 BRAM IP 的功能仿真替代模型
// -----------------------------------------------------------------------------
// 三个模块名和端口名与工程中的 IP 完全相同。每个实例都有独立存储器，
// A 口同步写、B 口同步读，B 口读数据在时钟上升沿后更新（1 拍读延迟）。
// 这些模型只应加入ModelSim等通用RTL仿真，不应加入FPGA综合工程。
// -----------------------------------------------------------------------------

// zhenghe 使用的 32-bit 行重定时缓存。
module blk_mem_gen_zhenghe (
    input             clka,
    input             wea,
    input      [8:0] addra,
    input      [31:0] dia,
    input             clkb,
    input      [8:0] addrb,
    output reg [31:0] dob
);
    reg [31:0] mem [0:511];

    always @(posedge clka) begin
        if (wea)
            mem[addra] <= dia;
    end

    always @(posedge clkb) begin
        dob <= mem[addrb];
    end
endmodule

// demosaic 两级行缓存使用的 33-bit BRAM（32-bit 像素组 + tuser）。
module blk_mem_gen_demosaic (
    input             clka,
    input             wea,
    input      [8:0] addra,
    input      [32:0] dia,
    input             clkb,
    input      [8:0] addrb,
    output reg [32:0] dob
);
    reg [32:0] mem [0:511];

    always @(posedge clka) begin
        if (wea)
            mem[addra] <= dia;
    end

    always @(posedge clkb) begin
        dob <= mem[addrb];
    end
endmodule

// AWB 的 96-bit 像素延迟缓存。
module blk_mem_gen_awb_delay_signal (
    input             clka,
    input             wea,
    input      [8:0] addra,
    input      [95:0] dia,
    input             clkb,
    input      [8:0] addrb,
    output reg [95:0] dob
);
    reg [95:0] mem [0:511];

    always @(posedge clka) begin
        if (wea)
            mem[addra] <= dia;
    end

    always @(posedge clkb) begin
        dob <= mem[addrb];
    end
endmodule
