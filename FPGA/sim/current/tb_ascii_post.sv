`timescale 1ns/1ps
// End-to-end FX5 selection and frame-atomic switching through final1_post.
module tb_ascii_post;
 localparam integer W=1280,H=32,BEATS=W/2,WORDS=W*H*3/16;
 reg clk=0,rst=0,v=0,u=0,l=0,style=1;
 reg [47:0] rgb=0;
 reg [2:0] fx=0;
 reg [1:0] cl=0;
 wire [127:0] data;
 wire valid,user,last;
 wire [4:0] tag;
 integer frames=0,frames_done=0,words=0,errors=0;
 reg [4:0] current_tag=0;
 reg [4:0] seen_tag[0:7];
 integer seen_words[0:7];
 reg test_passed=0;
 always #7.5 clk=~clk;
 final1_post #(.PIXELS(2),.IMG_WIDTH(W),.IMG_HEIGHT(H),.RGB_INPUT_ENABLE(1),
  .PIX_FIXED_LINE_PERIOD(1024),.GREEN_GAIN_ENABLE(1),.MCU_AWB_ENABLE(1)) dut(
  .axi4s_video_aclk(clk),.I_rst_n(rst),.I_style_enable(style),
  .I_tdata(40'd0),.I_tvalid(1'b0),.I_tuser(1'b0),.I_tlast(1'b0),.I_tdest(10'd0),
  .I_rgb_data(rgb),.I_rgb_valid(v),.I_rgb_user(u),.I_rgb_last(l),
  .I_mode(fx),.I_color_select(cl),.I_green_gain(9'd224),
  .O_tready(1'b1),.I_tready(),.O_tdata(data),.O_tvalid(valid),.O_tuser(user),.O_tlast(last),
  .O_frame_config(tag),.O_cl_overflow(),.I_awb_mcu_ready(1'b0),
  .O_awb_stats_request(),.O_awb_stats_payload(),.I_awb_gain_request(1'b0),
  .I_awb_gain_payload(72'd0),.O_awb_gain_ack());

 function [23:0] pixel(input integer x,y,f);
  pixel={8'(x*7+y*11+f*23),8'(x*13+y*17+f*29),8'(x*19+y*3+f*41)};
 endfunction

 always @(posedge clk) begin
  if(rst && dut.edge_O_tvalid && dut.output_mode==3'd5 && dut.edge_O_tdata!==dut.ascii_out_tdata) begin
   if(errors<10) $display("FAIL FX5 mux did not select ascii branch got=%012h ascii=%012h",dut.edge_O_tdata,dut.ascii_out_tdata);
   errors=errors+1;
  end
  if(valid) begin
   if(^data===1'bx)$fatal(1,"Unknown ASCII/post pixel");
   if(user) begin
    if(frames_done>0 && seen_words[frames_done-1]!==WORDS) begin
     $display("FAIL frame %0d words=%0d want=%0d",frames_done-1,seen_words[frames_done-1],WORDS);errors=errors+1;
    end
    if(frames_done<8) begin
     seen_tag[frames_done]=tag;seen_words[frames_done]=0;frames_done=frames_done+1;
    end
    current_tag<=tag;words<=0;
   end else if(current_tag!==tag) begin
    if(errors<10) $display("FAIL mixed tag frame %0d got=%02h want=%02h",frames_done-1,tag,current_tag);
    errors=errors+1;
   end
   if(frames_done>0) seen_words[frames_done-1]=seen_words[frames_done-1]+1;
   words<=words+1;
  end
 end

 task frame(input integer start_fx,input integer next_fx,input integer start_cl,input integer next_cl,input integer fno);begin
  fx=start_fx;cl=start_cl;
  for(integer y=0;y<H;y=y+1) begin
   for(integer x=0;x<W;x=x+2) begin
    v=1;u=(x==0&&y==0);l=(x==W-2);rgb={pixel(x,y,fno),pixel(x+1,y,fno)};
    if(y==8&&x==16) begin fx=next_fx;cl=next_cl;end
    @(negedge clk);
   end
   v=0;u=0;l=0;repeat(384) @(negedge clk);
  end
  repeat(12000) @(negedge clk);
 end endtask

 initial begin
  repeat(8) @(negedge clk);rst=1;
  frame(5,5,0,1,0); // ASCII ALL -> ASCII CLD
  frame(5,5,1,2,1); // ASCII CLD -> ASCII WRM
  frame(5,2,2,1,2); // ASCII WRM -> PIX CLD
  frame(2,4,1,2,3); // PIX CLD -> NEG WRM
  frame(4,0,2,0,4); // NEG WRM -> RGB ALL
  frame(0,0,0,0,5);
  repeat(2000) @(negedge clk);
  if(frames_done!=6) begin $display("FAIL only %0d frames",frames_done);errors=errors+1;end
  if(seen_tag[0]!=={3'd5,2'd0}) begin $display("FAIL frame0 tag=%02h",seen_tag[0]);errors=errors+1;end
  if(seen_tag[1]!=={3'd5,2'd1}) begin $display("FAIL frame1 tag=%02h",seen_tag[1]);errors=errors+1;end
  if(seen_tag[2]!=={3'd5,2'd2}) begin $display("FAIL frame2 tag=%02h",seen_tag[2]);errors=errors+1;end
  if(seen_tag[3]!=={3'd2,2'd1}) begin $display("FAIL frame3 tag=%02h",seen_tag[3]);errors=errors+1;end
  if(seen_tag[4]!=={3'd4,2'd2}) begin $display("FAIL frame4 tag=%02h",seen_tag[4]);errors=errors+1;end
  if(seen_tag[5]!=={3'd0,2'd0}) begin $display("FAIL frame5 tag=%02h",seen_tag[5]);errors=errors+1;end
  if(seen_words[5]!==WORDS)$fatal(1,"last ASCII post frame incomplete");
  if(errors==0) begin test_passed=1;$display("ASCII_POST_PASS frames=6 tags=ASCII_ALL,ASCII_CLD,ASCII_WRM,PIX,NEG,RGB words_per_frame=%0d",WORDS);end
  else $display("ASCII_POST_FAIL errors=%0d",errors);
  $finish;
 end
 initial begin #20000000;$fatal(1,"ASCII post timeout");end
endmodule
