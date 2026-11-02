`timescale 1ns/1ps
module tb_final1_runtime #(parameter FINAL_SINK=0,SMOKE=0);
 localparam W=1280,H=32,WORDS=W*H*3/16;
 reg test_passed=0;
 reg cam=0,ddr=0,ahb=0,pix=0,rst=0;
 always #8 cam=~cam;always #7.5 ddr=~ddr;always #3.333 ahb=~ahb;always #6.666 pix=~pix;
 reg [39:0] raw=0;reg rv=0,ru=0,rl=0;
 reg ew=0;reg [8:0] ewa=0,era=0;reg [31:0] ewd=0;wire [31:0] erd;
 wire lb,lw,lr;wire [24:0] la,lra;wire [127:0] ld;
 reg lret=0;reg [127:0] ldata=0;
 wire ps,pv;wire [127:0] pd;wire [50:0] pt;wire [18:0] gen;wire [1:0] mode;
 wire [7:0] fault;reg vs=0;
 reg [127:0] mem[0:4*WORDS-1];
 integer post_frames=0,words=0,frame_ticks=0,raw_frames=0;
 reg [31:0] last_post_gen=32'hffffffff;
 reg expected_sf=1;
 integer sf_red_frames=0,sf_motion_frames=0,sf_style_frames=0;
 wire sink_ready;
 wire [50:0] sink_tag;
 wire [1:0] sink_mode;
 wire sink_valid,sink_error;
 generate if(FINAL_SINK) begin:g_final_sink
  video_in #(.WIDTH(W),.HEIGHT(H),.ELASTIC(0)) sink(
   .I_rst_n(rst),.I_camera_clk(ddr),.I_ddr_clk(ddr),
   .I_frame_tag(pt),.I_diagnostics(92'd0),.O_frame_tag(sink_tag),.O_diagnostics(),.O_frame_sequence(),
   .I_camera_frame_start(ps),.I_camera_valid(pv),.I_camera_data(pd),.I_camera_mode(mode),
   .I_camera_abort(1'b0),.I_mipi_rx_error(1'b0),.I_display_pause(1'b0),.I_video_out_rd_busy(1'b0),
   .I_read_bank(2'd0),.O_camera_ready(),.O_frame_ready(sink_ready),.O_video_in_wr_busy(),
   .O_video_out_rp(),.O_frame_mode(sink_mode),.O_frame_valid(sink_valid),.O_capture_error(sink_error),
   .O_ddr_user_wr_en(),.O_ddr_user_addr(),.O_ddr_user_wr_data(),.I_ddr_user_ready(1'b1));
 end else begin:g_no_final_sink
  assign sink_ready=1;assign sink_tag=pt;assign sink_mode=mode;assign sink_valid=1;assign sink_error=0;
 end endgenerate
 final1_runtime #(.WIDTH(W),.HEIGHT(H)) dut(
  .camera_clk(cam),.ddr_clk(ddr),.ahb_clk(ahb),.pixel_clk(pix),.rst_n(rst),
  .raw_data(raw),.raw_valid(rv),.raw_user(ru),.raw_last(rl),
  .blc_enable(1'b1),.blc_offset(8'd32),
  .ext_write(ew),.ext_write_word(ewa),.ext_read_word(era),.ext_wdata(ewd),.ext_rdata(erd),
  .red_capture_ready(1'b1),.red_replay_idle(1'b1),.red_detector_ready(1'b1),
  .red_camera_enable(),.red_replay_enable(),.camera_tag(),.generation(gen),.active_mode(mode),
  .final_frame_ready(sink_ready),.post_start(ps),.post_data(pd),.post_valid(pv),.post_tag(pt),
  .linear_busy(lb),.linear_wr(lw),.linear_addr(la),.linear_data(ld),.linear_ready(1'b1),
  .linear_rd(lr),.linear_rd_addr(lra),.linear_rd_ready(1'b1),.linear_rd_valid(lret),.rd_data(ldata),
  .external_faults(8'd0),.faults(fault),.pixel_vs(vs),.red_display_frame(32'd0),
  .show_red(),.show_motion(),.motion_boxes(),.motion_box_valid(),.pixel_mode(),.pixel_running(),.pixel_ui(),
  .motion_mask_rd_addr(15'd0),.motion_mask_rd_data(),.motion_mask_wr_buf(),.motion_mask_enable(),.motion_y_offset());
 function integer addr_index(input [24:0] a);
  integer b,off;begin
   b=(a-3500000)/7000000;off=(a-(3500000+b*7000000))/8;
   if(a<3500000 || b>3 || off<0 || off>=WORDS || a[2:0]!=0) $fatal(1,"DDR address %d",a);
   addr_index=b*WORDS+off;
  end
 endfunction
 // Check the applied camera-domain mode at RAW SOF, including the first frame
 // after each mailbox transition and both early/coincident SOF conventions.
 always @(posedge cam) if(dut.camera_rst_n) begin
  if(ru) expected_sf=(dut.config_now[1:0]==0);
  if(dut.u_front.sf_input_user) begin
   if(dut.u_front.u_sf.I_mode!==(expected_sf ? 2'd3 : 2'd0)) $fatal(1,"SF mode not applied at frame boundary");
   case(dut.camera_config[1:0])
    0:sf_red_frames=sf_red_frames+1;
    1:sf_motion_frames=sf_motion_frames+1;
    2:sf_style_frames=sf_style_frames+1;
   endcase
  end
 end
 always @(posedge ddr) begin
  lret<=lr;
  if(lw) mem[addr_index(la)]<=ld;
  if(lr) ldata<=mem[addr_index(lra)];
  if(ps) begin if(words!=0) $fatal(1,"new post before previous completion");end
  if(pv) begin
   if(^pd===1'bx) $fatal(1,"unknown output pixel generation %0d word %0d",gen,words);
   if(words==WORDS-1) begin words=0;post_frames=post_frames+1;last_post_gen=pt[50:32];end
   else words=words+1;
  end
  if(rst && fault!=0) $fatal(1,"runtime fault %h",fault);
  if(rst && sink_error) $fatal(1,"final display writer rejected post frame");
 end
 always @(posedge pix) begin
  frame_ticks<=frame_ticks==9999?0:frame_ticks+1;
  vs<=frame_ticks<20;
 end
 task write_reg(input integer a,input [31:0] d);
  begin @(negedge ahb);ewa=a>>2;ewd=d;ew=1;@(negedge ahb);ew=0;end
 endtask
 task change(input integer newmode,input integer fx,input integer cl);
  integer wanted;begin
   wanted=gen+1;
   write_reg('h188,((newmode==2?224:256)<<9)|(newmode==2?256:0)|((fx&3)<<4)|((fx&4)<<16)|(cl<<6)|newmode);
   write_reg('h18c,1);
   wait(dut.u_regs.applied==wanted);
   wait(last_post_gen==wanted);
   if(FINAL_SINK) begin
    wait(sink_valid && sink_tag[50:32]==wanted);
    if(sink_mode!=newmode) $fatal(1,"final display publication mode mismatch");
   end
   if(dut.config_active[18]!==((fx>>2)&1) || dut.u_regs.active_config[18]!==((fx>>2)&1) ||
      dut.u_post.I_mode!==fx) $fatal(1,"NEG config lost across commit/CDC");
   if(mode!=newmode) $fatal(1,"mode mismatch");
   // Applied HUD mode must converge with the independent pixel profile.
   // Cover the reported MOTION -> STYLE path, not just the DDR config.
   repeat(2) @(negedge vs);
   if(dut.pixel_mode!==newmode || dut.pixel_running!==1'b1)
    $fatal(1,"pixel profile stuck: mode=%0d pixel=%0d run=%b",newmode,dut.pixel_mode,dut.pixel_running);
   if(newmode!=1 && (dut.show_motion!==1'b0 || dut.motion_box_valid!==0))
    $fatal(1,"motion boxes survived non-MOTION mode");
   if(newmode!=2 && dut.camera_config[7:2]!=0) $fatal(1,"style profile leaked");
   $display("MODE_PASS generation=%0d mode=%0d fx=%0d",wanted,newmode,fx);
  end
 endtask
 initial begin
  #100;rst=1;
  forever begin
   @(negedge cam);ru=!raw_frames[0];rv=0;rl=0;
   @(negedge cam);ru=0;
   repeat(100) @(negedge cam);
   for(integer y=0;y<H;y=y+1) begin
    for(integer x=0;x<W/4;x=x+1) begin
     rv=1;ru=raw_frames[0] && y==0 && x==0;rl=x==W/4-1;raw={4{10'd400}};
     if(raw_frames[0] && x>=80 && x<96 && y>=8 && y<24) raw={4{10'd800}};
     @(negedge cam);
    end
    rv=0;ru=0;rl=0;repeat(704) @(negedge cam);
   end
   raw_frames=raw_frames+1;repeat(4096) @(negedge cam);
  end
 end
 initial begin
  wait(post_frames>=1);
  change(1,0,0); // RED -> MOTION
  repeat(100000) @(posedge cam);
  if(dut.u_regs.motion_seq==0) $fatal(1,"motion snapshot missing");
  change(2,0,0); // MOTION -> STYLE
  if(SMOKE) begin
   change(2,4,0); // Frozen-display report: visible NEG frame must publish.
   change(2,5,0); // Delayed ASCII output must also complete the final writer.
   change(1,0,0);
   test_passed=1;$display("FINAL_SINK_SWITCH_PASS frames=%0d",post_frames);$finish;
  end
  change(0,0,0); // STYLE -> RED
  change(2,1,1); // RED -> STYLE, CRT
  change(2,2,2); // PIX and tail drain
  change(2,5,0); // PIX -> ASCII, delayed tail drain
  change(2,4,0); // ASCII -> NEG, RGB timing after delayed tail
  change(2,4,1); // NEG+CLD
  change(2,4,2); // NEG+WRM
  change(2,0,0); // NEG -> RGB
  change(2,4,0); // RGB -> NEG
  change(2,3,0); // HAT
  change(2,5,2); // ASCII WRM
  change(1,0,0); // ASCII -> MOTION
  change(0,0,0); // MOTION -> RED
  if(sf_red_frames==0 || sf_motion_frames==0 || sf_style_frames==0) $fatal(1,"SF mode coverage incomplete");
  test_passed=1;$display("FINAL1_RUNTIME_PASS frames=%0d SF_RED=%0d BYPASS_MOTION=%0d BYPASS_STYLE=%0d",post_frames,sf_red_frames,sf_motion_frames,sf_style_frames);$finish;
 end
 initial begin #100000000;$fatal(1,"timeout state=%0d capready=%b replayidle=%b frames=%0d words=%0d",dut.state,dut.capture_ready,dut.replay_idle,post_frames,words);end
endmodule
