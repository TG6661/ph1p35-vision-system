`timescale 1ns/1ps
// MCLK is 23.809524 MHz. Hold PWDNB low for ~1 ms, start I2C at ~6 ms.
module sc520_powerup #(
    parameter integer PWDNB_LOW_CYCLES = 23810,
    parameter integer I2C_START_CYCLES = 142857
)(
    input wire I_clk,
    input wire I_pll_locked,
    output reg O_pwdnb,
    output reg O_i2c_ready
);
    reg [17:0] count;
    always @(posedge I_clk or negedge I_pll_locked) begin
        if (!I_pll_locked) begin
            count <= 0;
            O_pwdnb <= 0;
            O_i2c_ready <= 0;
        end else begin
            if (count < I2C_START_CYCLES) count <= count + 1'b1;
            if (count >= PWDNB_LOW_CYCLES) O_pwdnb <= 1'b1;
            if (count >= I2C_START_CYCLES - 1) O_i2c_ready <= 1'b1;
        end
    end
endmodule
