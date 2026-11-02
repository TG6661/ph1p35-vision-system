`timescale 1ns/1ps
module tb_exposure_stats;
 reg clk=0,rst=0,valid=0,user=0,last=0,auto_wb=0,req=0,test_passed=0;
 always #5 clk=~clk;
 reg [47:0] data=0;reg [71:0] gain={32'd1,20'd80000,20'd70000};
 wire [47:0] out,old;wire ov,ou,ol,bv,bu,bl,toggle,otoggle,ack,oack;
 wire [191:0] stats,ostats;
 awb_mcu96 #(.PIXELS(2),.IMG_WIDTH(32),.IMG_HEIGHT(8)) dut(
 .I_clk(clk),.I_rst_n(rst),.I_tuser(user),.I_tlast(last),.I_tvalid(valid),.I_tdata(data),
 .O_tuser(ou),.O_tlast(ol),.O_tvalid(ov),.O_tdata(out),.I_mcu_ready(auto_wb),
 .O_stats_request(toggle),.O_stats_payload(stats),.I_gain_request(req),.I_gain_payload(gain),.O_gain_ack(ack));
 awb_mcu96_reference #(.PIXELS(2),.IMG_WIDTH(32),.IMG_HEIGHT(8)) ref_wb(
 .I_clk(clk),.I_rst_n(rst),.I_tuser(user),.I_tlast(last),.I_tvalid(valid),.I_tdata(data),
 .O_tuser(bu),.O_tlast(bl),.O_tvalid(bv),.O_tdata(old),.I_mcu_ready(auto_wb),
 .O_stats_request(otoggle),.O_stats_payload(ostats),.I_gain_request(req),.I_gain_payload(gain),.O_gain_ack(oack));
 integer cycles=0,frames=0;reg previous;
 always @(posedge clk) begin
  #1;if(rst)begin
   cycles++;
   if({out,ov,ou,ol,ack}!=={old,bv,bu,bl,oack}) $fatal(1,"WB pixels/timing/ack changed");
  end
 end
 task frame(input [23:0] pixel,input integer count,input integer r,input integer g,input integer b);
 integer i;begin
  previous=toggle;
  for(i=0;i<128;i++)begin
   @(negedge clk);data={pixel,pixel};valid=1;user=(i==0);last=(i%16==15);
  end
  @(negedge clk);valid=0;user=0;last=0;repeat(5)@(negedge clk);
  if(toggle==previous || stats[127:96]!=count || stats[31:0]!=r || stats[63:32]!=g || stats[95:64]!=b)
   $fatal(1,"metering disabled/stats wrong %h",stats);
  if(auto_wb && stats!==ostats) $fatal(1,"auto WB stats changed");
  frames++;
 end endtask
 initial begin
  repeat(5)@(negedge clk);rst=1;repeat(8)@(negedge clk);
  frame(24'h325064,64,3201,5121,6401); // fixed WB must still meter
  frame(24'hffffff,0,1,1,1); // exclude clipped samples, keep explicit zero count
  auto_wb=1;req=1;repeat(12)@(negedge clk);
  frame(24'h325064,64,3201,5121,6401); // gain applied at SOF, stats remain pre-gain
  auto_wb=0;repeat(10)@(negedge clk);
  frame(24'h000000,64,1,1,1); // darkness is NOT clipping
  // Reset a partial frame. No stale aggregate may leak into next publication.
  @(negedge clk);valid=1;user=1;repeat(3)@(negedge clk);user=0;
  rst=0;valid=0;repeat(5)@(negedge clk);rst=1;repeat(8)@(negedge clk);
  frame(24'h325064,64,3201,5121,6401);
  test_passed=1;$display("EXPOSURE_STATS_PASS frames=%0d pixel_equivalence_cycles=%0d",frames,cycles);$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
