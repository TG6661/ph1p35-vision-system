// Coherent held-bus transfer; latest value is sent after each acknowledgement.
module view_mode_cdc #(parameter BITS=2,parameter [BITS-1:0] RESET_VALUE=0,
    parameter SYNC_RELEASE=0)(
    input wire src_clk,dst_clk,reset_n,
    input wire [BITS-1:0] value,
    output reg [BITS-1:0] received
);
    wire idle,srn,drn,pending;
    reg submit;
    reg [BITS-1:0] published;
    target_result_cdc #(.SYNC_RELEASE(SYNC_RELEASE)) u_cdc(.src_clk(src_clk),.dst_clk(dst_clk),.reset_n(reset_n),
        .src_submit(submit),.src_idle(idle),.src_reset_n(srn),.dst_reset_n(drn),
        .dst_pending(pending),.dst_accept(pending));
    always @(posedge src_clk or negedge srn)
        if(!srn) begin submit<=0;published<=RESET_VALUE;end
        else begin
            submit<=0;
            if(idle && !submit) begin published<=value;submit<=1;end
        end
    always @(posedge dst_clk or negedge drn)
        if(!drn) received<=RESET_VALUE;
        else if(pending) received<=published;
endmodule
