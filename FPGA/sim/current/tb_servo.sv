`timescale 1ns/1ps
module tb_servo;
 parameter DIV=2;
 reg clk=0,rst=0,write=0;always #3.333 clk=~clk;
 reg [4:0] wa=0,ra=0;reg [31:0] wd=0;wire [31:0] rd;wire pan,tilt;
 reg test_passed=0;integer checks=0;
 final1_servo_pwm #(.CLOCKS_PER_US(DIV)) dut(clk,rst,write,wa,wd,ra,rd,pan,tilt);
 task check(input bit ok,input string msg);begin checks++;if(!ok)$fatal(1,"%s",msg);end endtask
 task wr(input [4:0] addr,input [31:0] data);begin
  @(negedge clk);write=1;wa=addr;wd=data;@(negedge clk);write=0;
 end endtask
 task read_check(input [4:0] addr,input [31:0] expected);begin
  ra=addr;#1;check(rd===expected,$sformatf("read word%0d got %h expected %h",addr,rd,expected));
 end endtask
 task pair(input integer a,b);begin wr(25,a);wr(26,b);wr(27,5);end endtask
 integer cycle=0,pan_rise=-1,tilt_rise=-1,last_pan=-1,last_tilt=-1,exp_pan=1500,exp_tilt=1500,periods=0;
 reg prev_pan=0,prev_tilt=0;
 always @(posedge clk) begin
  #0.1;cycle++;
  if(!rst)begin prev_pan=0;prev_tilt=0;pan_rise=-1;tilt_rise=-1;last_pan=-1;last_tilt=-1;end
  else begin
   if(pan && !prev_pan)begin
    if(last_pan>=0)check(cycle-last_pan==20000*DIV,"PAN period not 20ms");
    check(tilt,"pair rising edges not atomic");pan_rise=cycle;last_pan=cycle;periods++;
   end
   if(tilt && !prev_tilt)begin
    if(last_tilt>=0)check(cycle-last_tilt==20000*DIV,"TILT period not 20ms");
    tilt_rise=cycle;last_tilt=cycle;
   end
   if(!pan && prev_pan)check(cycle-pan_rise==exp_pan*DIV,"PAN pulse truncated/wrong length");
   if(!tilt && prev_tilt)check(cycle-tilt_rise==exp_tilt*DIV,"TILT pulse truncated/wrong length");
   prev_pan=pan;prev_tilt=tilt;
  end
 end
 initial begin
  #1;repeat(4)@(negedge clk);rst=1;
  read_check(28,32'h53560101);read_check(25,1500);read_check(26,1500);read_check(27,0);
  @(posedge pan);repeat(10)@(negedge clk);
  pair(500,2500);read_check(27,1);
  wr(25,2200);wr(26,800);wr(27,1);read_check(27,3);
  @(posedge pan);#1;exp_pan=500;exp_tilt=2500;read_check(29,(2500<<12)|500);read_check(27,2);
  wr(27,4);read_check(27,0);
  wr(25,0);read_check(25,1500);wr(25,1);read_check(25,500);
  wr(26,32'hffffffff);read_check(26,2500);
  wr(25,2000);wr(26,1000);wr(27,5);wr(27,3);read_check(27,3);
  wr(27,6);read_check(27,0);
  @(posedge pan);#1;read_check(29,(2500<<12)|500);
  pair(2000,1000);
  @(posedge pan);#1;exp_pan=2000;exp_tilt=1000;read_check(29,(1000<<12)|2000);
  // Commit on idle boundary waits one full period.
  wr(25,700);wr(26,2300);
  wait(dut.period_us==19999 && dut.divider==DIV-1);
  @(negedge clk);write=1;wa=27;wd=5;
  @(negedge clk);write=0;read_check(29,(1000<<12)|2000);read_check(27,1);
  @(posedge pan);#1;exp_pan=700;exp_tilt=2300;read_check(29,(2300<<12)|700);
  pair(1800,1200);
  wait(dut.period_us==19999 && dut.divider==DIV-1);
  @(negedge clk);write=1;wa=27;wd=6;
  @(negedge clk);write=0;read_check(29,(2300<<12)|700);read_check(27,0);
  // A busy commit on the apply edge rejects the second request but applies
  // the already accepted pair. Reserved command bits cannot cancel it.
  pair(1800,1200);wr(27,8);read_check(27,3);
  wait(dut.period_us==19999 && dut.divider==DIV-1);
  @(negedge clk);write=1;wa=27;wd=5;
  @(negedge clk);write=0;exp_pan=1800;exp_tilt=1200;
  read_check(29,(1200<<12)|1800);read_check(27,2);
  wait(!pan && !tilt);repeat(10)@(negedge clk);
  @(posedge pan);repeat(10)@(negedge clk);pair(1200,1800);@(negedge clk);rst=0;#1;check(!pan && !tilt,"reset output");read_check(27,0);read_check(29,(1500<<12)|1500);
  repeat(3)@(negedge clk);exp_pan=1500;exp_tilt=1500;rst=1;
  @(posedge pan);wait(!pan && !tilt);#1;
  check(periods>=7,"missing full periods");test_passed=1;
  $display("SERVO_PWM_PASS DIV=%0d checks=%0d periods=%0d",DIV,checks,periods);$finish;
 end
 initial begin #2000000000;$fatal(1,"timeout");end
endmodule
