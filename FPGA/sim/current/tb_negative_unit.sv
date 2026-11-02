`timescale 1ns/1ps
module tb_negative_unit;
reg [95:0] data=0;wire [95:0] full;wire [47:0] pair;
reg test_passed=0;integer checks=0;
final1_negative_rgb #(.PIXELS(4)) d4(.data(data),.out_data(full));
final1_negative_rgb #(.PIXELS(2)) d2(.data(data[95:48]),.out_data(pair));
initial begin
 for(integer value=0;value<256;value++) begin
  for(integer channel=0;channel<12;channel++) data[channel*8+:8]=(value+channel*19)%256;
  #1;
  for(integer channel=0;channel<12;channel++) begin
   if(full[channel*8+:8]!==8'(255-data[channel*8+:8])) $fatal(1,"NEG arithmetic");
   checks++;
  end
  if(pair!==full[95:48]) $fatal(1,"2px ordering");
 end
 test_passed=1;$display("NEGATIVE_UNIT_PASS channels=12 values_per_channel=256 checks=%0d widths=48,96",checks);$finish;
end
endmodule
