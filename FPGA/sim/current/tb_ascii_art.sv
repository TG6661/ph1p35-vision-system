`timescale 1ns/1ps
// Directed test for the FX5 ASCII renderer. The small 64x32 frame keeps the
// double-buffer and 2-pixel timing visible while still exercising two 16-row bands.
module tb_ascii_art;
 reg test_passed=0;
 localparam integer W=64,H=32,BEATS=W/2,CELLS=W/16,CELL_BEATS=16/2,LINE_PERIOD=64;
 localparam integer FRAME_WORDS=(W/2)*H;
 localparam integer MAX_WORDS=FRAME_WORDS;
 reg clk=0,rst=0,valid=0,user=0,last=0;
 reg [47:0] data=0;
 wire out_valid,out_user,out_last;
 wire [47:0] out_data;
 integer cap_count=0,cap_user=0,cap_last=0;
 reg [47:0] cap_data[0:MAX_WORDS-1];
 reg cap_user_v[0:MAX_WORDS-1];
 reg cap_last_v[0:MAX_WORDS-1];
 integer errors=0;
 reg [3:0] exp_char[0:7];
 reg [23:0] exp_color[0:7];
 integer frame_sel=0;
 integer row,beat,block,band,cellno,target,gl;
 reg [7:0] gray;
 reg [23:0] solid;

 ascii_art_96 #(.PIXELS(2),.IMG_WIDTH(W),.IMG_HEIGHT(H),.FIXED_LINE_PERIOD(LINE_PERIOD)) dut(
  .I_clk(clk),.I_rst_n(rst),.I_tlast(last),.I_tuser(user),.I_tvalid(valid),.I_tdata(data),
  .I_tready(1'b1),.O_tlast(out_last),.O_tuser(out_user),.O_tdata(out_data),.O_tvalid(out_valid),.O_tready());

 always #5 clk=~clk;

 function [7:0] glyph8(input [3:0] ci,input [3:0] row);
  begin
   case({ci,row})
    8'h00:glyph8=8'h00; 8'h01:glyph8=8'h00; 8'h02:glyph8=8'h00; 8'h03:glyph8=8'h00; 8'h04:glyph8=8'h00; 8'h05:glyph8=8'h00; 8'h06:glyph8=8'h00; 8'h07:glyph8=8'h00; 8'h08:glyph8=8'h00; 8'h09:glyph8=8'h00; 8'h0a:glyph8=8'h00; 8'h0b:glyph8=8'h00; 8'h0c:glyph8=8'h00; 8'h0d:glyph8=8'h00; 8'h0e:glyph8=8'h00; 8'h0f:glyph8=8'h00;
    8'h10:glyph8=8'h00; 8'h11:glyph8=8'h00; 8'h12:glyph8=8'h00; 8'h13:glyph8=8'h00; 8'h14:glyph8=8'h00; 8'h15:glyph8=8'h00; 8'h16:glyph8=8'h00; 8'h17:glyph8=8'h00; 8'h18:glyph8=8'h00; 8'h19:glyph8=8'h18; 8'h1a:glyph8=8'h38; 8'h1b:glyph8=8'h18; 8'h1c:glyph8=8'h00; 8'h1d:glyph8=8'h00; 8'h1e:glyph8=8'h00; 8'h1f:glyph8=8'h00;
    8'h20:glyph8=8'h00; 8'h21:glyph8=8'h00; 8'h22:glyph8=8'h00; 8'h23:glyph8=8'h00; 8'h24:glyph8=8'h00; 8'h25:glyph8=8'h18; 8'h26:glyph8=8'h18; 8'h27:glyph8=8'h00; 8'h28:glyph8=8'h00; 8'h29:glyph8=8'h00; 8'h2a:glyph8=8'h18; 8'h2b:glyph8=8'h18; 8'h2c:glyph8=8'h00; 8'h2d:glyph8=8'h00; 8'h2e:glyph8=8'h00; 8'h2f:glyph8=8'h00;
    8'h30:glyph8=8'h00; 8'h31:glyph8=8'h00; 8'h32:glyph8=8'h00; 8'h33:glyph8=8'h00; 8'h34:glyph8=8'h00; 8'h35:glyph8=8'h00; 8'h36:glyph8=8'h00; 8'h37:glyph8=8'h00; 8'h38:glyph8=8'h3c; 8'h39:glyph8=8'h00; 8'h3a:glyph8=8'h00; 8'h3b:glyph8=8'h00; 8'h3c:glyph8=8'h00; 8'h3d:glyph8=8'h00; 8'h3e:glyph8=8'h00; 8'h3f:glyph8=8'h00;
    8'h40:glyph8=8'h00; 8'h41:glyph8=8'h00; 8'h42:glyph8=8'h00; 8'h43:glyph8=8'h00; 8'h44:glyph8=8'h00; 8'h45:glyph8=8'h00; 8'h46:glyph8=8'h00; 8'h47:glyph8=8'h7e; 8'h48:glyph8=8'h00; 8'h49:glyph8=8'h7e; 8'h4a:glyph8=8'h00; 8'h4b:glyph8=8'h00; 8'h4c:glyph8=8'h00; 8'h4d:glyph8=8'h00; 8'h4e:glyph8=8'h00; 8'h4f:glyph8=8'h00;
    8'h50:glyph8=8'h00; 8'h51:glyph8=8'h00; 8'h52:glyph8=8'h00; 8'h53:glyph8=8'h00; 8'h54:glyph8=8'h00; 8'h55:glyph8=8'h18; 8'h56:glyph8=8'h18; 8'h57:glyph8=8'h18; 8'h58:glyph8=8'hfe; 8'h59:glyph8=8'h18; 8'h5a:glyph8=8'h18; 8'h5b:glyph8=8'h18; 8'h5c:glyph8=8'h00; 8'h5d:glyph8=8'h00; 8'h5e:glyph8=8'h00; 8'h5f:glyph8=8'h00;
    8'h60:glyph8=8'h00; 8'h61:glyph8=8'h00; 8'h62:glyph8=8'h18; 8'h63:glyph8=8'h5c; 8'h64:glyph8=8'h7c; 8'h65:glyph8=8'h7c; 8'h66:glyph8=8'h5c; 8'h67:glyph8=8'h18; 8'h68:glyph8=8'h00; 8'h69:glyph8=8'h00; 8'h6a:glyph8=8'h00; 8'h6b:glyph8=8'h00; 8'h6c:glyph8=8'h00; 8'h6d:glyph8=8'h00; 8'h6e:glyph8=8'h00; 8'h6f:glyph8=8'h00;
    8'h70:glyph8=8'h00; 8'h71:glyph8=8'h00; 8'h72:glyph8=8'h00; 8'h73:glyph8=8'h34; 8'h74:glyph8=8'h24; 8'h75:glyph8=8'h7f; 8'h76:glyph8=8'h24; 8'h77:glyph8=8'h24; 8'h78:glyph8=8'h2c; 8'h79:glyph8=8'hfe; 8'h7a:glyph8=8'h6c; 8'h7b:glyph8=8'h6c; 8'h7c:glyph8=8'h00; 8'h7d:glyph8=8'h00; 8'h7e:glyph8=8'h00; 8'h7f:glyph8=8'h00;
    8'h80:glyph8=8'h00; 8'h81:glyph8=8'h00; 8'h82:glyph8=8'h62; 8'h83:glyph8=8'hf6; 8'h84:glyph8=8'hf4; 8'h85:glyph8=8'h6c; 8'h86:glyph8=8'h18; 8'h87:glyph8=8'h10; 8'h88:glyph8=8'h3e; 8'h89:glyph8=8'h6b; 8'h8a:glyph8=8'h4a; 8'h8b:glyph8=8'hce; 8'h8c:glyph8=8'h00; 8'h8d:glyph8=8'h00; 8'h8e:glyph8=8'h00; 8'h8f:glyph8=8'h00;
    8'h90:glyph8=8'h00; 8'h91:glyph8=8'h00; 8'h92:glyph8=8'h1c; 8'h93:glyph8=8'h26; 8'h94:glyph8=8'h62; 8'h95:glyph8=8'h5f; 8'h96:glyph8=8'hff; 8'h97:glyph8=8'hff; 8'h98:glyph8=8'hef; 8'h99:glyph8=8'hef; 8'h9a:glyph8=8'hfe; 8'h9b:glyph8=8'hfe; 8'h9c:glyph8=8'hc0; 8'h9d:glyph8=8'h64; 8'h9e:glyph8=8'h3c; 8'h9f:glyph8=8'h00;
    default:glyph8=8'h00;
   endcase
  end
 endfunction
 function [7:0] clip11(input signed [10:0] v);begin if(v<0) clip11=8'd0;else if(v>11'sd255) clip11=8'd255;else clip11=v[7:0];end endfunction
 function [23:0] enhance(input [23:0] c);
  reg [9:0] ysum;reg [7:0] y0,y;reg signed [8:0] dr,dg,db;reg signed [10:0] vr,vg,vb;
  begin
   ysum={2'b0,c[23:16]}+{1'b0,c[15:8],1'b0}+{2'b0,c[7:0]};
   y0=ysum[9:2];y=(y0>8'd192)?(8'd192+((y0-8'd192)>>1)):y0;
   dr=$signed({1'b0,c[23:16]})-$signed({1'b0,y0});
   dg=$signed({1'b0,c[15:8]})-$signed({1'b0,y0});
   db=$signed({1'b0,c[7:0]})-$signed({1'b0,y0});
   vr=$signed({3'b0,y})+$signed({{2{dr[8]}},dr})+$signed({{2{dr[8]}},(dr>>>1)});
   vg=$signed({3'b0,y})+$signed({{2{dg[8]}},dg})+$signed({{2{dg[8]}},(dg>>>1)});
   vb=$signed({3'b0,y})+$signed({{2{db[8]}},db})+$signed({{2{db[8]}},(db>>>1)});
   enhance={clip11(vr),clip11(vg),clip11(vb)};
  end
 endfunction
 function [23:0] dimcolor(input [23:0] c);begin dimcolor={2'b0,c[23:18],2'b0,c[15:10],2'b0,c[7:2]};end endfunction

 // Capture stream.
 always @(posedge clk) begin
  if(out_valid) begin
   if(cap_count<MAX_WORDS) begin
    cap_data[cap_count]=out_data;
    cap_user_v[cap_count]=out_user;
    cap_last_v[cap_count]=out_last;
   end
   cap_count=cap_count+1;
   if(out_user) cap_user=cap_user+1;
   if(out_last) cap_last=cap_last+1;
  end
 end

 task drive_line(input integer y,input integer frame);begin
  for(beat=0;beat<BEATS;beat=beat+1) begin
   @(negedge clk);
   valid=1;user=(y==0&&beat==0);last=(beat==BEATS-1);
   cellno=beat/CELL_BEATS;
   band=y/16;
   block=band*CELLS+cellno;
   if(frame==0) begin
    case(block)
     0:begin target=0;solid=24'h000000;end
     1:begin target=1;solid=24'h101010;end
     2:begin target=2;solid=24'h202020;end
     3:begin target=3;solid=24'h383838;end
     4:begin target=4;solid=24'h505050;end
     5:begin target=5;solid=24'h686868;end
     6:begin target=6;solid=24'h888888;end
     default:begin target=7;solid=24'ha8a8a8;end
    endcase
    data={solid,solid};
   end else begin
    case(block)
     0:begin target=8;solid=24'hc8d2dc;end
     1:begin target=9;solid=24'hf0f0f0;end
     2:begin target=0;solid=24'h000000;end
     3:begin target=1;solid=24'h101010;end
     4:begin target=2;solid=24'h202020;end
     5:begin target=3;solid=24'h383838;end
     6:begin target=4;solid=24'h505050;end
     default:begin target=3;solid=24'h7f007f;data={24'hff0000,24'h0000ff};end
    endcase
    if(block!=7) data={solid,solid};
   end
  end
  @(negedge clk);valid=0;user=0;last=0;
  for(beat=0;beat<LINE_PERIOD-BEATS;beat=beat+1) @(negedge clk);
 end endtask

 task run_frame(input integer frame);begin
  rst=0;valid=0;user=0;last=0;data=0;cap_count=0;cap_user=0;cap_last=0;
  repeat(5) @(negedge clk);rst=1;repeat(3) @(negedge clk);
  for(row=0;row<H;row=row+1) drive_line(row,frame);
  for(beat=0;beat<5000 && cap_count<FRAME_WORDS;beat=beat+1) @(negedge clk);
  repeat(40) @(negedge clk);
 end endtask

 task check_frame(input integer frame);integer n,line_no,beat_no,cell_no,band_no,block_no,wbeat,rowg,lane,bitpos;reg [7:0] g,gr;reg [23:0] fg,bg;reg expbit;begin
  if(cap_count!==FRAME_WORDS) begin $display("FAIL frame %0d count %0d want %0d",frame,cap_count,FRAME_WORDS);errors=errors+1;end
  if(cap_user!==1) begin $display("FAIL frame %0d user count %0d",frame,cap_user);errors=errors+1;end
  if(cap_last!==H) begin $display("FAIL frame %0d last count %0d",frame,cap_last);errors=errors+1;end
  for(n=0;n<FRAME_WORDS;n=n+1) begin
   line_no=n/BEATS;
   beat_no=n%BEATS;
   band_no=line_no/16;
   cell_no=beat_no/CELL_BEATS;
   block_no=band_no*CELLS+cell_no;
   wbeat=beat_no%CELL_BEATS;
   rowg=line_no%16;
   if(cap_user_v[n] !== (n==0)) begin $display("FAIL user at %0d",n);errors=errors+1;end
   if(cap_last_v[n] !== ((n%BEATS)==BEATS-1)) begin $display("FAIL last at %0d",n);errors=errors+1;end
   if(frame==0) begin
    case(block_no)
     0:begin g=8'h00;end 1:begin g=8'h10;end 2:begin g=8'h20;end 3:begin g=8'h38;end
     4:begin g=8'h50;end 5:begin g=8'h68;end 6:begin g=8'h88;end default:begin g=8'ha8;end
    endcase
    fg=enhance({g,g,g});bg=dimcolor(fg);
   end else begin
    case(block_no)
     0:begin g=8'hc8;fg=enhance(24'hc8d2dc);bg=dimcolor(fg);end
     1:begin g=8'hf0;fg=enhance({g,g,g});bg=dimcolor(fg);end
     2:begin g=8'h00;fg=enhance({g,g,g});bg=dimcolor(fg);end
     3:begin g=8'h10;fg=enhance({g,g,g});bg=dimcolor(fg);end
     4:begin g=8'h20;fg=enhance({g,g,g});bg=dimcolor(fg);end
     5:begin g=8'h38;fg=enhance({g,g,g});bg=dimcolor(fg);end
     6:begin g=8'h50;fg=enhance({g,g,g});bg=dimcolor(fg);end
     default:begin fg=enhance(24'h7f007f);bg=dimcolor(fg);end
    endcase
   end
   for(lane=0;lane<2;lane=lane+1) begin
    bitpos=15-wbeat*2-lane;
    gr=glyph8(exp_char[block_no],rowg);
    if(bitpos<4 || bitpos>11) expbit=0; else expbit=gr[bitpos-4];
    if(cap_data[n][47-lane*24 -:24] !== (expbit?fg:bg)) begin
     if(errors<12) $display("FAIL frame %0d n %0d block %0d row %0d within %0d lane %0d got %06h want %06h char %0d",frame,n,block_no,rowg,wbeat,lane,cap_data[n][47-lane*24 -:24],expbit?fg:bg,exp_char[block_no]);
     errors=errors+1;
    end
   end
  end
 end endtask

 initial begin
  exp_char[0]=0;exp_char[1]=1;exp_char[2]=2;exp_char[3]=3;exp_char[4]=4;exp_char[5]=5;exp_char[6]=6;exp_char[7]=7;
  run_frame(0);check_frame(0);
  exp_char[0]=8;exp_char[1]=9;exp_char[2]=0;exp_char[3]=1;exp_char[4]=2;exp_char[5]=3;exp_char[6]=4;exp_char[7]=3;
  run_frame(1);check_frame(1);
  if(errors==0) begin $display("ASCII_ART_PASS words=%0d chars=10 bands=4 mixed_color=1",FRAME_WORDS*2);test_passed=1;end
  else begin $display("ASCII_ART_FAIL errors=%0d",errors);test_passed=0;end
  $finish;
 end
 initial begin #200000;$fatal(1,"ASCII timeout");end
endmodule
