// Asynchronous assertion, synchronous release after 16 destination clocks.
// Each clock domain owns its reset chain; no video reset is driven here.
module mcu_reset_sync(
    input wire clk, async_reset_n,
    output wire reset_n
);
    (* ASYNC_REG="TRUE" *) reg [15:0] release_pipe;
    always @(posedge clk or negedge async_reset_n)
        if (!async_reset_n) release_pipe <= 16'd0;
        else release_pipe <= {release_pipe[14:0],1'b1};
    assign reset_n = release_pipe[15];
endmodule
