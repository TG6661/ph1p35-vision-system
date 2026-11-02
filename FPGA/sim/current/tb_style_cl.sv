`timescale 1ns/1ps
module tb_style_cl;
 reg test_passed=0,clk=0,rst=0,v=0,u=0,l=0;always #5 clk=~clk;
 reg [47:0] data=0;reg [1:0] mode=3;
 wire [47:0] result;wire valid,user,last;
 wire [95:0] refdata;wire refv,refu,refl;
 color_select_96 #(.PIXELS(2),.COLD_SENSITIVITY_ENABLE(1)) dut(
  .I_clk(clk),.I_rst_n(rst),.I_tlast(l),.I_tuser(u),.I_tdata(data),.I_tvalid(v),.I_tready(1'b1),
  .I_cold_sensitivity(4'd0),.I_color_sel(mode),.O_tlast(last),.O_tuser(user),.O_tdata(result),.O_tvalid(valid),.O_tready());
 ref_color_select_96 #(.COLD_SENSITIVITY_ENABLE(1)) refdut(
  .I_clk(clk),.I_rst_n(rst),.I_tlast(l),.I_tuser(u),.I_tdata({data,48'h102030405060}),.I_tvalid(v),.I_tready(1'b1),
  .I_cold_sensitivity(4'd0),.I_color_sel(mode),.O_tlast(refl),.O_tuser(refu),.O_tdata(refdata),.O_tvalid(refv),.O_tready());
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
 reg [47:0] ep0=0,ep1=0;reg [1:0] vp=0,up=0,lp=0;reg pending=0;reg [1:0] active=3,sel;
 integer checks=0,m,n,r,p;reg [31:0] rng=32'h531a28ef;
 always @(posedge clk)begin
  if(!rst)begin vp=0;up=0;lp=0;ep0=0;ep1=0;pending=0;active=3;end
  else begin
   sel=v&&(u||pending)?mode:active;
   ep1=ep0;ep0={scalar(data[47:24],sel),scalar(data[23:0],sel)};
   vp={vp[0],v};up={up[0],u};lp={lp[0],l};
   if(v&&(u||pending))begin active=mode;pending=0;end else if(u)pending=1;
  end
  #1;
  if(rst)begin
   if({valid,user,last}!=={vp[1],up[1],lp[1]})$fatal(1,"CL two-clock tags");
   if({result,valid,user,last}!=={refdata[95:48],refv,refu,refl})$fatal(1,"CL teammate mismatch");
   if(valid)begin
    if(result!==ep1)$fatal(1,"CL scalar mismatch %h %h",result,ep1);
    checks=checks+2;
   end
  end
 end
 task tick(input bit iv,iu,il);begin @(negedge clk);v=iv;u=iu;l=il;end endtask
 initial begin
  repeat(5)tick(0,0,0);rst=1;
  for(m=0;m<4;m=m+1)begin
   mode=m;tick(0,1,0);repeat(3)tick(0,0,0);
   for(n=0;n<65536;n=n+1)begin
    tick(n%17!=16,0,n%640==639);
    rng=(rng<<1)^((rng[31])?32'h04c11db7:0);
    // Exhaust every R/G pair against neutral and +/-16 threshold boundaries,
    // plus a second independent pseudorandom RGB lane.
    r=n&255;p=((n>>8)&3)-1;
    data={8'(r),8'(n>>8),8'((r+16+p)&255),rng[23:0]};
    if(n==15)mode=3-m; // Mid-frame updates must wait for SOF.
   end
   repeat(4)tick(0,0,0);
  end
  tick(1,1,0);tick(1,0,0);@(negedge clk);rst=0;v=0;u=0;l=0;
  repeat(3)tick(0,0,0);rst=1;repeat(5)tick(0,0,0);
  $display("STYLE_CL_PASS pixels=%0d",checks);test_passed=1;$finish;
 end
endmodule
