`timescale 1ns/1ps
module tb_style_lsc;
 reg test_passed=0,clk=0,rst=0,v=0,u=0,l=0;
 always #5 clk=~clk;
 reg [39:0] d=0;reg [1:0] level=0;
 wire [39:0] a,b,c;wire av,au,al,bv,bu,bl,cv,cu,cl;
 raw_delay_4px dut(clk,rst,d,v,u,l,a,av,au,al);
 ref_raw_lsc_4px refdut(clk,rst,d,v,u,l,level,b,bv,bu,bl);
 old_lsc olddut(clk,rst,d,v,u,l,level,c,cv,cu,cl);
 integer checks=0,pixels=0,f,y,x,k;
 always @(posedge clk) begin
  #1;
  if(rst)begin
   if({av,au,al}!=={bv,bu,bl} || (av && a!==b))$fatal(1,"raw delay differs from prior OFF");
   if({av,au,al}!=={cv,cu,cl} || (av && a!==c))$fatal(1,"OFF/LOW baseline mismatch");
   checks=checks+1;if(av)pixels=pixels+4;
  end
 end
 task tick(input bit valid,user,last,input integer row,groupno);
  begin
   @(negedge clk);v=valid;u=user;l=last;
   for(integer q=0;q<4;q=q+1)d[q*10+:10]=(row*31+groupno*17+q*197+f*113)&1023;
  end
 endtask
 initial begin
  repeat(5)@(negedge clk);rst=1;
  for(f=0;f<2;f=f+1)begin
   level=0;repeat(10)tick(0,0,0,0,0);
   if(f==0)begin tick(0,1,0,0,0);repeat(3)tick(0,0,0,0,0);end
   for(y=0;y<720;y=y+1)begin
    for(x=0;x<320;x=x+1)begin
     tick(1,f==1&&y==0&&x==0,x==319,y,x);
     if(x==113)tick(0,0,0,0,0);
    end
    repeat(8)tick(0,0,0,0,0);
   end
   repeat(12)tick(0,0,0,0,0);
  end
  // Asynchronous occupied reset and fresh early SOF.
  tick(1,1,0,0,0);tick(1,0,0,0,1);@(negedge clk);rst=0;v=0;u=0;
  repeat(3)@(negedge clk);rst=1;repeat(8)tick(0,0,0,0,0);
  tick(0,1,0,0,0);tick(1,0,0,0,0);repeat(12)tick(0,0,0,0,0);
  if(pixels<1843200)$fatal(1,"insufficient pixels");
  $display("RAW_DELAY_PASS checks=%0d pixels=%0d",checks,pixels);test_passed=1;$finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
