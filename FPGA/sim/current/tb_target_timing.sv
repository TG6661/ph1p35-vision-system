`timescale 1ns/1ps
module tb_target_timing;
 reg a=0,d=0,rst=0,test_passed=0;
 always #3.333 a=~a;
 always #7.5 d=~d;
 reg write=0;reg [4:0] ww=0,rw=0;reg [31:0] wd=0;
 reg sv=0,sd=0,mr=0,mdr=0;
 reg [69:0] record=0;reg [15:0] count=0,total=0;
 reg [3:0] error=0;reg [31:0] frame=0;
 wire sr,dsr,mv,mdv,alive,rr,sr0,dsr0,mv0,mdv0,alive0,rr0;
 wire [31:0] rd,rd0,mf,mf0;wire [51:0] mout,mout0;
 wire [15:0] mc,mc0;wire [3:0] me,me0;
 mcu_target_bridge #(.STALE_CYCLES(300)) dut(
  .ahb_clk(a),.detector_clk(d),.reset_n(rst),.write(write),.write_word(ww),.wdata(wd),.read_word(rw),.rdata(rd),
  .s_valid(sv),.s_ready(sr),.s_record(record),.s_done_valid(sd),.s_done_ready(dsr),.s_count(count),.s_total(total),.s_error(error),.s_frame(frame),
  .m_valid(mv),.m_ready(mr),.m_record(mout),.m_done_valid(mdv),.m_done_ready(mdr),.m_count(mc),.m_error(me),.m_frame(mf),.alive(alive),.result_reset_n(rr));
 mcu_target_bridge_timing_reference #(.STALE_CYCLES(300)) ref_dut(
  .ahb_clk(a),.detector_clk(d),.reset_n(rst),.write(write),.write_word(ww),.wdata(wd),.read_word(rw),.rdata(rd0),
  .s_valid(sv),.s_ready(sr0),.s_record(record),.s_done_valid(sd),.s_done_ready(dsr0),.s_count(count),.s_total(total),.s_error(error),.s_frame(frame),
  .m_valid(mv0),.m_ready(mr),.m_record(mout0),.m_done_valid(mdv0),.m_done_ready(mdr),.m_count(mc0),.m_error(me0),.m_frame(mf0),.alive(alive0),.result_reset_n(rr0));
 integer cycles=0,delivered=0,records=0,commits=0,expected_count=0;
 reg compare=0;reg [51:0] expected[0:7];
 always @(posedge a) begin
  #0.2;
  if(rst && compare)begin
   cycles++;
   if(dut.tx_busy!==ref_dut.tx_busy || rd!==rd0 ||
     {dut.tx_written,dut.tx_submit,dut.tx_inflight,dut.rejected,dut.rx_ready,dut.accepted_count,dut.delivered_sequence}!==
     {ref_dut.tx_written,ref_dut.tx_submit,ref_dut.tx_inflight,ref_dut.rejected,ref_dut.rx_ready,ref_dut.accepted_count,ref_dut.delivered_sequence})
    $fatal(1,"target bridge cycle equivalence");
   if(!dut.tx_busy && !dut.tx_idle)$fatal(1,"unowned outstanding mailbox");
  end
 end
 always @(posedge d) begin
  if(rst && compare)begin
   if({sr,dsr,mv,mdv,mout,mc,me,mf,alive,rr}!=={sr0,dsr0,mv0,mdv0,mout0,mc0,me0,mf0,alive0,rr0})
    $fatal(1,"detector stream/CDC equivalence");
   if(mv && mr)begin
    if(mout!==expected[records] || records>=expected_count)$fatal(1,"payload changed during ownership");
    records++;
   end
   if(mdv && mdr)begin
    if(mc!=expected_count || records!=expected_count || mf!=frame)$fatal(1,"result frame/count");
    delivered++;
   end
  end
 end
 task reset;
  begin
   @(negedge a);compare=0;rst=0;write=0;sv=0;sd=0;mr=0;mdr=0;
   repeat(5)@(negedge a);rst=1;
   // Startup adds one conservative local cycle, with no payload accepted.
   wait(dut.tx_armed);repeat(5)@(negedge a);compare=1;
  end
 endtask
 task wr(input [4:0] address,input [31:0] value);
  begin @(negedge a);write=1;ww=address;wd=value;end
 endtask
 task end_writes;begin @(negedge a);write=0;end endtask
 task source(input integer n);
  begin
   wait(dut.rx_idle);@(negedge d);frame=frame+1;count=n;total=n;error=0;
   for(integer k=0;k<n;k++)begin sv=1;record={8'(k+1),20'(100+k),11'd100,11'd10,10'd20,10'd50};@(negedge d);end
   sv=0;sd=1;@(negedge d);sd=0;wait(dut.rx_ready);
  end
 endtask
 task prepare(input integer n);
  reg [51:0] packed_record;
  begin
   records=0;expected_count=n;
   wr(8,dut.rx_sequence);wr(9,n);
   for(integer k=0;k<n;k++)begin
    packed_record={8'(k+1),2'(k%3),11'(10+k),11'(100+k),10'(20+k),10'(50+k)};
    expected[k]=packed_record;
    wr(10,2*k);wr(11,packed_record[31:0]);
    wr(10,2*k+1);wr(11,{12'd0,packed_record[51:32]});
   end
  end
 endtask
 task finish_result;
  integer old_delivered;
  begin
   old_delivered=delivered;wr(6,2);end_writes();commits++;
   if(!dut.tx_inflight)$fatal(1,"back-to-back final write/commit rejected");
   repeat(20)@(negedge a);
   // Every return-table command must reject while consumer is stalled.
   wr(8,32'hbad);wr(9,0);wr(10,15);wr(11,32'hffffffff);wr(6,2);end_writes();
   if(!dut.rejected)$fatal(1,"busy write not rejected");
   mr=1;mdr=1;wait(delivered>old_delivered);wait(!dut.tx_busy);
   @(negedge d);mr=0;mdr=0;
  end
 endtask
 initial begin
  reset();
  for(integer n=0;n<=8;n++)begin source(n);prepare(n);finish_result();end
  source(1);prepare(1);end_writes();
  // Stale sequence, incomplete table, invalid geometry/high bits, bad metadata.
  wr(8,dut.rx_sequence+1);wr(6,2);end_writes();if(dut.tx_inflight)$fatal(1,"stale accepted");
  prepare(1);wr(8,dut.rx_sequence);wr(6,2);end_writes();if(dut.tx_inflight)$fatal(1,"incomplete accepted");
  prepare(1);wr(10,1);wr(11,32'hfff00000);wr(6,2);end_writes();if(dut.tx_inflight)$fatal(1,"bad geometry accepted");
  prepare(1);wr(9,32'h1001);wr(6,2);end_writes();if(dut.tx_inflight)$fatal(1,"bad meta accepted");
  prepare(1);finish_result();
  for(integer k=0;k<64;k++)begin source($urandom_range(0,8));prepare(count);finish_result();end
  source(8);prepare(8);wr(6,2);end_writes();repeat(12)@(negedge d);
  reset();source(2);prepare(2);finish_result();
  repeat(400)@(negedge d);if(alive)$fatal(1,"stale watchdog");
  if(delivered!=75)$fatal(1,"missing completed results %0d",delivered);
  test_passed=1;$display("TARGET_TIMING_PASS cycles=%0d delivered=%0d ownership backpressure rejection reset watchdog",cycles,delivered);$finish;
 end
 initial begin #1000000;$fatal(1,"target timeout");end
endmodule
