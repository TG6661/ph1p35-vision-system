`timescale 1ns/1ps
module joint_regs_pair #(parameter R=0)(
 input clk,
 input rst_n,
 input write,
 input [8:0] write_word,
 input [8:0] read_word,
 input [31:0] wdata,
 input cfg_ready,
 input cfg_done,
 input [31:0] cfg_applied,
 input [7:0] faults,
 input camera_diag_valid,
 input [63:0] camera_diag,
 input post_diag_valid,
 input [127:0] post_diag,
 input motion_valid,
 input [223:0] motion_data,
 input awb_valid,
 input [255:0] awb_data,
 input result_ready,
 input gain_ready);
 wire [31:0] rdata,rdata_old;
 wire [31:0] ui_data,ui_data_old;
 wire motion_bg_reset,motion_bg_reset_old;
 wire motion_mask_enable,motion_mask_enable_old;
 wire [7:0] motion_y_offset,motion_y_offset_old;
 wire [7:0] motion_dwell_limit,motion_dwell_limit_old;
 wire cfg_send,cfg_send_old;
 wire [95:0] cfg_data,cfg_data_old;
 wire result_send,result_send_old;
 wire [223:0] result_data,result_data_old;
 wire gain_send,gain_send_old;
 wire [103:0] gain_data,gain_data_old;
final1_regs #(.READ_DECODE_REGISTERED(R)) dut(.clk(clk),.rst_n(rst_n),.write(write),.write_word(write_word),.read_word(read_word),.wdata(wdata),.cfg_ready(cfg_ready),.cfg_done(cfg_done),.cfg_applied(cfg_applied),.faults(faults),.camera_diag_valid(camera_diag_valid),.camera_diag(camera_diag),.post_diag_valid(post_diag_valid),.post_diag(post_diag),.motion_valid(motion_valid),.motion_data(motion_data),.awb_valid(awb_valid),.awb_data(awb_data),.result_ready(result_ready),.gain_ready(gain_ready),.rdata(rdata),.ui_data(ui_data),.motion_bg_reset(motion_bg_reset),.motion_mask_enable(motion_mask_enable),.motion_y_offset(motion_y_offset),.motion_dwell_limit(motion_dwell_limit),.cfg_send(cfg_send),.cfg_data(cfg_data),.result_send(result_send),.result_data(result_data),.gain_send(gain_send),.gain_data(gain_data));
final1_regs_before #(.READ_DECODE_REGISTERED(R)) reference_dut(.clk(clk),.rst_n(rst_n),.write(write),.write_word(write_word),.read_word(read_word),.wdata(wdata),.cfg_ready(cfg_ready),.cfg_done(cfg_done),.cfg_applied(cfg_applied),.faults(faults),.camera_diag_valid(camera_diag_valid),.camera_diag(camera_diag),.post_diag_valid(post_diag_valid),.post_diag(post_diag),.motion_valid(motion_valid),.motion_data(motion_data),.awb_valid(awb_valid),.awb_data(awb_data),.result_ready(result_ready),.gain_ready(gain_ready),.rdata(rdata_old),.ui_data(ui_data_old),.motion_bg_reset(motion_bg_reset_old),.motion_mask_enable(motion_mask_enable_old),.motion_y_offset(motion_y_offset_old),.motion_dwell_limit(motion_dwell_limit_old),.cfg_send(cfg_send_old),.cfg_data(cfg_data_old),.result_send(result_send_old),.result_data(result_data_old),.gain_send(gain_send_old),.gain_data(gain_data_old));
 task compare;
 begin
  if(rdata!==rdata_old) $fatal(1,"read mismatch R=%0d word=%h got=%h old=%h",R,read_word,rdata,rdata_old);
  if(dut.legal!==reference_dut.legal) $fatal(1,"cached legality mismatch R=%0d",R);
  if({13'd0,dut.accepted}!==reference_dut.accepted) $fatal(1,"generation mismatch");
  if({13'd0,dut.active_config}!==reference_dut.active_config) $fatal(1,"active config mismatch");
  if(ui_data!==ui_data_old) $fatal(1,"ui_data mismatch R=%0d",R);
  if(motion_bg_reset!==motion_bg_reset_old) $fatal(1,"motion_bg_reset mismatch R=%0d",R);
  if(motion_mask_enable!==motion_mask_enable_old) $fatal(1,"motion_mask_enable mismatch R=%0d",R);
  if(motion_y_offset!==motion_y_offset_old) $fatal(1,"motion_y_offset mismatch R=%0d",R);
  if(motion_dwell_limit!==motion_dwell_limit_old) $fatal(1,"motion_dwell_limit mismatch R=%0d",R);
  if(cfg_send!==cfg_send_old) $fatal(1,"cfg_send mismatch R=%0d",R);
  if(cfg_data!==cfg_data_old) $fatal(1,"cfg_data mismatch R=%0d",R);
  if(result_send!==result_send_old) $fatal(1,"result_send mismatch R=%0d",R);
  if(result_data!==result_data_old) $fatal(1,"result_data mismatch R=%0d",R);
  if(gain_send!==gain_send_old) $fatal(1,"gain_send mismatch R=%0d",R);
  if(gain_data!==gain_data_old) $fatal(1,"gain_data mismatch R=%0d",R);
 end
 endtask
 always @(posedge clk) begin #0.2;if(rst_n) compare();end
 always @(negedge clk) begin #0.2;if(rst_n) compare();end
endmodule
module tb_joint_regs;
 reg clk=0;
 reg rst_n=0;
 reg write=0;
 reg [8:0] write_word=0;
 reg [8:0] read_word=0;
 reg [31:0] wdata=0;
 reg cfg_ready=1;
 reg cfg_done=0;
 reg [31:0] cfg_applied=0;
 reg [7:0] faults=0;
 reg camera_diag_valid=0;
 reg [63:0] camera_diag=0;
 reg post_diag_valid=0;
 reg [127:0] post_diag=0;
 reg motion_valid=0;
 reg [223:0] motion_data=0;
 reg awb_valid=0;
 reg [255:0] awb_data=0;
 reg result_ready=1;
 reg gain_ready=1;
 reg test_passed=0;always #3.333 clk=~clk;
 joint_regs_pair #(.R(0)) p0(.clk(clk),.rst_n(rst_n),.write(write),.write_word(write_word),.read_word(read_word),.wdata(wdata),.cfg_ready(cfg_ready),.cfg_done(cfg_done),.cfg_applied(cfg_applied),.faults(faults),.camera_diag_valid(camera_diag_valid),.camera_diag(camera_diag),.post_diag_valid(post_diag_valid),.post_diag(post_diag),.motion_valid(motion_valid),.motion_data(motion_data),.awb_valid(awb_valid),.awb_data(awb_data),.result_ready(result_ready),.gain_ready(gain_ready));
 joint_regs_pair #(.R(1)) p1(.clk(clk),.rst_n(rst_n),.write(write),.write_word(write_word),.read_word(read_word),.wdata(wdata),.cfg_ready(cfg_ready),.cfg_done(cfg_done),.cfg_applied(cfg_applied),.faults(faults),.camera_diag_valid(camera_diag_valid),.camera_diag(camera_diag),.post_diag_valid(post_diag_valid),.post_diag(post_diag),.motion_valid(motion_valid),.motion_data(motion_data),.awb_valid(awb_valid),.awb_data(awb_data),.result_ready(result_ready),.gain_ready(gain_ready));

 integer i,j,n;reg [31:0] rnd=32'h2197a635;integer cfg_accepts=0;
 function [31:0] random_word(input [31:0] x);
  reg [31:0] y;begin y=x^(x<<13);y=y^(y>>17);random_word=y^(y<<5);end
 endfunction
 function [10:0] write_address(input integer k);
  case(k%22)
   0:write_address='h188;1:write_address='h18c;2:write_address='h1a8;3:write_address='h1ac;
   4:write_address='h1b0;5:write_address='h220;6:write_address='h280;7:write_address='h284;
   8:write_address='h288;9:write_address='h28c;10:write_address='h290;11:write_address='h294;
   12:write_address='h298;13:write_address='h29c;14:write_address='h420;15:write_address='h440;
   16:write_address='h444;17:write_address='h448;18:write_address='h44c;19:write_address='h450;
   20:write_address='h7fc;default:write_address='h1bc;
  endcase
 endfunction
 task step(input bit we,input [10:0] addr,input [31:0] value);
  begin @(negedge clk);write=we;write_word=addr[10:2];wdata=value;
   @(posedge clk);#0.5;end
 endtask
 task finish_config;
  begin cfg_applied={13'd0,p0.dut.accepted};cfg_done=1;step(0,0,0);cfg_done=0;end
 endtask
 task commit_ok(input [31:0] config_value,input [31:0] motion_value);
  reg [31:0] seq;begin
   finish_config();cfg_ready=1;
   step(1,'h188,config_value);step(1,'h1a8,motion_value);
   seq={13'd0,p0.dut.accepted}+1;
   step(1,'h18c,1);
   if(!p0.cfg_send || p0.cfg_data!=={seq,motion_value,config_value}) $fatal(1,"valid commit payload");
   cfg_accepts=cfg_accepts+1;
   step(1,'h18c,1);if(p0.cfg_send) $fatal(1,"busy commit accepted");
  end
 endtask
 task scan_reads;
  begin
   for(integer a=0;a<512;a=a+1) begin
    @(negedge clk);write=0;read_word=a;faults=a;
    @(posedge clk);#0.5;
    // Live status must NOT be sampled into the grouped address pipeline.
    faults=~a;#0.3;p0.compare();p1.compare();
   end
  end
 endtask
 initial begin
  repeat(4) @(negedge clk);rst_n=1;step(0,0,0);
  // Every diagnostic/snapshot word is distinct, so bank/index swaps are visible.
  camera_diag=64'h12345678_9abcdef0;
  post_diag=128'h10203040_50607080_90a0b0c0_d0e0f001;
  motion_data={32'h11223344,32'h55667788,32'h99aabbcc,32'hddeeff00,32'h13579bdf,32'h2468ace0,32'h98765432};
  awb_data={32'h01020304,32'h11121314,32'h21222324,32'h31323334,32'h41424344,32'h51525354,32'h61626364,32'h71727374};
  camera_diag_valid=1;post_diag_valid=1;motion_valid=1;awb_valid=1;step(0,0,0);
  camera_diag_valid=0;post_diag_valid=0;motion_valid=0;awb_valid=0;
  step(1,'h220,1);step(1,'h420,1);
  scan_reads();
  for(i=0;i<524288;i=i+1) step(1,'h188,i);
  $display("JOINT_CONFIG_FIELDS_PASS combinations=524288 modes=2");
  for(i=19;i<32;i=i+1) begin
   step(1,'h188,(32'd1<<i)|32'd131072);step(1,'h18c,1);
   if(p0.cfg_send || !p0.dut.rejected) $fatal(1,"reserved config accepted");
  end
  step(1,'h188,131072);
  for(i=0;i<8;i=i+1) for(j=0;j<64;j=j+1) step(1,'h1a8,20|(i<<8)|(j<<11)|(10<<17));
  for(i=22;i<32;i=i+1) begin
   step(1,'h1a8,(32'd1<<i)|32'd1313556);step(1,'h18c,1);
   if(p0.cfg_send) $fatal(1,"reserved motion accepted");
  end
  commit_ok(131072,1313556);commit_ok(131073,1313556);commit_ok(131328,1313556);
  for(i=0;i<18;i=i+1) commit_ok((224<<9)|2|((i%3)<<6)|(((i/3)%4)<<4)|(((i/3)>>2)<<18),4194303);
  // The bit18 reaches commit payload and active readback unchanged.
  finish_config();
  if(!p0.dut.active_config[18]) $fatal(1,"NEG active high bit lost");
  for(i=2;i<4;i=i+1) begin
   step(1,'h188,(1<<18)|(224<<9)|2|(i<<4));step(1,'h18c,1);
   if(p0.cfg_send || !p0.dut.rejected) $fatal(1,"FX6..7 accepted");
  end
  for(i=0;i<2;i=i+1) begin
   step(1,'h188,(1<<18)|(256<<9)|i);step(1,'h18c,1);
   if(p0.cfg_send || !p0.dut.rejected) $fatal(1,"NEG leaked to normal modes");
  end
  // Full invalid shadow readback remains observable, including write-only holes.
  step(1,'h188,32'hffffffff);step(1,'h1a8,32'hffffffff);step(1,'h1b0,32'hdeadbeef);
  scan_reads();
  step(1,'h188,131072);step(1,'h1a8,1313556);finish_config();
  // Seed a reachable near-saturation state; all following transitions are real writes.
  @(negedge clk);write=0;
  p0.dut.accepted=19'h7fffd;p1.dut.accepted=19'h7fffd;
  p0.reference_dut.accepted=32'h7fffd;p1.reference_dut.accepted=32'h7fffd;
  commit_ok(131072,1313556);commit_ok(131072,1313556);finish_config();
  step(1,'h18c,1);
  if(p0.cfg_send || p0.dut.accepted!=19'h7ffff) $fatal(1,"generation saturated incorrectly");
  scan_reads();
  #0.7;rst_n=0;#0.5;p0.compare();p1.compare();
  repeat(3) @(negedge clk);rst_n=1;
  for(i=0;i<30000;i=i+1) begin
   @(negedge clk);rnd=random_word(rnd);write=rnd[0];write_word=write_address(rnd[9:2])>>2;
   wdata=(i%4==0)?32'd1:((i%4==1)?32'd2:rnd);read_word=rnd[18:10];
   cfg_ready=rnd[19];cfg_done=rnd[20];cfg_applied=rnd;faults=rnd[7:0];
   camera_diag_valid=rnd[21];camera_diag={rnd,~rnd};post_diag_valid=rnd[22];post_diag={rnd,~rnd,rnd+32'd1,rnd^32'h55555555};
   motion_valid=rnd[23];motion_data={rnd,~rnd,rnd+32'd1,rnd-32'd1,rnd^32'h55555555,32'h13579bdf,32'h02468ace};
   awb_valid=rnd[24];awb_data={rnd,~rnd,rnd+32'd1,rnd-32'd1,rnd^32'haaaaaaaa,32'h12345678,32'h90abcdef,rnd^32'h55555555};
   result_ready=rnd[25];gain_ready=rnd[26];
   if(i%997==0) begin #0.7;rst_n=0;#0.5;p0.compare();p1.compare();rst_n=1;end
   @(posedge clk);#0.5;
  end
  cfg_done=0;camera_diag_valid=0;post_diag_valid=0;motion_valid=0;awb_valid=0;
  scan_reads();step(0,0,0);
  test_passed=1;
  $display("JOINT_REGS_EQUIVALENCE_PASS config_cases=524288 random_cycles=30000 address_sweeps=4 accepted_checks=%0d",cfg_accepts);
  $finish;
 end
 initial begin #10000000;$fatal(1,"joint regs watchdog");end
endmodule
