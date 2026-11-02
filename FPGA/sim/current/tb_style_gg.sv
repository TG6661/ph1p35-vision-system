`timescale 1ns/1ps
module tb_style_gg;
 parameter W=1280,H=720;
 reg test_passed=0,clk=0,rst=0,style=1;
 always #5 clk=~clk;
 reg [95:0] d4=0;reg v4=0,u4=0,l4=0;
 reg [47:0] d2=0;reg v2=0,u2=0,l2=0;
 reg [8:0] gain=224;
 wire [95:0] dr,dold;wire vr,ur,lr,vo,uo,lo;
 wire [47:0] da;wire va,ua,la;
 green_gain96 #(.PIXELS(2),.IMG_WIDTH(W),.IMG_HEIGHT(H)) dut(
  .I_clk(clk),.I_rst_n(rst),.I_style_enable(style),.I_tdata(d2),.I_tvalid(v2),.I_tuser(u2),.I_tlast(l2),.I_gain(gain),
  .O_tdata(da),.O_tvalid(va),.O_tuser(ua),.O_tlast(la));
 ref_green_gain96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H)) refdut(clk,rst,v4,u4,l4,d4,gain,vr,ur,lr,dr);
 old_green_gain96 olddut(clk,rst,v4,u4,l4,d4,gain,vo,uo,lo,dold);
 reg [23:0] expected[0:W*H*4-1];
 integer wr=0,rd=0,frames=0,lines=0,f,y,x,k;reg checking_style=1;
 reg [2:0] valid_pipe=0,last_pipe=0,sof_pipe=0;reg pending=0;
 wire sof=v2&&(u2||pending);
 always @(posedge clk)begin
  if(!rst)begin valid_pipe=0;last_pipe=0;sof_pipe=0;pending=0;end
  else begin
   valid_pipe={valid_pipe[1:0],v2};last_pipe={last_pipe[1:0],l2};sof_pipe={sof_pipe[1:0],sof};
   if(sof)pending=0;else if(u2)pending=1;
  end
  #1;
  if(rst)begin
   if(checking_style?vr:vo)begin
    for(integer q=0;q<4;q=q+1)expected[wr+q]=checking_style?dr[95-24*q-:24]:dold[95-24*q-:24];
    wr=wr+4;
   end
   if({va,ua,la}!=={valid_pipe[2],sof_pipe[2],last_pipe[2]})$fatal(1,"GG marker latency");
   if(va)begin
    for(integer q=0;q<2;q=q+1)begin
     if(rd>=wr || da[47-24*q-:24]!==expected[rd])$fatal(1,"GG pixel f=%0d index=%0d got=%h expected=%h",f,rd,da[47-24*q-:24],expected[rd]);
     rd=rd+1;
    end
    if(ua)frames=frames+1;if(la)lines=lines+1;
   end
  end
 end
 task idle;
  begin @(negedge clk);v4=0;u4=0;l4=0;v2=0;u2=0;l2=0;end
 endtask
 initial begin
  repeat(5)idle();rst=1;
  for(f=0;f<4;f=f+1)begin
   checking_style=(f==0);style=checking_style;
   gain=f==0?224:(f==1?256:(f==2?384:128));
   repeat(12)idle();
   if(f==0)begin @(negedge clk);u4=1;u2=1;repeat(3)idle();end
   for(y=0;y<H;y=y+1)begin
    for(x=0;x<W;x=x+4)begin
     @(negedge clk);
     for(k=0;k<4;k=k+1)d4[95-24*k-:24]={8'((x+k+y*13)&255),8'((255-x-k+y*7)&255),8'((x+k+y*17)&255)};
     v4=1;u4=f!=0&&x==0&&y==0;l4=x==W-4;
     d2=d4[95:48];v2=1;u2=u4;l2=0;
     @(negedge clk);v4=0;u4=0;l4=0;d2=d4[47:0];u2=0;l2=x==W-4;
     if(x==W/4)idle();
    end
    repeat(8)idle();
    // A mid-frame style request must not split the current frame.
    if(y==3)style=!checking_style;
   end
   repeat(12)idle();
  end
  if(rd!=4*W*H||wr!=rd||frames!=4||lines!=4*H)$fatal(1,"GG counts");
  @(negedge clk);rst=0;repeat(4)idle();rst=1;repeat(10)idle();
  $display("STYLE_GG_PASS pixels=%0d frames=%0d lines=%0d",rd,frames,lines);test_passed=1;$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
