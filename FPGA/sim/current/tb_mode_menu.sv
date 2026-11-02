`timescale 1ns/1ps
module tb_mode_menu;
 reg c=0,p=0,rst=0,test_passed=0;always #7 c=~c;always #6.5 p=~p;
 reg [95:0] command=0,current=0;reg submit=0,de=0,hs=0,vs=0,cfg=1,error=0;
 wire ready,done,rr,rd,od,oh,ov,bd,bh,bv;
 wire [23:0] out,old;
 reg [88:0] latency={5'b11100,24'h012345,24'h012342,12'h003,24'h050017};
 camera_settings_osd #(.LATENCY_ENABLE(1)) dut(.src_clk(c),.pixel_clk(p),.reset_n(rst),
  .command(command),.submit(submit),.ready(ready),.done(done),.cfg_done(cfg),.iic_error(error),
  .latency_data(latency),.rgb(24'h436b91),.de(de),.hs(hs),.vs(vs),.out_rgb(out),.out_de(od),.out_hs(oh),.out_vs(ov));
 camera_settings_osd_reference #(.LATENCY_ENABLE(1)) reference_hud(.src_clk(c),.pixel_clk(p),.reset_n(rst),
  .command(command),.submit(submit),.ready(rr),.done(rd),.cfg_done(cfg),.iic_error(error),
  .latency_data(latency),.rgb(24'h436b91),.de(de),.hs(hs),.vs(vs),.out_rgb(old),.out_de(bd),.out_hs(bh),.out_vs(bv));
 integer vectors=0,rows_checked=0,pixels=0,compared=0,shot=0,fd,n,frame_rows,mode,fx;
 integer x,y,px,py,row_index,item;reg outside_panel,active_frame=0;reg [7:0] glyph_union;
 reg [1:0] logo_fixture[0:13723];reg [23:0] logo_expected;
 reg check_logo;integer logo_checks=0;integer fullshot=0;
 initial $readmemh("current/logo_pixels.hex",logo_fixture);
 reg [95:0] next_vector;reg [159:0] wanted;
 function automatic [159:0] pad(input string s);
  reg [159:0] result;begin
   result="                    ";if(s.len()>20)$fatal(1,"Expected text too wide");
   for(integer k=0;k<s.len();k++)result[159-8*k-:8]=s[k];pad=result;
  end
 endfunction
 function automatic integer decimal(input [15:0] bcd);
  decimal=bcd[3:0]+10*bcd[7:4]+100*bcd[11:8]+1000*bcd[15:12];
 endfunction
 function automatic string number(input integer value,input integer width);
  string result;integer v;begin
   result="";v=value;
   repeat(width)begin result={8'(48+v%10),result};v=v/10;end
   number=result;
  end
 endfunction
 function automatic integer selection_id(input integer row_number);
  case(row_number)
   0:selection_id=5;1:selection_id=10;2:selection_id=0;3:selection_id=1;
   4:selection_id=3;5:selection_id=4;6:selection_id=6;7:selection_id=7;8:selection_id=8;
   9:selection_id=mode==0?9:-1;default:selection_id=-1;
  endcase
 endfunction
 function automatic [159:0] expected_line(input integer r);
  string s;begin
   s="";
   case(r)
    0:s=mode==0?"MODE:RED":mode==1?"MODE:MOTION":"MODE:STYLE";
    1:s=current[39]?"AUTO EXP:ON":"AUTO EXP:OFF";
    2:s={"AE:",number(decimal(current[15:0]),4)};
    3:s={"AG:",number(decimal({4'd0,current[27:16]}),3)};
    4:s=current[92]?"BL:ON":"BL:OFF";
    5:s={"BO:",number(decimal({4'd0,current[51:40]}),3)};
    6:if(mode==0)s={"RMIN:",number(decimal({4'd0,current[63:52]}),3)};
      else if(mode==1)s={"DIFF:",number(decimal({4'd0,current[63:52]}),3)};
      else case(fx) 0:s="FX:RGB";1:s="FX:CRT";2:s="FX:PIX";3:s="FX:HAT";4:s="FX:NEG";5:s="FX:ASCII";endcase
    7:if(mode==0)s={"RGAP:",number(decimal({4'd0,current[75:64]}),3)};
      else if(mode==1)s={"NEIG:",number(current[67:64],3)};
      else case(current[67:64])0:s="CL:ALL";1:s="CL:CLD";2:s="CL:WRM";endcase
    8:if(mode==0)s={"BGAP:",number(decimal({4'd0,current[87:76]}),3)};
       else if(mode==1)s={"HOLD:",number(decimal({4'd0,current[87:76]}),3)};
       else s="";
    9:if(mode==0)s=current[95]?"TRACK:PATROL":"TRACK:OFF";
   endcase
   expected_line=pad(s);
  end
 endfunction
 always @(posedge p)begin
  px=dut.S_x_2d;py=dut.S_y_2d;
  outside_panel=!(de && ((px>=24 && px<344 && py>=24 && py<488) ||
       (px>=32 && px<178 && py>=600 && py<694) ||
       (px>=32 && px<96 && py>=640 && py<688) || dut.latency_box));
  check_logo=rst && active_frame && de && px>=32 && px<178 && py>=600 && py<694;
  if(check_logo) begin
   case(logo_fixture[(py-600)*146+px-32])
    0:logo_expected=24'h436b91;1:logo_expected=24'h1c2d4e;
    2:logo_expected=24'hed1c24;3:logo_expected=24'hffffff;
   endcase
  end
  if(rst && active_frame && de)begin
   if(dut.displayed[95:0]!==current)$fatal(1,"mid-frame HUD tearing");
   if(px==24 && py>=28 && (py-28)%20==0 && py<28+frame_rows*20)begin
    row_index=(py-28)/20;wanted=expected_line(row_index);item=selection_id(row_index);
    if(dut.line_text!==wanted)$fatal(1,"vector=%0d row=%0d got=[%s] expected=[%s]",vectors,row_index,dut.line_text,wanted);
    if(dut.S_osd_selected_line!==((item>=0)&&(current[91:88]==item)))$fatal(1,"selection mapping");
    if(dut.S_osd_readonly_line!==(item<0))$fatal(1,"read-only navigation");
    for(integer ch=0;ch<20;ch++)if(wanted[159-ch*8-:8]!=8'h20)begin
     glyph_union=0;
     for(integer gr=0;gr<8;gr++)glyph_union=glyph_union|dut.font8_row(wanted[159-ch*8-:8],gr);
     if(glyph_union==0)$fatal(1,"missing font glyph %h",wanted[159-ch*8-:8]);
    end
    rows_checked++;
   end
  end
  #1;
  if(rst)begin
   if({od,oh,ov,ready,done}!=={bd,bh,bv,rr,rd})$fatal(1,"HUD handshake or video latency changed");
   if(check_logo)begin if(out!==logo_expected)$fatal(1,"Logo coordinate/palette x=%0d y=%0d got=%h want=%h",px,py,out,logo_expected);logo_checks++;end
   if(outside_panel && out!==old)$fatal(1,"pixel outside menu changed x=%0d y=%0d",px,py);
   if(od && active_frame)begin
    pixels++;if(outside_panel)compared++;
    if(fullshot)$fdisplay(fullshot,"%06h",out);
    if(shot && px>=24 && px<344 && py>=24 && py<28+frame_rows*20)$fdisplay(shot,"%06h",out);
   end
  end
 end
 task send;begin
  wait(ready);@(negedge c);submit=1;@(negedge c);submit=0;wait(done);repeat(4)@(negedge p);
 end endtask
 task vsync;begin
  @(negedge p);vs=1;repeat(5)@(negedge p);vs=0;repeat(5)@(negedge p);
 end endtask
 initial begin
  repeat(12)@(negedge c);rst=1;repeat(20)@(negedge p);
  fd=$fopen("current/menu_vectors.txt","r");if(!fd)$fatal(1,"Run current/run_host.ps1 first");
  while(!$feof(fd))begin
   n=$fscanf(fd,"%h %h %h\n",next_vector[95:64],next_vector[63:32],next_vector[31:0]);
   if(n==3)begin
    command=next_vector;if(vectors>=3)command[91:88]=vectors%11;
    cfg=vectors<3?1:vectors%2;error=vectors<3?0:vectors%3==0;
    send();if(vectors && dut.displayed[95:0]!==current)$fatal(1,"payload changed before VS");
    current=command;mode=current[94:93];fx=current[63:52];
    frame_rows=mode==0?10:(mode==1?9:8);
    vsync();if(dut.displayed[95:0]!==current)$fatal(1,"VS snapshot");
    if(vectors==0)fullshot=$fopen("current/menu_full_red.hex","w");
    if(vectors==0)shot=$fopen("current/menu_red.hex","w");
    if(vectors==1)shot=$fopen("current/menu_motion.hex","w");
    if(vectors==2)shot=$fopen("current/menu_style.hex","w");
    active_frame=1;
    for(y=0;y<(vectors<3?720:488);y++)begin
     @(negedge p);de=1;
     for(x=0;x<(vectors<3?1280:40);x++)begin
      // Unsubmitted shadow changes must never leak into the displayed frame.
      if(x==30 && y==60)command=~command;
      if(vectors==0 && x==30 && y==200)fork
       begin command=current;command[39]=~current[39];send();end
      join_none
      @(negedge p);
     end
     de=0;repeat(4)@(negedge p);
    end
    active_frame=0;if(fullshot)begin $fclose(fullshot);fullshot=0;end
    if(shot)begin $fclose(shot);shot=0;end
    vectors++;
   end
  end
  $fclose(fd);if(vectors!=102 || rows_checked!=882)$fatal(1,"incomplete coverage %0d %0d",vectors,rows_checked);
  if(logo_checks!=3*146*94)$fatal(1,"Logo coverage %0d",logo_checks);
  rst=0;repeat(10)@(negedge c);rst=1;repeat(20)@(negedge p);
  if(dut.displayed[95] || dut.displayed[94:93]!=0 || dut.displayed[91:88]!=5)$fatal(1,"default RED/menu/reset");
  test_passed=1;$display("MODE_MENU_RTL_PASS vectors=%0d rows=%0d pixels=%0d unchanged_pixels=%0d VS_atomic adjustable_only",vectors,rows_checked,pixels,compared);$finish;
 end
 initial begin #250000000;$fatal(1,"mode menu timeout");end
endmodule
