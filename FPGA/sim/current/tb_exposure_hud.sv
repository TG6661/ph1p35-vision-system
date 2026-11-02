`timescale 1ns/1ps
module tb_exposure_hud;
 reg c=0,p=0,rst=0,test_passed=0;always #7 c=~c;always #6.5 p=~p;
 reg [23:0] rgb=24'h436b91;reg de=0,hs=0,vs=0;
 reg [95:0] command={1'b0,2'd0,1'b1,4'd0,12'h065,12'h065,12'h100,12'h032,12'h070,12'h190,16'h1991};
 reg submit=0;wire ready,done,rr,rd;reg [88:0] payload={5'b11100,24'h012345,24'h012342,12'h003,24'h050017};
 wire [23:0] out,old;wire od,oh,ov,bd,bh,bv;
 camera_settings_osd #(.LATENCY_ENABLE(1)) dut(.src_clk(c),.pixel_clk(p),.reset_n(rst),.command(command),.submit(submit),.ready(ready),.done(done),
 .cfg_done(1'b1),.iic_error(1'b0),.latency_data(payload),.rgb(rgb),.de(de),.hs(hs),.vs(vs),.out_rgb(out),.out_de(od),.out_hs(oh),.out_vs(ov));
 camera_settings_osd_reference #(.LATENCY_ENABLE(1)) reference_hud(.src_clk(c),.pixel_clk(p),.reset_n(rst),.command(command),.submit(submit),.ready(rr),.done(rd),
 .cfg_done(1'b1),.iic_error(1'b0),.latency_data(payload),.rgb(rgb),.de(de),.hs(hs),.vs(vs),.out_rgb(old),.out_de(bd),.out_hs(bh),.out_vs(bv));
 integer x,y,frame,pixels=0,compared=0,rows=0,fd=0;reg changed_d;reg [95:0] current;
 always @(posedge p) begin
  changed_d=de && dut.S_x_2d>=24 && dut.S_x_2d<216 && dut.S_y_2d>=24 && dut.S_y_2d<288 && (dut.S_x_2d>=200 || dut.S_y_2d>=224);
  if(rst && de && dut.S_x_2d==24) begin
   if(dut.S_y_2d==228)begin
    if(dut.line_text!==(current[39]?"AUTO EXP:ON     ":"AUTO EXP:OFF    "))$fatal(1,"AUTO EXP text");
    if(dut.S_osd_selected_line!==(current[91:88]==10))$fatal(1,"AUTO EXP highlight");
   end
   if(dut.S_y_2d==208)begin
    if(dut.line_text!==(current[95]?"TRACK:ON        ":"TRACK:OFF       ")) $fatal(1,"TRACK text");
    if(dut.S_osd_selected_line!==(current[91:88]==9)) $fatal(1,"TRACK highlight");rows++;
   end
   if(dut.S_y_2d==248 && dut.line_text!=="CFG:1           ")$fatal(1,"CFG moved/lost");
   if(dut.S_y_2d==268 && dut.line_text!=="I2C:0           ")$fatal(1,"I2C moved/lost");
  end
  #1;
  if(rst)begin
   if({od,oh,ov,ready,done}!={bd,bh,bv,rr,rd})$fatal(1,"HUD handshake/latency changed");
   if(!changed_d && out!==old)$fatal(1,"unmodified pixels changed");
   if(od)begin pixels++;if(!changed_d)compared++;if(fd)$fdisplay(fd,"%06h",out);end
  end
 end
 task send;begin
  wait(ready);@(negedge c);submit=1;@(negedge c);submit=0;wait(done);repeat(3)@(negedge p);
 end endtask
 task vsync;begin @(negedge p);vs=1;repeat(5)@(negedge p);vs=0;repeat(5)@(negedge p);end endtask
 initial begin
  repeat(12)@(negedge c);rst=1;repeat(20)@(negedge p);
  send();current=command;vsync();
  for(frame=0;frame<3;frame++)begin
   command[95]=(frame!=0);command[94:93]=frame;command[91:88]=10;command[39]=(frame!=0);send();
   current=command;vsync();
   if(dut.displayed[95:0]!==current)$fatal(1,"coherent VS payload");
   if(frame==1)fd=$fopen("current/hud_rgb.hex","w");
   for(y=0;y<720;y++)begin
    @(negedge p);de=1;
    for(x=0;x<1280;x++)begin
     if(frame==1 && y==300 && x==700)command[39]=0;
     if(dut.displayed[95:0]!==current)$fatal(1,"mid-frame tearing");
     @(negedge p);
    end
    de=0;repeat(12)@(negedge p);
   end
   if(fd)begin $fclose(fd);fd=0;end
  end
  if(pixels!=3*921600 || rows!=3)$fatal(1,"pixel/row coverage");
  test_passed=1;$display("EXPOSURE_HUD_PASS pixels=%0d unchanged=%0d eleven_items=PASS VS_atomic=PASS",pixels,compared);$finish;
 end
 initial begin #60000000;$fatal(1,"HUD timeout");end
endmodule
