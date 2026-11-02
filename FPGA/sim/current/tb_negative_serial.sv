`timescale 1ns/1ps
module tb_negative_serial;
reg clk=0,rst=0,v=0,u=0,l=0,test_passed=0;
reg [95:0] data=0;reg [4:0] tag=0;
wire [95:0] out;wire ov,ou,ol,overflow;wire [4:0] ot;
reg [102:0] expected[0:4095];integer wr=0,rd=0,checks=0;
reg [95:0] golden;reg [1:0] sel;
always #5 clk=~clk;
final1_color_serial dut(.clk(clk),.rst_n(rst),.data(data),.valid(v),.user(u),.last(l),.config_tag(tag),
 .out_data(out),.out_valid(ov),.out_user(ou),.out_last(ol),.out_config(ot),.overflow(overflow));
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

always @(posedge clk) begin
 if(rst && v) begin
  sel=tag[1:0]==1?0:(tag[1:0]==2?1:3);
  for(integer p=0;p<4;p++)golden[95-p*24-:24]=scalar(data[95-p*24-:24],sel);
  expected[wr%4096]={tag,u,l,golden};wr++;
 end
 #1;
 if(rst)begin
  if(overflow)$fatal(1,"serial overflow");
  if(ov)begin
   if(rd==wr || {ot,ou,ol,out}!==expected[rd%4096])$fatal(1,"serial metadata/pixel mismatch word %0d",rd);
   rd++;checks++;
  end
 end
end
task frame(input [4:0] t);
 begin
  for(integer y=0;y<4;y++)begin
   for(integer x=0;x<320;x++)begin
    @(negedge clk);v=1;u=x==0&&y==0;l=x==319;tag=t;
    data={24'(x*141+y*71),24'(x*163+y*91),24'(x*191+y*101),24'(x*211+y*131)};
   end
   @(negedge clk);v=0;u=0;l=0;repeat(704)@(negedge clk);
  end
  repeat(30)@(negedge clk);if(rd!=wr)$fatal(1,"serial frame drain");
 end
endtask
initial begin
 repeat(6)@(negedge clk);rst=1;
 frame(0);frame(13);frame(16);frame(17);frame(18);frame(2);
 // Abandon an occupied queue, then check reset recovery with a NEG tag.
 @(negedge clk);v=1;u=1;tag=16;@(negedge clk);u=0;
 repeat(32)@(negedge clk);rst=0;v=0;wr=0;rd=0;
 repeat(6)@(negedge clk);rst=1;frame(18);
 test_passed=1;$display("NEGATIVE_SERIAL_PASS checked_words=%0d high_FX_bit_CL_queue_reset",checks);$finish;
end
initial begin #1000000;$fatal(1,"serial timeout");end
endmodule
