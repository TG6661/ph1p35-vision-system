// One outstanding bundled-data transaction. Both domains share reset_n.
// Payload is held from source request until the synchronized acknowledgement.
module target_result_cdc #(parameter SYNC_RELEASE=0)(
    input wire src_clk,dst_clk,reset_n,
    input wire src_submit,
    output wire src_idle,src_reset_n,dst_reset_n,
    output wire dst_pending,
    input wire dst_accept
);
    (* ASYNC_REG="TRUE" *) reg [1:0] sr,dr;
    (* ASYNC_REG="TRUE" *) reg [1:0] req_sync,ack_sync;
    reg request,ack;
    always @(posedge src_clk or negedge reset_n)
        if(!reset_n) sr<=0; else sr<={sr[0],1'b1};
    always @(posedge dst_clk or negedge reset_n)
        if(!reset_n) dr<=0; else dr<={dr[0],1'b1};
    assign src_reset_n=sr[1];
    assign dst_reset_n=dr[1];
    assign src_idle=sr[1] && request==ack_sync[1];
    assign dst_pending=dr[1] && req_sync[1]!=ack;
    // MCU reset is generated in AHB and is asynchronous to the video clocks.
    // In this mode only sr/dr see the raw reset; all handshake flops release
    // from their own clock-domain reset synchronizer. Legacy users unchanged.
    wire src_logic_reset_n=SYNC_RELEASE ? sr[1] : reset_n;
    wire dst_logic_reset_n=SYNC_RELEASE ? dr[1] : reset_n;
    always @(posedge src_clk or negedge src_logic_reset_n) begin
        if(!src_logic_reset_n) begin request<=0; ack_sync<=0; end
        else if(!sr[1]) begin request<=0; ack_sync<=0; end
        else begin
            ack_sync<={ack_sync[0],ack};
            if(src_submit && src_idle) request<=~request;
        end
    end
    always @(posedge dst_clk or negedge dst_logic_reset_n) begin
        if(!dst_logic_reset_n) begin ack<=0; req_sync<=0; end
        else if(!dr[1]) begin ack<=0; req_sync<=0; end
        else begin
            req_sync<={req_sync[0],request};
            if(dst_accept && dst_pending) ack<=req_sync[1];
        end
    end
endmodule
