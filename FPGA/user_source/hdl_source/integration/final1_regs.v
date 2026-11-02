// Unified v6 extension. Addresses are absolute byte offsets in Fabric window.
// Snapshot acquire copies latest into a CPU-owned bank until explicit release.
module final1_regs #(parameter READ_DECODE_REGISTERED=0)(
 input clk,rst_n,write,input [8:0] write_word,read_word,input [31:0] wdata,
 output reg [31:0] rdata,output reg [31:0] ui_data,
 output reg motion_bg_reset,output reg motion_mask_enable,
 output reg signed [7:0] motion_y_offset,output reg [7:0] motion_dwell_limit,
 output reg cfg_send,output reg [95:0] cfg_data,input cfg_ready,cfg_done,
 input [31:0] cfg_applied,input [7:0] faults,
 input camera_diag_valid,input [63:0] camera_diag,
 input post_diag_valid,input [127:0] post_diag,
 input motion_valid,input [223:0] motion_data,
 input awb_valid,input [255:0] awb_data,
 output reg result_send,output reg [223:0] result_data,input result_ready,
 output reg gain_send,output reg [103:0] gain_data,input gain_ready
);
 localparam [31:0] NORMAL=32'd131072; // GG=256, RED, FIXED, LSC/FX/CL off
 localparam [31:0] MOTION_DEFAULT=(20 | (3<<8) | (5<<11) | (10<<17));
 reg [63:0] camera_status;reg [127:0] post_status;
 // Keep complete shadows for invalid-write readback. Accepted generations
 // saturate at 0x7ffff; only successfully committed active fields need storage.
 reg [31:0] config_shadow,motion_shadow,applied;
 reg [18:0] accepted;
 reg [18:0] active_config; // bit18 is FX[2]; existing low fields are unchanged.
 wire [18:0] accepted_next=accepted+19'd1;
 reg busy,rejected;
 reg [223:0] motion_latest,motion_snapshot;
 // Reserved result bits are not readable. Retain their nonzero predicate
 // for rejection, rather than 28 data bits that can never be committed.
 reg [63:0] result_header;
 reg [131:0] result_body;
 reg result_reserved_nonzero;
 wire [223:0] result_shadow={result_header,28'd0,result_body};
 reg [255:0] awb_latest,awb_snapshot;
 reg [31:0] motion_seq,motion_frozen_seq,awb_seq,awb_frozen_seq;
 reg motion_locked,awb_locked;
 // Gain shadows are write-only. Values above 18 bits are all illegal; keep
 // one predicate per word so arbitrary invalid writes still reject exactly.
 reg [17:0] gain_r,gain_b;
 reg gain_r_high,gain_b_high;
 reg [31:0] gain_gen,gain_sequence;
 reg [4:0] motion_bg_reset_count;
 wire [10:0] wa={write_word,2'b00},ra={read_word,2'b00};
 // Cache small predicates on the SAME edge as each full shadow write.
 // A following commit sees the new checks even for consecutive writes.
 // Do not truncate invalid shadows: software may read them before rejection.
 reg [4:0] config_checks;
 reg [2:0] motion_checks;
 wire legal=(&config_checks) && (&motion_checks);
 // Exact unsigned modulo-2^32 age test, without a variable 32-bit subtract.
 // A low-nibble borrow is valid only when the upper epoch advanced by one.
 // The 28-bit increment intentionally wraps, including ffffffff -> 00000000.
 // Both operands remain live; do not cache this against a changing snapshot.
 function frame_age_lt16;
  input [31:0] newest,submitted;
  reg [27:0] next_epoch;
  begin
   next_epoch=submitted[31:4]+28'd1;
   frame_age_lt16=((newest[31:4]==submitted[31:4]) && (newest[3:0]>=submitted[3:0])) ||
                  ((newest[31:4]==next_epoch) && (newest[3:0]<submitted[3:0]));
  end
 endfunction
 integer i;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   camera_status<=0;post_status<=0;ui_data<=0;config_shadow<=NORMAL;motion_shadow<=MOTION_DEFAULT;accepted<=0;applied<=0;active_config<=NORMAL;
   cfg_send<=0;cfg_data<=0;busy<=0;rejected<=0;
   config_checks<=5'b11111;motion_checks<=3'b111;
   motion_latest<=0;motion_snapshot<=0;motion_seq<=0;motion_frozen_seq<=0;motion_locked<=0;
   awb_latest<=0;awb_snapshot<=0;awb_seq<=0;awb_frozen_seq<=0;awb_locked<=0;
   result_header<=0;result_body<=0;result_reserved_nonzero<=0;result_send<=0;result_data<=0;
   gain_r<=95907;gain_b<=100825;gain_r_high<=0;gain_b_high<=0;
   gain_gen<=0;gain_sequence<=0;gain_send<=0;gain_data<=0;
   motion_bg_reset<=0;motion_bg_reset_count<=0;motion_mask_enable<=1;motion_y_offset<=0;motion_dwell_limit<=20;
  end else begin
   cfg_send<=0;result_send<=0;gain_send<=0;
   // Teammate live controls and pulse stretcher, intentionally not part of cfg CDC.
   if(motion_bg_reset_count!=0) begin motion_bg_reset_count<=motion_bg_reset_count-1'b1;motion_bg_reset<=1;end
   else motion_bg_reset<=0;
   if(camera_diag_valid) camera_status<=camera_diag;
   if(post_diag_valid) post_status<=post_diag;
   if(cfg_done) begin busy<=0;applied<=cfg_applied;active_config<=cfg_data[18:0];end
   if(motion_valid) begin motion_latest<=motion_data;motion_seq<=motion_seq+1'b1;end
   if(awb_valid) begin awb_latest<=awb_data;awb_seq<=awb_seq+1'b1;end
   if(write) begin
    case(wa)
     'h188:begin
      config_shadow<=wdata;
      config_checks[0]<=wdata[31:19]==0 && (!wdata[18] || (wdata[1:0]==2'd2 && wdata[5:4]<=2'd1)); // FX4/5 only in STYLE; reject FX6/7.
      config_checks[1]<=wdata[1:0]!=2'd3;
      config_checks[2]<=wdata[7:6]!=2'd3;
      config_checks[3]<=wdata[1:0]==2'd2 ? wdata[17:9]==9'd224 : wdata[17:9]>=9'd128; // STYLE GG fixed; other modes unchanged.
      config_checks[4]<=(wdata[1:0]==2'd2 && wdata[3:2]==2'd0) || (wdata[7:2]==0 && wdata[17:9]==9'd256);
     end
     'h18c:begin
      if(wdata==4) rejected<=0;
      else if(wdata==1) begin
       if(!busy && cfg_ready && !cfg_send && legal && accepted!=19'h7ffff) begin
        // Constant reserved fields propagate through the unchanged 96-bit CDC ABI.
        accepted<=accepted_next;
        cfg_data<={13'd0,accepted_next,10'd0,motion_shadow[21:0],13'd0,config_shadow[18:0]};
        cfg_send<=1;busy<=1;
       end else rejected<=1;
      end else rejected<=1;
     end
     'h1a8:begin
      motion_shadow<=wdata;
      motion_checks[0]<=wdata[31:22]==0;
      motion_checks[1]<=wdata[10:8]!=0;
      motion_checks[2]<=wdata[16:11]!=0;
     end
     'h1ac:begin
      if(wdata[2]) motion_bg_reset_count<=16;
      motion_mask_enable<=wdata[3];motion_y_offset<=wdata[15:8];
      if(wdata[23:16]!=0) motion_dwell_limit<=wdata[23:16];
     end
     'h1b0:ui_data<=wdata;
     'h220:begin
      if(wdata==1 && !motion_locked) begin motion_snapshot<=motion_latest;motion_frozen_seq<=motion_seq;motion_locked<=1;end
      else if(wdata==2) motion_locked<=0;
      else rejected<=1;
     end
     'h280:result_header[63:32]<=wdata;
     'h284:result_header[31:0]<=wdata;
     'h288:begin result_body[131:128]<=wdata[3:0];result_reserved_nonzero<=|wdata[31:4];end
     'h28c:result_body[31:0]<=wdata;
     'h290:result_body[63:32]<=wdata;
     'h294:result_body[95:64]<=wdata;
     'h298:result_body[127:96]<=wdata;
     'h29c:begin
      // Capture an idle commit attempt independently of frame/generation
      // validation. A rejected attempt may change only unconsumed staging data.
      // !result_send freezes the payload before ready falls on the next edge;
      // !result_ready then preserves EXTERNAL_HOLD data until the ACK returns.
      if(wdata==1 && result_ready && !result_send) result_data<=result_shadow;
      if(wdata==1 && !busy && active_config[1:0]==1 && result_ready && !result_send &&
       result_shadow[223:192]==applied && !result_reserved_nonzero &&
       motion_latest[223:192]==applied &&
       frame_age_lt16(motion_latest[191:160],result_shadow[191:160])) begin
       result_send<=1;
      end else rejected<=1;
     end
     'h420:begin
      if(wdata==1 && !awb_locked) begin awb_snapshot<=awb_latest;awb_frozen_seq<=awb_seq;awb_locked<=1;end
      else if(wdata==2) awb_locked<=0;
      else rejected<=1;
     end
     'h440:begin gain_r<=wdata[17:0];gain_r_high<=|wdata[31:18];end
     'h444:begin gain_b<=wdata[17:0];gain_b_high<=|wdata[31:18];end
     'h448:gain_gen<=wdata;
     'h44c:gain_sequence<=wdata;
     'h450:begin
      if(wdata==1 && !busy && active_config[8] && gain_ready && !gain_send && gain_gen==applied &&
       !gain_r_high && !gain_b_high &&
       gain_r>=18'd32768 && gain_r<=18'd229376 && gain_b>=18'd32768 && gain_b<=18'd229376 &&
       awb_latest[255:224]==applied && frame_age_lt16(awb_latest[159:128],gain_sequence)) begin
       gain_data<={gain_gen,gain_sequence,2'd0,gain_b,2'd0,gain_r};gain_send<=1;
      end else rejected<=1;
     end
     default:;
    endcase
   end
  end
 end
 // Factor the read mux into five local word banks and four single words.
 // Each bank keeps a local index only when addressed: no global 36-way
 // one-hot data mask, and no extra data pipeline or stale-status snapshot.
 // Registered mode still delays ONLY the address by exactly one clock.
 wire [8:0] read_bank_decode;
 reg [8:0] read_bank_q;
 reg [2:0] config_word_q,control_word_q,diag_word_q,motion_word_q,awb_word_q;
 assign read_bank_decode[0]=(ra[10:5]==6'h0c); // 0x180..0x19c
 assign read_bank_decode[1]=(ra[10:5]==6'h0d); // 0x1a0..0x1bc
 assign read_bank_decode[2]=(ra[10:5]==6'h0e); // 0x1c0..0x1dc
 assign read_bank_decode[3]=(ra[10:5]==6'h10); // 0x200..0x21c
 assign read_bank_decode[4]=(ra[10:5]==6'h20); // 0x400..0x41c
 assign read_bank_decode[5]=(ra==11'h220);
 assign read_bank_decode[6]=(ra==11'h2a0);
 assign read_bank_decode[7]=(ra==11'h420);
 assign read_bank_decode[8]=(ra==11'h454);
 generate if(READ_DECODE_REGISTERED) begin:g_read_decode
  always @(posedge clk or negedge rst_n)
   if(!rst_n) begin
    read_bank_q<=0;config_word_q<=0;control_word_q<=0;
    diag_word_q<=0;motion_word_q<=0;awb_word_q<=0;
   end else begin
    read_bank_q<=read_bank_decode;
    if(read_bank_decode[0]) config_word_q<=ra[4:2];
    if(read_bank_decode[1]) control_word_q<=ra[4:2];
    if(read_bank_decode[2]) diag_word_q<=ra[4:2];
    if(read_bank_decode[3]) motion_word_q<=ra[4:2];
    if(read_bank_decode[4]) awb_word_q<=ra[4:2];
   end
 end else begin:g_read_comb
  always @* begin
   read_bank_q=read_bank_decode;
   config_word_q=ra[4:2];control_word_q=ra[4:2];diag_word_q=ra[4:2];
   motion_word_q=ra[4:2];awb_word_q=ra[4:2];
  end
 end endgenerate
 // Local word decoding is combinational; no new state or read latency.
 // Explicit masked terms expose a balanced AND/OR network to synthesis.
 // Physical F7/Slice reduction must still be checked in the next TD run.
 function [7:0] decode_local_word;
  input [2:0] word_index;
  begin
   case(word_index)
    3'd0:decode_local_word=8'b00000001;
    3'd1:decode_local_word=8'b00000010;
    3'd2:decode_local_word=8'b00000100;
    3'd3:decode_local_word=8'b00001000;
    3'd4:decode_local_word=8'b00010000;
    3'd5:decode_local_word=8'b00100000;
    3'd6:decode_local_word=8'b01000000;
    3'd7:decode_local_word=8'b10000000;
    default:decode_local_word=8'd0;
   endcase
  end
 endfunction
 wire [7:0] config_word_sel=decode_local_word(config_word_q);
 wire [31:0] read_config=
  ({32{config_word_sel[0]}} & 32'h00010001) |
  ({32{config_word_sel[1]}} & 32'h000070ff) | // bit14: OFF/PATROL HUD; bit13: fixed GG224/576, no LSC; bit12: ASCII; bit7: HUD v2
  ({32{config_word_sel[2]}} & config_shadow) |
  ({32{config_word_sel[4]}} & {22'd0,faults,rejected,busy}) |
  ({32{config_word_sel[5]}} & {13'd0,accepted}) |
  ({32{config_word_sel[6]}} & applied) |
  ({32{config_word_sel[7]}} & {13'd0,active_config});
 wire [7:0] control_word_sel=decode_local_word(control_word_q);
 wire [31:0] read_control=
  ({32{control_word_sel[0]}} & applied) |
  ({32{control_word_sel[2]}} & motion_shadow) |
  ({32{control_word_sel[3]}} & {8'd0,motion_dwell_limit,motion_y_offset,4'd0,motion_mask_enable,motion_bg_reset,2'd0});
 wire [7:0] diag_word_sel=decode_local_word(diag_word_q);
 wire [31:0] read_diag=
  ({32{diag_word_sel[0]}} & camera_status[31:0]) |
  ({32{diag_word_sel[1]}} & camera_status[63:32]) |
  ({32{diag_word_sel[2]}} & post_status[95:64]) |
  ({32{diag_word_sel[3]}} & post_status[127:96]) |
  ({32{diag_word_sel[4]}} & post_status[63:32]) |
  ({32{diag_word_sel[5]}} & post_status[31:0]);
 wire [7:0] motion_word_sel=decode_local_word(motion_word_q);
 wire [31:0] read_motion=
  ({32{motion_word_sel[0]}} & motion_frozen_seq) |
  ({32{motion_word_sel[1]}} & motion_snapshot[223:192]) |
  ({32{motion_word_sel[2]}} & motion_snapshot[191:160]) |
  ({32{motion_word_sel[3]}} & motion_snapshot[159:128]) |
  ({32{motion_word_sel[4]}} & motion_snapshot[31:0]) |
  ({32{motion_word_sel[5]}} & motion_snapshot[63:32]) |
  ({32{motion_word_sel[6]}} & motion_snapshot[95:64]) |
  ({32{motion_word_sel[7]}} & motion_snapshot[127:96]);
 wire [7:0] awb_word_sel=decode_local_word(awb_word_q);
 wire [31:0] read_awb=
  ({32{awb_word_sel[0]}} & awb_frozen_seq) |
  ({32{awb_word_sel[1]}} & awb_snapshot[255:224]) |
  ({32{awb_word_sel[2]}} & awb_snapshot[223:192]) |
  ({32{awb_word_sel[3]}} & awb_snapshot[31:0]) |
  ({32{awb_word_sel[4]}} & awb_snapshot[63:32]) |
  ({32{awb_word_sel[5]}} & awb_snapshot[95:64]) |
  ({32{awb_word_sel[6]}} & awb_snapshot[127:96]) |
  ({32{awb_word_sel[7]}} & awb_snapshot[159:128]);
 always @* begin
  rdata=({32{read_bank_q[0]}} & read_config) |
        ({32{read_bank_q[1]}} & read_control) |
        ({32{read_bank_q[2]}} & read_diag) |
        ({32{read_bank_q[3]}} & read_motion) |
        ({32{read_bank_q[4]}} & read_awb) |
        ({32{read_bank_q[5]}} & {30'd0,(motion_seq!=0),motion_locked}) |
        ({32{read_bank_q[6]}} & {31'd0,!result_ready || result_send}) |
        ({32{read_bank_q[7]}} & {30'd0,(awb_seq!=0),awb_locked}) |
        ({32{read_bank_q[8]}} & {31'd0,!gain_ready || gain_send});
 end
endmodule
