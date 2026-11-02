`timescale 1ns/1ps
// Whole-post pixel/marker equivalence in normal modes; frame-atomic FX/CL tags
// across every STYLE combination, including a request change inside each frame.
module tb_post_contract;
localparam W=1280,H=32,WORDS=W*H*3/16;
reg clk=0,rst=0,v=0,u=0,l=0,style=0;
reg [47:0] rgb=0;
reg [2:0] fx=0;reg [1:0] cl=0;
wire [127:0] data,old_data;
wire valid,user,last,old_valid,old_user,old_last,overflow;
wire [4:0] tag;wire [3:0] old_tag;
reg [129:0] got[0:WORDS-1],expected[0:WORDS-1];
integer n=0,old_n=0,frames=0,checks=0;
reg [4:0] expected_tag=0;
reg test_passed=0;
always #7.5 clk=~clk;
final1_post #(.PIXELS(2),.IMG_WIDTH(W),.IMG_HEIGHT(H),.RGB_INPUT_ENABLE(1),
 .PIX_FIXED_LINE_PERIOD(1024),.GREEN_GAIN_ENABLE(1),.MCU_AWB_ENABLE(1)) dut(
 .axi4s_video_aclk(clk),.I_rst_n(rst),.I_style_enable(style),
 .I_tdata(40'd0),.I_tvalid(1'b0),.I_tuser(1'b0),.I_tlast(1'b0),.I_tdest(10'd0),
 .I_rgb_data(rgb),.I_rgb_valid(v),.I_rgb_user(u),.I_rgb_last(l),
 .I_mode(fx),.I_color_select(cl),.I_green_gain(style?9'd224:9'd256),
 .O_tready(1'b1),.I_tready(),.O_tdata(data),.O_tvalid(valid),.O_tuser(user),.O_tlast(last),
 .O_frame_config(tag),.O_cl_overflow(overflow),.I_awb_mcu_ready(1'b0),
 .O_awb_stats_request(),.O_awb_stats_payload(),.I_awb_gain_request(1'b0),
 .I_awb_gain_payload(72'd0),.O_awb_gain_ack());
before_final1_post #(.PIXELS(2),.IMG_WIDTH(W),.IMG_HEIGHT(H),.RGB_INPUT_ENABLE(1),
 .PIX_FIXED_LINE_PERIOD(1024),.GREEN_GAIN_ENABLE(1),.MCU_AWB_ENABLE(1)) reference_dut(
 .axi4s_video_aclk(clk),.I_rst_n(rst),.I_style_enable(style),
 .I_tdata(40'd0),.I_tvalid(1'b0),.I_tuser(1'b0),.I_tlast(1'b0),.I_tdest(10'd0),
 .I_rgb_data(rgb),.I_rgb_valid(v),.I_rgb_user(u),.I_rgb_last(l),
 .I_mode(fx<4?fx[1:0]:2'd0),.I_color_select(cl),.I_green_gain(style?9'd224:9'd256),
 .O_tready(1'b1),.I_tready(),.O_tdata(old_data),.O_tvalid(old_valid),.O_tuser(old_user),.O_tlast(old_last),
 .O_frame_config(old_tag),.O_cl_overflow(),.I_awb_mcu_ready(1'b0),
 .O_awb_stats_request(),.O_awb_stats_payload(),.I_awb_gain_request(1'b0),
 .I_awb_gain_payload(72'd0),.O_awb_gain_ack());
always @(posedge clk) begin
 #1;
 if(rst) begin
  if({dut.O_awb_stats_request,dut.O_awb_stats_payload}!=={reference_dut.O_awb_stats_request,reference_dut.O_awb_stats_payload})
   $fatal(1,"NEG affected linear metering");
  if(expected_tag[4:2]<4 && ({valid,user,last}!=={old_valid,old_user,old_last} || (valid && (data!==old_data || tag!=={1'b0,old_tag}))))
   $fatal(1,"Existing FX cycle equivalence");
  if(overflow) $fatal(1,"CL overflow");
  if(valid) begin
   if(n>=WORDS || (^data)===1'bx || tag!==expected_tag || user!==(n==0) || last!==((n%(W*3/16))==W*3/16-1))
    $fatal(1,"Post flags/tag/data frame=%0d word=%0d tag=%h expected=%h",frames,n,tag,expected_tag);
   got[n]={user,last,data};n++;
  end
  if(old_valid && expected_tag[4:2]!=4) begin
   if(old_n>=WORDS) $fatal(1,"Old post overrun");
   expected[old_n]={old_user,old_last,old_data};old_n++;
  end
 end
end
 function automatic [23:0] scalar(input [23:0] rgb,input [1:0] sel);
  integer r,g,b,y,t,c,adj,boost;reg keep;reg [23:0] o;
  begin
   r=rgb[23:16];g=rgb[15:8];b=rgb[7:0];y=r/4+g/2+b/4;
   t=y/8;if(t<6)t=6;if(t>14)t=14;
   keep=(sel==0)?(b>r+16||g>r+16):((sel==1)?(r>b+t&&r+g>2*b):1);
   for(integer k=0;k<3;k=k+1)begin
    c=(rgb>>(k*8))&255;
    if(sel>=2)boost=c;
    else if(!keep)boost=y;
    else begin
     adj=c+((c-y)>>>3);if(adj<0)adj=0;if(adj>255)adj=255;
     boost=adj+adj/8;if(boost>255)boost=255;
    end
    o[k*8+:8]=boost;
   end
   scalar=o;
  end
 endfunction

integer neg_bytes=0,negative_checks=0;
reg [127:0] negative_words[0:WORDS-1];
reg [23:0] neg_rgb;
reg [1:0] neg_sel;
always @(posedge clk) if(rst && expected_tag[4:2]==4 && dut.style_tvalid) begin
 if({dut.edge_O_tvalid,dut.edge_O_tuser,dut.edge_O_tlast}!=={dut.style_tvalid,dut.style_tuser,dut.style_tlast})
  $fatal(1,"NEG added timing latency");
 neg_sel=expected_tag[1:0]==1?0:(expected_tag[1:0]==2?1:3);
 for(integer lane=0;lane<2;lane++) begin
  for(integer ch=0;ch<3;ch++)
   neg_rgb[ch*8+:8]=255-dut.style_tdata[47-lane*24-16+ch*8-:8];
  // Explicit per-channel subtraction above, then standalone CL model.
  if(dut.edge_O_tdata[47-lane*24-:24]!==neg_rgb) $fatal(1,"NEG channel mismatch");
  neg_rgb=scalar(neg_rgb,neg_sel);
  for(integer byte_idx=2;byte_idx>=0;byte_idx--) begin
   negative_words[neg_bytes/16][127-8*(neg_bytes%16)-:8]=neg_rgb[byte_idx*8+:8];
   neg_bytes++;
  end
 end
end

function [23:0] pixel(input integer x,y,f);
 pixel={8'(x*7+y*11+f*23),8'(x*13+y*17+f*29),8'(x*19+y*3+f*41)};
endfunction
task frame(input bit sty,input integer f,input integer c,input bit early);
 begin
  @(negedge clk);style=sty;fx=f;cl=c;expected_tag={(f<5?3'(f):3'd0),2'(c)};n=0;old_n=0;neg_bytes=0;
  repeat(40) @(negedge clk);
  if(early) begin u=1;@(negedge clk);u=0;repeat(3) @(negedge clk);end
  for(integer y=0;y<H;y++) begin
   for(integer x=0;x<W;x+=2) begin
    v=1;u=!early&&x==0&&y==0;l=x==W-2;rgb={pixel(x,y,frames),pixel(x+1,y,frames)};
    // Requests may change after frame start; the current output keeps its tag.
    if(sty&&y==8&&x==16) begin fx=(f+1)%5;cl=(c+1)%3;end
    @(negedge clk);
   end
   v=0;u=0;l=0;repeat(384) @(negedge clk);
  end
  // PIX buffers eight rows; allow its complete final stripe to drain.
  repeat(12000) @(negedge clk);
  if(n!=WORDS) $fatal(1,"Incomplete output frame %0d got %0d",frames,n);
  if(f!=4) begin
   if(old_n!=WORDS) $fatal(1,"Incomplete reference");
   for(integer k=0;k<WORDS;k++) begin
    if(got[k]!==expected[k]) $fatal(1,"Existing FX changed word %0d",k);
    checks++;
   end
  end
  if(f==4) begin
   if(neg_bytes!=W*H*3) $fatal(1,"NEG golden incomplete");
   for(integer k=0;k<WORDS;k++) begin
    if(got[k][127:0]!==negative_words[k]) $fatal(1,"NEG+CL packed mismatch frame=%0d word=%0d",frames,k);
    negative_checks++;
   end
  end
  frames++;
 end
endtask
initial begin
 repeat(8) @(negedge clk);rst=1;
 frame(0,0,0,0);frame(0,0,0,1);
 for(integer f=0;f<5;f++) for(integer c=0;c<3;c++) frame(1,f,c,c%2);
 // Occupied reset followed by full-frame recovery.
 v=1;u=1;rgb=48'h123456abcdef;repeat(5) @(negedge clk);rst=0;v=0;u=0;
 repeat(5) @(negedge clk);rst=1;
 frame(1,4,1,1);frame(1,2,2,0);frame(1,4,2,0);
 frame(1,1,1,1);frame(1,4,0,0);frame(1,3,0,0);frame(0,0,0,0);
 // Direct module invalid request must fall back to RGB; AHB rejects these.
 frame(1,6,0,0);frame(1,6,1,0);frame(1,7,2,0);
 test_passed=1;$display("POST_CONTRACT_PASS frames=%0d old_equal_words=%0d negative_golden_words=%0d all_15_FX_CL_tags_midframe_request_reset",frames,checks,negative_checks);$finish;
end
initial begin #60000000;$fatal(1,"Post contract watchdog");end
endmodule
