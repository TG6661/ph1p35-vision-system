// Complete line prefetch before output. At most 16 ordered reads in flight.
// Output rows start no faster than LINE_PERIOD, preserving PIX ping-pong banks.
// Shared DDR reset only; a mode change stops new frames and drains this one.
module final1_line_replay #(parameter WIDTH=1280,HEIGHT=720,LINE_PERIOD=1024,PIXELS=4)(
 input clk,rst_n,enable,frame_valid,input [31:0] frame_sequence,
 input [1:0] bank,input [50:0] tag,input [18:0] generation,
 input sink_frame_ready,post_done,
 output reg [1:0] locked_bank,output reg frame_start,
 output reg [50:0] active_tag,output idle,
 output rd_en,output [24:0] address,input bus_ready,rd_valid,input [127:0] rd_data,
 output [PIXELS*24-1:0] rgb,output valid,user,last,output reg error
);
 localparam WORDS=WIDTH*3/16,BEATS=WIDTH/PIXELS;
 localparam IDLE=0,READ=1,LOAD=2,FEED=3,DRAIN=4,WAIT_POST=5;
 reg [2:0] state;
 localparam LINE_ADDR_BITS=(WORDS>1)?$clog2(WORDS):1;
 wire [127:0] q;
 reg [9:0] issued,returned,index;
 reg [10:0] row;
 reg [15:0] timer;
 reg [31:0] last_sequence;
 reg [24:0] base;
 wire unpack_ready;
 assign idle=state==IDLE;
 assign rd_en=state==READ && issued<WORDS && (issued-returned)<16 && bus_ready;
 assign address=base+((row*WORDS+issued)<<3);
 wire feed=state==FEED && unpack_ready;
 reg [10:0] pair_x;
 reg [2:0] pair_phase;
 generate if(PIXELS==4) begin:g_four
 rgb_unpack96 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) u_unpack(
  .clk(clk),.rst_n(rst_n),.s_data(q),.s_valid(state==FEED),.s_ready(unpack_ready),
  .m_data(rgb),.m_valid(valid),.m_user(user),.m_last(last));
 end else begin:g_two
 // Synchronous row RAM is prefetched two cycles before the next word is used.
 // 3 words -> 8 pairs, with an uninterrupted 640-cycle row at 1280 pixels.
 reg [127:0] holding;
 reg [47:0] data_q;
 reg valid_q,user_q,last_q;
 assign rgb=data_q;assign valid=valid_q;assign user=user_q;assign last=last_q;
 assign unpack_ready=1'b1;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin holding<=0;data_q<=0;valid_q<=0;user_q<=0;last_q<=0;end
  else begin
   valid_q<=state==FEED;user_q<=state==FEED && row==0 && pair_x==0;
   last_q<=state==FEED && pair_x==BEATS-1;
   if(state==FEED) begin
    if(pair_phase==0 || pair_phase==2 || pair_phase==5) holding<=q;
    case(pair_phase)
     0:data_q<=q[127:80];
     1:data_q<=holding[79:32];
     2:data_q<={holding[31:0],q[127:112]};
     3:data_q<=holding[111:64];
     4:data_q<=holding[63:16];
     5:data_q<={holding[15:0],q[127:96]};
     6:data_q<=holding[95:48];
     7:data_q<=holding[47:0];
    endcase
   end
  end
 end
 end endgenerate
 // Explicit device ERAM: NOREG still has one synchronous read cycle.
 // READ fills the entire row before LOAD/FEED consumes it, so read/write
 // collisions are never observed as valid pixels. Keep the original latency.
 isp_line_ram #(
  .DATA_WIDTH_A(128),.DATA_WIDTH_B(128),
  .ADDR_WIDTH_A(LINE_ADDR_BITS),.ADDR_WIDTH_B(LINE_ADDR_BITS),
  .DATA_DEPTH_A(1<<LINE_ADDR_BITS),.DATA_DEPTH_B(1<<LINE_ADDR_BITS),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
  .WRITEMODE_A("NORMAL"),.WRITEMODE_B("READBEFOREWRITE")
 ) u_line_eram(
  .clka(clk),.wea(rd_valid && state==READ && returned<WORDS),
  .addra(returned[LINE_ADDR_BITS-1:0]),.dia(rd_data),.doa(),
  .clkb(clk),.web(1'b0),.addrb(index[LINE_ADDR_BITS-1:0]),
  .dib(128'd0),.dob(q)
 );
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=IDLE;issued<=0;returned<=0;index<=0;row<=0;timer<=0;pair_x<=0;pair_phase<=0;
   last_sequence<=0;base<=0;locked_bank<=0;frame_start<=0;active_tag<=0;error<=0;
  end else begin
   frame_start<=0;
   if(timer!=0) timer<=timer-1'b1;
   if(rd_en) issued<=issued+1'b1;
   if(rd_valid) begin
    if(state==READ && returned<issued) returned<=returned+1'b1;
    else error<=1;
   end
   case(state)
    IDLE:if(enable && frame_valid && frame_sequence!=last_sequence && tag[50:32]==generation && sink_frame_ready) begin
     last_sequence<=frame_sequence;locked_bank<=bank;active_tag<=tag;frame_start<=1;
     case(bank)
      0:base<=3500000;1:base<=10500000;2:base<=17500000;3:base<=24500000;
     endcase
     row<=0;issued<=0;returned<=0;index<=0;state<=READ;
     // Preserve the minimum row-start period across adjacent two-pixel frames.
     if(PIXELS==4) timer<=0;
    end
    READ:if(returned==WORDS && timer==0) begin index<=0;pair_x<=0;pair_phase<=0;timer<=LINE_PERIOD-1;state<=LOAD;end
    LOAD:state<=FEED;
    FEED:if(feed) begin
     if(PIXELS==2) begin
      pair_x<=pair_x+1'b1;pair_phase<=pair_phase+1'b1;
      if((pair_phase==0 || pair_phase==2 || pair_phase==5) && index<WORDS-1) index<=index+1'b1;
      if(pair_x==BEATS-1) state<=DRAIN;
     end else begin
      if(index==WORDS-1) state<=DRAIN;
      else begin index<=index+1'b1;state<=LOAD;end
     end
    end
    DRAIN:if(valid && last) begin
     if(row==HEIGHT-1) state<=WAIT_POST;
     else begin row<=row+1'b1;issued<=0;returned<=0;index<=0;state<=READ;end
    end
    WAIT_POST:if(post_done) state<=IDLE;
    default:state<=IDLE;
   endcase
  end
 end
endmodule
