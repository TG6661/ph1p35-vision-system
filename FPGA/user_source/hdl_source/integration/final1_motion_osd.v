// Final1 UI / boxes plus teammate live ping-pong green veil, with one pixel
// register stage for synchronous mask RAM. The detector retains its +4 Y shift.
module final1_motion_osd(
 input clk,rst_n,input [23:0] rgb,input de,hs,vs,
 input [31:0] ui,input [127:0] boxes,input [3:0] box_valid,input [1:0] mode,input running,
 input mask_data,mask_wr_buf,mask_enable,input signed [7:0] mask_y_offset,
 output [14:0] mask_rd_addr,
 output [23:0] out_rgb,output out_de,out_hs,out_vs
);
 reg [10:0] x;reg [9:0] y;reg de_d,vs_d;
 always @(posedge clk or negedge rst_n)
  if(!rst_n) begin x<=0;y<=0;de_d<=0;vs_d<=0;end
  else begin
   de_d<=de;vs_d<=vs;
   if(vs && !vs_d) begin x<=0;y<=0;end
   else if(de) x<=x+1'b1;
   else if(de_d) begin x<=0;y<=y+1'b1;end
  end
 wire [3:0] hit;
 genvar i;
 generate for(i=0;i<4;i=i+1) begin:g_box
  wire [31:0] b=boxes[i*32+:32];
  // Box endpoints are whole 8x8 blocks. The two-pixel border is exactly
  // subpixel 0/1 on the first block or 6/7 on the last block. Keep the
  // surrounding range/legality tests, including reversed/out-of-range boxes.
  assign hit[i]=de && box_valid[i] && b[31:30]==0 && b[29:22]<=b[21:14] && b[21:14]<160 &&
   b[13:7]<=b[6:0] && b[6:0]<90 &&
   x[10:3]>=b[29:22] && x[10:3]<=b[21:14] && y[9:3]>=b[13:7] && y[9:3]<=b[6:0] &&
   ((x[10:3]==b[29:22] && x[2:1]==2'b00) ||
    (x[10:3]==b[21:14] && x[2:1]==2'b11) ||
    (y[9:3]==b[13:7] && y[2:1]==2'b00) ||
    (y[9:3]==b[6:0] && y[2:1]==2'b11));
 end endgenerate
 // Compact always-visible mode indicator: R / M / S, grey while switching.
 reg [7:0] glyph;
 always @* begin
  glyph=0;
  if(mode==0) case(y[3:1])
   0:glyph=8'h7c;1:glyph=8'h42;2:glyph=8'h42;3:glyph=8'h7c;4:glyph=8'h48;5:glyph=8'h44;6:glyph=8'h42;default:;
  endcase
  else if(mode==1) case(y[3:1])
   0:glyph=8'h42;1:glyph=8'h66;2:glyph=8'h5a;3:glyph=8'h5a;4:glyph=8'h42;5:glyph=8'h42;6:glyph=8'h42;default:;
  endcase
  else case(y[3:1])
   0:glyph=8'h3c;1:glyph=8'h42;2:glyph=8'h40;3:glyph=8'h3c;4:glyph=8'h02;5:glyph=8'h42;6:glyph=8'h3c;default:;
  endcase
 end
 // Teammate bank synchronization / live offset. No VS ownership handshake added.
 reg [2:0] mask_bank_sync;
 always @(posedge clk or negedge rst_n)
  if(!rst_n) mask_bank_sync<=0;else mask_bank_sync<={mask_bank_sync[1:0],mask_wr_buf};
 wire [7:0] mask_bx=x[10:3];
 wire [6:0] mask_by_raw=y[9:3];
 wire signed [7:0] mask_by_signed=$signed({1'b0,mask_by_raw})-mask_y_offset;
 wire mask_y_valid=mask_by_signed>=8'sd0 && mask_by_signed<8'sd90;
 wire [6:0] mask_by=mask_y_valid?mask_by_signed[6:0]:7'd0;
 wire [13:0] mask_block_addr={mask_by,7'b0}+{mask_by,5'b0}+{6'd0,mask_bx};
 assign mask_rd_addr={~mask_bank_sync[2],mask_block_addr};
 wire badge=de && x>=1248 && x<1264 && y<16 && glyph[7-x[3:1]];
 wire ui_zone=de && x>=1056 && x<1216 && y>=24 && y<34 && ui[27:24]!=0;
 reg [7:0] code;reg [31:0] label;
 always @* begin
  label="MODE";
  if(ui[27:24]==1 && ui[23:20]==1) label="AUTO";
  if(ui[27:24]==2) case(ui[23:20])
   0:label="DIFF";1:label="NEIG";2:label="MIN ";3:label="HOLD";4:label="YOFF";5:label="DWEL";default:label="    ";
  endcase
  if(ui[27:24]==3) case(ui[23:20])
   0:label="FX  ";1:label="CL  ";default:label="    ";
  endcase
  code=" ";
  case((x-1056)>>3)
   0:code="P";1:code="0"+ui[27:24];3:code=label[31:24];4:code=label[23:16];
   5:code=label[15:8];6:code=label[7:0];7:code=ui[16]?"-":" ";8:code="0"+ui[15:12];9:code="0"+ui[11:8];
   10:code="0"+ui[7:4];11:code="0"+ui[3:0];default:;
  endcase
 end
 wire ui_ink;
 target_osd_font u_font(.code(code),.row((y-24)>>1),.col(x[2:1]),.pixel(ui_ink));
 reg [23:0] rgb_d,annotation_rgb;
 reg de_d1,hs_d1,vs_d1,annotation_d,mask_allowed_d;
 always @(posedge clk or negedge rst_n)
  if(!rst_n) begin rgb_d<=0;annotation_rgb<=0;de_d1<=0;hs_d1<=0;vs_d1<=0;annotation_d<=0;mask_allowed_d<=0;end
  else begin
   rgb_d<=rgb;de_d1<=de;hs_d1<=hs;vs_d1<=vs;
   annotation_d<=(ui_zone && ui_ink) || badge || (|hit);
   annotation_rgb<=(ui_zone && ui_ink)?24'hffff00:badge?(running?24'hffffff:24'h808080):24'hff0000;
   mask_allowed_d<=de && mode==1 && running && mask_enable && mask_y_valid;
  end
 wire [7:0] green=(rgb_d[15:8]>>1)+8'd128;
 wire [23:0] veil={1'b0,rgb_d[23:17],green,1'b0,rgb_d[7:1]};
 assign out_rgb=annotation_d?annotation_rgb:(mask_allowed_d && mask_data)?veil:rgb_d;
 assign out_de=de_d1;assign out_hs=hs_d1;assign out_vs=vs_d1;
endmodule
