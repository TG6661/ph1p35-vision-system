`timescale 1ns/1ps
module tb_style_crt;
 parameter W=1280,H=720;
 reg test_passed=0,clk=0,rst=0;
 always #5 clk=~clk;
 reg [95:0] d4=0;reg v4=0,u4=0,l4=0;
 reg [47:0] d2=0;reg v2=0,u2=0,l2=0;
 wire [95:0] dr;wire vr,ur,lr;
 wire [47:0] da;wire va,ua,la;
 cartoon_96 #(.PIXELS(2),.IMG_WIDTH(W),.IMG_HEIGHT(H)) dut(
  .I_clk(clk),.I_rst_n(rst),.I_tdata(d2),.I_tvalid(v2),.I_tuser(u2),.I_tlast(l2),.I_tready(1'b1),
  .O_tdata(da),.O_tvalid(va),.O_tuser(ua),.O_tlast(la),.O_tready());
 ref_cartoon_96 #(.IMG_WIDTH(W),.IMG_HEIGHT(H)) refdut(
  .I_clk(clk),.I_rst_n(rst),.I_tdata(d4),.I_tvalid(v4),.I_tuser(u4),.I_tlast(l4),.I_tready(1'b1),
  .O_tdata(dr),.O_tvalid(vr),.O_tuser(ur),.O_tlast(lr),.O_tready());
 reg [23:0] expected[0:W*H*2-1];
 integer wr=0,rd=0,frames=0,lines=0,f,y,x,k;
 reg [11:0] vp=0,lp=0,up=0;
 always @(posedge clk)begin
  if(!rst)begin vp=0;lp=0;up=0;end
  else begin vp={vp[10:0],v2};lp={lp[10:0],l2};up={up[10:0],u2};end
  #1;
  if(rst)begin
   if(vr)begin for(integer q=0;q<4;q=q+1)expected[wr+q]=dr[95-24*q-:24];wr=wr+4;end
   if({va,ua,la}!=={vp[11],up[11],lp[11]})$fatal(1,"CRT marker latency");
   if(va)begin
    for(integer q=0;q<2;q=q+1)begin
     if(rd>=wr || da[47-24*q-:24]!==expected[rd])$fatal(1,"CRT pixel index=%0d xy=(%0d,%0d) got=%h expected=%h",rd,rd%W,(rd/W)%H,da[47-24*q-:24],expected[rd]);
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
  for(f=0;f<2;f=f+1)begin
   repeat(20)idle();
   for(y=0;y<H;y=y+1)begin
    for(x=0;x<W;x=x+4)begin
     @(negedge clk);
     for(k=0;k<4;k=k+1)
      if(f==0)d4[95-24*k-:24]={8'(((x+k)/13+y/11)&255),8'(255-((x+k)/7+y/5)&255),8'(((x+k)/23+y/17)&255)};
      else d4[95-24*k-:24]={8'((x+k+y*13)&255),8'((255-x-k+y*7)&255),8'((x+k+y*17)&255)};
     v4=1;u4=x==0&&y==0;l4=x==W-4;
     d2=d4[95:48];v2=1;u2=u4;l2=0;
     @(negedge clk);v4=0;u4=0;l4=0;d2=d4[47:0];u2=0;l2=x==W-4;
     if(x==W/4)idle();
    end
    repeat(16)idle();
   end
   repeat(20)idle();
  end
  if(rd!=2*W*H||wr!=rd||frames!=2||lines!=2*H)$fatal(1,"CRT counts");
  $display("STYLE_CRT_PASS pixels=%0d frames=%0d lines=%0d",rd,frames,lines);test_passed=1;$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
