`timescale 1ns/1ps
// Reproducer: original teammate color takes 11 clocks while valid/edge take 12.
// First row has no edges or historical pixels; an independent scalar quantizer
// therefore determines every output exactly, even at continuous 4px/clock.
module tb_crt_latency;
 reg test_passed=0,clk=0,rst=0,v=0,u=0,l=0;always #5 clk=~clk;
 reg [95:0] d=0;wire [95:0] original,fixed_data;wire ov,ou,ol,fv,fu,fl;
 wire ready0,ready1;
 defect_cartoon_96 #(.IMG_WIDTH(64),.IMG_HEIGHT(8)) broken(clk,rst,l,u,d,v,1'b1,ol,ou,original,ov,ready0);
 ref_cartoon_96 #(.IMG_WIDTH(64),.IMG_HEIGHT(8)) repaired(clk,rst,l,u,d,v,1'b1,fl,fu,fixed_data,fv,ready1);
 integer n=0,mismatches=0,k,p;reg [7:0] expected;
 always @(posedge clk)begin #1;
  if(rst&&fv)begin
   if(!ov||ou!==fu||ol!==fl)$fatal(1,"marker changed");
   for(integer q=0;q<4;q=q+1)begin
    expected=8'(((n+q)*3/32)*32+16);
    if(fixed_data[95-24*q-:24]!=={3{expected}})$fatal(1,"scalar quant mismatch pixel=%0d",n+q);
    if(original[95-24*q-:24]!=={3{expected}})mismatches=mismatches+1;
   end
   n=n+4;
  end
 end
 initial begin
  repeat(5)@(negedge clk);rst=1;
  for(k=0;k<16;k=k+1)begin
   @(negedge clk);v=1;u=k==0;l=k==15;
   for(p=0;p<4;p=p+1)d[95-24*p-:24]={3{8'((k*4+p)*3)}};
  end
  @(negedge clk);v=0;u=0;l=0;repeat(20)@(negedge clk);
  if(n!=64||mismatches==0)$fatal(1,"defect not reproduced");
  $display("STYLE_CRT_LATENCY_PASS original_mismatches=%0d corrected_pixels=%0d",mismatches,n);test_passed=1;$finish;
 end
endmodule
