// Apply the approved exposure/gain once after sensor initialization.
// The sensor still uses its reference grouped I2C write and NACK policy.
module camera_fixed_config #(
    parameter [15:0] EXPOSURE=16'd1991, GAIN=16'd190
)(
    input wire clk,reset_n,cfg_done,ae_done,
    output reg ae_req,
    output wire [15:0] exposure,gain
);
    reg submitted;
    assign exposure=EXPOSURE;
    assign gain=GAIN;
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin ae_req<=0; submitted<=0; end
        else begin
            ae_req<=0;
            if(!submitted && cfg_done && ae_done) begin ae_req<=1; submitted<=1; end
        end
    end
endmodule
