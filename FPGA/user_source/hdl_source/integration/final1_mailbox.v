// One stable payload in flight. Source may only submit when ready; destination
// ACK follows capture. Reset is shared by both domains, never a mode reset.
// EXTERNAL_HOLD requires a registered producer to hold data from before send
// until ready returns. The default still captures arbitrary input payloads.
module final1_mailbox #(parameter WIDTH=32, parameter EXTERNAL_HOLD=0)(
 input src_clk,dst_clk,rst_n,input send,input [WIDTH-1:0] data,
 output ready,output reg valid,output reg [WIDTH-1:0] received
);
 wire src_reset_n,dst_reset_n;
 final1_reset_release u_src_reset(.clk(src_clk),.async_reset_n(rst_n),.reset_n(src_reset_n));
 final1_reset_release u_dst_reset(.clk(dst_clk),.async_reset_n(rst_n),.reset_n(dst_reset_n));
 reg request,ack;
 wire [WIDTH-1:0] payload;
 generate if(EXTERNAL_HOLD) begin:g_external
  assign payload=data;
 end else begin:g_internal
  reg [WIDTH-1:0] held;
  always @(posedge src_clk or negedge src_reset_n)
   if(!src_reset_n) held<=0;
   else if(send && ready) held<=data;
  assign payload=held;
 end endgenerate
 (* ASYNC_REG="TRUE" *) reg [1:0] req_sync,ack_sync;
 assign ready=src_reset_n && request==ack_sync[1];
 always @(posedge src_clk or negedge src_reset_n)
  if(!src_reset_n) begin request<=0;ack_sync<=0;end
  else begin
   ack_sync<={ack_sync[0],ack};
   if(send && ready) request<=~request;
  end
 always @(posedge dst_clk or negedge dst_reset_n)
  if(!dst_reset_n) begin req_sync<=0;ack<=0;valid<=0;received<=0;end
  else begin
   req_sync<={req_sync[0],request};valid<=0;
   if(dst_reset_n && req_sync[1]!=ack) begin received<=payload;valid<=1;ack<=req_sync[1];end
  end
endmodule

// Shared asynchronous assertion cancels both sides of every transaction.
// Three local rising edges release reset; a stopped clock remains in reset.
module final1_reset_release(input clk,async_reset_n,output reset_n);
 (* ASYNC_REG="TRUE" *) reg [2:0] release_pipe;
 always @(posedge clk or negedge async_reset_n)
  if(!async_reset_n) release_pipe<=0;
  else release_pipe<={release_pipe[1:0],1'b1};
 assign reset_n=release_pipe[2];
endmodule
