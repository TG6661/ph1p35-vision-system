`timescale 1ns/1ps
// Real two-pixel replay + production post. Source publications are fixed 60Hz.
// Ordered DDR latency/stalls are a contract, not a PHY or complete arbiter model.
module tb_round2_performance #(parameter W=1280,H=720,FRAMES=4,LATENCY=8,STALLS=0,FX=0,CL=0,CHECK_REFERENCE=1,FAST_DSP_MODEL=0,EXPECT_SKIPS=0,
 parameter real FRAME_NS=1000000000.0/60.0);
 localparam WORDS=W*H*3/16;
 reg clk=0,rst=0,published=0,enable=1;
 always #7.5 clk=~clk;
 reg [31:0] seq=0;
 reg [1:0] bank=0;
 reg [50:0] tag=0;
 wire [1:0] locked_bank;
 wire [50:0] active_tag;
 wire idle,start,rd,rvout,ru,rl,error;
 wire [24:0] address;
 wire [47:0] rgb;
 wire [127:0] post_data,ref_data;
 wire pv,pu,pl,ref_v,ref_u,ref_l,cl_error;
 reg post_done=0,rd_valid=0;
 reg [127:0] rd_data=0;
 integer tick=0,head=0,tail=0,peak=0,words=0,completed=0,started=0;
 integer bank_id[0:3];
 reg [127:0] response[0:63];
 integer due[0:63];
 integer offered=0,window_complete=0,last_started=0,skipped=0;
 real origin,first_done=-1.0,last_done=-1.0,start_time;
 integer checks=0,replay_pixels=0;
 reg test_passed=0;
 wire ready=!STALLS || (tick%29<23 && tick%127<119);
 final1_line_replay #(.WIDTH(W),.HEIGHT(H),.PIXELS(2)) replay(
  .clk(clk),.rst_n(rst),.enable(enable),.frame_valid(published),.frame_sequence(seq),
  .bank(bank),.tag(tag),.generation(19'd0),.sink_frame_ready(1'b1),.post_done(post_done),
  .locked_bank(locked_bank),.frame_start(start),.active_tag(active_tag),.idle(idle),
  .rd_en(rd),.address(address),.bus_ready(ready),.rd_valid(rd_valid),.rd_data(rd_data),
  .rgb(rgb),.valid(rvout),.user(ru),.last(rl),.error(error));
 final1_post #(.PIXELS(2),.IMG_WIDTH(W),.IMG_HEIGHT(H),.RGB_INPUT_ENABLE(1),
  .PIX_FIXED_LINE_PERIOD(1024),.GREEN_GAIN_ENABLE(1),.MCU_AWB_ENABLE(1)) post(
  .axi4s_video_aclk(clk),.I_rst_n(rst),.I_style_enable(FX!=0 || CL!=0),
  .I_tdata(40'd0),.I_tvalid(1'b0),.I_tuser(1'b0),.I_tlast(1'b0),.I_tdest(10'd0),
  .I_rgb_data(rgb),.I_rgb_valid(rvout),.I_rgb_user(ru),.I_rgb_last(rl),
  .I_mode(3'(FX)),.I_color_select(2'(CL)),.I_green_gain(9'd224),
  .O_tready(1'b1),.I_tready(),.O_tdata(post_data),.O_tvalid(pv),.O_tuser(pu),.O_tlast(pl),
  .O_frame_config(),.O_cl_overflow(cl_error),.I_awb_mcu_ready(1'b0),
  .O_awb_stats_request(),.O_awb_stats_payload(),.I_awb_gain_request(1'b0),
  .I_awb_gain_payload(72'd0),.O_awb_gain_ack());
 generate if(CHECK_REFERENCE) begin:g_reference
 final1_post_round2_before #(.PIXELS(2),.IMG_WIDTH(W),.IMG_HEIGHT(H),.RGB_INPUT_ENABLE(1),
  .PIX_FIXED_LINE_PERIOD(1024),.GREEN_GAIN_ENABLE(1),.MCU_AWB_ENABLE(1)) reference_post(
  .axi4s_video_aclk(clk),.I_rst_n(rst),.I_style_enable(FX!=0 || CL!=0),
  .I_tdata(40'd0),.I_tvalid(1'b0),.I_tuser(1'b0),.I_tlast(1'b0),.I_tdest(10'd0),
  .I_rgb_data(rgb),.I_rgb_valid(rvout),.I_rgb_user(ru),.I_rgb_last(rl),
  .I_mode(3'(FX)),.I_color_select(2'(CL)),.I_green_gain(9'd224),
  .O_tready(1'b1),.I_tready(),.O_tdata(ref_data),.O_tvalid(ref_v),.O_tuser(ref_u),.O_tlast(ref_l),
  .O_frame_config(),.O_cl_overflow(),.I_awb_mcu_ready(1'b0),
  .O_awb_stats_request(),.O_awb_stats_payload(),.I_awb_gain_request(1'b0),
  .I_awb_gain_payload(72'd0),.O_awb_gain_ack());
 end else begin:g_no_reference
  assign ref_data=post_data;assign ref_v=pv;assign ref_u=pu;assign ref_l=pl;
 end endgenerate
 function integer bank_index(input [24:0] a);bank_index=a/7000000;endfunction
 function [23:0] pixel(input integer id,pos);
  pixel={8'(id*29+pos/W),8'(pos%W),8'(pos/W+pos)};
 endfunction
 function [127:0] memory_word(input integer id,n);
  reg [143:0] pixels;
  integer first;
  begin
   first=(n*16)/3;
   for(integer j=0;j<6;j++) pixels[143-j*24-:24]=pixel(id,first+j);
   case(n%3)
    0:memory_word=pixels[143:16];
    1:memory_word=pixels[135:8];
    2:memory_word=pixels[127:0];
   endcase
  end
 endfunction
 always @(negedge clk) if(rst) tick=tick+1;
 always @(posedge clk) if(rst) begin
  rd_valid<=0;post_done<=0;
  if(rd) begin
   if(!ready || tail-head>=63) $fatal(1,"Memory contract overflow");
   response[tail%64]=memory_word(bank_id[bank_index(address)],(address%3500000)/8);
   due[tail%64]=tick+LATENCY;tail++;
  end
  if(tail-head>peak) peak=tail-head;
  if(head<tail && tick>=due[head%64] && (!STALLS || tick%11!=0)) begin
   rd_valid<=1;rd_data<=response[head%64];head++;
  end
  if(error || cl_error) $fatal(1,"Replay/post protocol error");
  if(start) begin
   started++;skipped+=active_tag[31:0]-last_started-1;last_started=active_tag[31:0];
   start_time=$realtime;replay_pixels=0;
  end
  if(rvout) begin
   if(rgb!=={pixel(active_tag[31:0],replay_pixels),pixel(active_tag[31:0],replay_pixels+1)} ||
      ru!==(replay_pixels==0) || rl!==((replay_pixels%W)==W-2))
    $fatal(1,"Replay pixel/flag mismatch at pixel %0d",replay_pixels);
   replay_pixels+=2;
  end
  if(pv) begin
   if((^post_data)===1'bx) $fatal(1,"Unknown post data");
   if(pu!==(words==0) || pl!==((words%(W*3/16))==(W*3/16)-1))
    $fatal(1,"Post frame/line flag mismatch at word %0d",words);
   if(words==WORDS-1) begin
    if(replay_pixels!=W*H) $fatal(1,"Incomplete replay frame");
    words=0;post_done<=1;completed++;
    if(first_done<0) first_done=$realtime;
    last_done=$realtime;
    $display("PERF_FRAME source=%0d completed=%0d processing_ns=%0.3f time_ns=%0.3f",active_tag[31:0],completed,$realtime-start_time,$realtime);
   end else words++;
  end
  if(CHECK_REFERENCE) begin
   #1;
   if({pv,pu,pl}!=={ref_v,ref_u,ref_l} || (pv && post_data!==ref_data))
    $fatal(1,"Post cycle equivalence at realistic cadence");
  end
  if(pv) checks++;
 end
 initial begin
  for(integer i=0;i<4;i++) bank_id[i]=0;
  repeat(8) @(negedge clk);rst=1;
  repeat(8) @(negedge clk);origin=$realtime;
  for(integer f=0;f<FRAMES;f++) begin
   if($realtime<origin+f*FRAME_NS) #(origin+f*FRAME_NS-$realtime);
   @(negedge clk);
   // Never overwrite the current replay's bank. Publication never waits.
   bank=(bank+1)%4;
   if(!idle && bank==locked_bank) bank=(bank+1)%4;
   bank_id[bank]=f+1;seq=f+1;tag={19'd0,32'(f+1)};published=1;offered++;
   $display("PERF_SOURCE offered=%0d time_ns=%0.3f busy=%0d",offered,$realtime,!idle);
  end
  if($realtime<origin+FRAMES*FRAME_NS) #(origin+FRAMES*FRAME_NS-$realtime);
  @(negedge clk);enable=0;window_complete=completed;
  $display("PERF_WINDOW offered=%0d started=%0d completed=%0d skipped_before_start=%0d duration_ns=%0.3f",offered,started,completed,skipped,$realtime-origin);
  begin: drain
   repeat(6000000) begin
    @(negedge clk);
    if(idle && head==tail && !rd_valid) disable drain;
   end
   $fatal(1,"Performance drain timeout");
  end
  if(completed==0 || completed!=started || words!=0 || checks==0) $fatal(1,"Incomplete performance exercise");
  if(EXPECT_SKIPS && skipped==0) $fatal(1,"Overload fixture did not exercise a skipped source frame");
  $display("ROUND2_PERFORMANCE_RESULT W=%0d H=%0d latency=%0d stalls=%0d FX=%0d CL=%0d reference=%0d fast_dsp=%0d source_period_ns=%0.3f offered=%0d window_complete=%0d final_complete=%0d not_started=%0d peak_reads=%0d observed_completion_fps=%0.3f all_offered_completed=%0d",W,H,LATENCY,STALLS,FX,CL,CHECK_REFERENCE,FAST_DSP_MODEL,FRAME_NS,offered,window_complete,completed,offered-started,peak,(completed>1)?(completed-1)*1000000000.0/(last_done-first_done):0.0,completed==offered);
  test_passed=1;$display("ROUND2_PERFORMANCE_CORRECTNESS_PASS words=%0d",checks);$finish;
 end
 initial begin #300000000;$fatal(1,"Performance watchdog");end
endmodule
