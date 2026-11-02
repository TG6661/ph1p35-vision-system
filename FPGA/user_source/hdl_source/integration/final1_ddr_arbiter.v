// Three registered burst writers, HDMI and three bounded read clients.
// Mode changes never clear owner tags or outstanding transactions.
module final1_ddr_arbiter(
 input clk,rst_n,
 input cap_busy,cap_wr,input [24:0] cap_addr,input [127:0] cap_data,output cap_ready,
 input linear_busy,linear_wr,input [24:0] linear_addr,input [127:0] linear_data,output linear_ready,
 input view_busy,view_wr,input [24:0] view_addr,input [127:0] view_data,output view_ready,
 input display_busy,display_rd,input [24:0] display_addr,output display_ready,display_valid,
 input tf_rd,tf_wr,input [24:0] tf_addr,input [127:0] tf_data,output tf_ready,tf_valid,
 input linear_rd,input [24:0] linear_rd_addr,output linear_rd_ready,linear_rd_valid,
 input mask_request,mask_wr,mask_rd,input [24:0] mask_addr,input [127:0] mask_data,
 output mask_ready,mask_valid,input ready,rd_valid,
 output wr_en,rd_en,output [24:0] address,output [127:0] wr_data,
 output reg error,output [10:0] outstanding
);
 reg [2:0] turn,grant;
 reg [1:0] writer; // 0 red, 1 final, 2 linear, 3 none
 reg [9:0] head,tail;
 reg [10:0] pending;
 // Prefetch the head that will be current AFTER this clock. The return
 // decoder therefore keeps the original same-cycle rd_valid interface.
 wire pop_owner=rd_valid && pending!=0;
 wire [9:0] owner_read_address=head+pop_owner;
 wire [1:0] owner_write_data=linear_rd?2'd3:mask_rd?2'd2:tf_rd?2'd1:2'd0;
 wire [1:0] owner_ram_data;
 reg owner_bypass;
 reg [1:0] owner_bypass_data;
 wire [1:0] owner_head=owner_bypass?owner_bypass_data:owner_ram_data;
 // A new head may be written on the same edge (empty or one-item queue).
 // Explicit forwarding makes that case independent of ERAM collision mode.
 always @(posedge clk or negedge rst_n)
  if(!rst_n) begin owner_bypass<=0;owner_bypass_data<=0;end
  else begin
   owner_bypass<=rd_en && tail==owner_read_address;
   owner_bypass_data<=owner_write_data;
  end
 isp_line_ram #(.DATA_WIDTH_A(2),.DATA_WIDTH_B(2),
  .ADDR_WIDTH_A(10),.ADDR_WIDTH_B(10),.DATA_DEPTH_A(1024),.DATA_DEPTH_B(1024),
  .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
  .WRITEMODE_A("NORMAL"),.WRITEMODE_B("READBEFOREWRITE")) u_owner_eram(
  .clka(clk),.wea(rst_n && rd_en),.addra(tail),.dia(owner_write_data),.doa(),
  .clkb(clk),.web(1'b0),.addrb(owner_read_address),.dib(2'd0),.dob(owner_ram_data));
 wire reserved=cap_wr || view_wr || linear_wr;
 wire available=rst_n && ready && !reserved && writer==3;
 wire lower=available && !display_busy;
 assign outstanding=pending;
 assign display_ready=available && pending<1000;
 // Six round-robin slots. Empty reader slots cost at most one clock.
 always @* begin
  grant=turn;
 end
 assign cap_ready=rst_n && ready && writer==0;
 assign view_ready=rst_n && ready && writer==1;
 assign linear_ready=rst_n && ready && writer==2;
 assign tf_ready=lower && grant==3 && pending<1000;
 assign mask_ready=lower && grant==4 && pending<1000;
 assign linear_rd_ready=lower && grant==5 && pending<1000;
 assign wr_en=cap_wr || view_wr || linear_wr || tf_wr || mask_wr;
 assign rd_en=display_rd || tf_rd || mask_rd || linear_rd;
 assign address=cap_wr?cap_addr:view_wr?view_addr:linear_wr?linear_addr:display_rd?display_addr:
                (mask_wr || mask_rd)?mask_addr:linear_rd?linear_rd_addr:tf_addr;
 assign wr_data=cap_wr?cap_data:view_wr?view_data:linear_wr?linear_data:mask_wr?mask_data:tf_data;
 assign display_valid=rd_valid && pending!=0 && owner_head==0;
 assign tf_valid=rd_valid && pending!=0 && owner_head==1;
 assign mask_valid=rd_valid && pending!=0 && owner_head==2;
 assign linear_rd_valid=rd_valid && pending!=0 && owner_head==3;
 wire [3:0] reads={display_rd,tf_rd,mask_rd,linear_rd};
 wire [4:0] writes={cap_wr,view_wr,linear_wr,tf_wr,mask_wr};
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin writer<=3;turn<=0;head<=0;tail<=0;pending<=0;error<=0;end
  else begin
   if(lower) turn<=turn==5?0:turn+1'b1;
   if(writer==0 && !cap_busy) writer<=3;
   else if(writer==1 && !view_busy) writer<=3;
   else if(writer==2 && !linear_busy) writer<=3;
   else if(lower) begin
    if(grant==0 && cap_busy) writer<=0;
    else if(grant==1 && view_busy) writer<=1;
    else if(grant==2 && linear_busy) writer<=2;
   end
   if(rd_en) tail<=tail+1'b1;
   if(rd_valid && pending!=0) head<=head+1'b1;
   case({rd_en,rd_valid && pending!=0})
    2'b10:pending<=pending+1'b1;2'b01:pending<=pending-1'b1;default:;
   endcase
   if((reads & (reads-1'b1))!=0 || (writes & (writes-1'b1))!=0 || (wr_en && rd_en) ||
      (rd_valid && pending==0) || pending>1000) error<=1;
  end
 end
endmodule
