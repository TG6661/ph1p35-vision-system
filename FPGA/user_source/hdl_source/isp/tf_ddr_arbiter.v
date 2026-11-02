// Five clients. Existing FIFO writers have one registered output after ready:
// that reserved word has priority next clock and uses the adapter's skid margin.
// Ordered DDR read responses use a 1024-entry two-bit owner queue. Display's
// outstanding limit is 448; TF and mask each issue at most 16 reads at a time.
module tf_ddr_arbiter(
    input wire clk,rst_n,
    input wire cap_busy,cap_wr,input wire [24:0] cap_addr,input wire [127:0] cap_data,output wire cap_ready,
    input wire view_busy,view_wr,input wire [24:0] view_addr,input wire [127:0] view_data,output wire view_ready,
    input wire display_busy,display_rd,input wire [24:0] display_addr,output wire display_ready,display_valid,
    input wire tf_rd,tf_wr,input wire [24:0] tf_addr,input wire [127:0] tf_data,output wire tf_ready,tf_valid,
    input wire mask_request,mask_wr,mask_rd,input wire [24:0] mask_addr,input wire [127:0] mask_data,
    output wire mask_ready,mask_valid,
    input wire ready,rd_valid,
    output wire wr_en,rd_en,output wire [24:0] address,output wire [127:0] wr_data,
    output reg error
);
    reg [1:0] turn;
    reg [1:0] grant;
    reg [1:0] writer_owner;
    wire reserved=cap_wr || view_wr;
    reg [1:0] owners[0:1023]; // synthesis ram_style=dram
    reg [9:0] head,tail;
    reg [10:0] pending;
    // HDMI has a hard deadline; lower-priority clients rotate after each grant.
    always @(*) begin
        grant=3;
        if(turn==0) begin if(cap_busy) grant=0;else if(view_busy) grant=1;else grant=2;end
        else if(turn==1) begin if(view_busy) grant=1;else grant=2;end
        else if(turn==2) grant=2;
        else if(mask_request) grant=3;
        else if(cap_busy) grant=0;
        else if(view_busy) grant=1;
        else grant=2;
    end
    wire available=rst_n && ready && !reserved && writer_owner==2;
    assign display_ready=available && pending<1000;
    wire lower=available && !display_busy;
    // Hold a complete existing 240-word write burst. Consecutive FIFO pops
    // sustain one word/clock; never insert a bubble for each registered word.
    assign cap_ready=rst_n && ready && writer_owner==0;
    assign view_ready=rst_n && ready && writer_owner==1;
    assign tf_ready=lower && grant==2 && pending<1000;
    assign mask_ready=lower && grant==3 && pending<1000;
    assign wr_en=cap_wr || view_wr || tf_wr || mask_wr;
    assign rd_en=display_rd || tf_rd || mask_rd;
    assign address=cap_wr ? cap_addr : view_wr ? view_addr : display_rd ? display_addr : (mask_wr || mask_rd) ? mask_addr : tf_addr;
    assign wr_data=cap_wr ? cap_data : view_wr ? view_data : mask_wr ? mask_data : tf_data;
    assign display_valid=rd_valid && pending!=0 && owners[head]==0;
    assign tf_valid=rd_valid && pending!=0 && owners[head]==1;
    assign mask_valid=rd_valid && pending!=0 && owners[head]==2;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin writer_owner<=2;turn<=0;head<=0;tail<=0;pending<=0;error<=0;end
        else begin
            if(lower) turn<=grant+1'b1;
            if(writer_owner==0 && !cap_busy) writer_owner<=2;
            else if(writer_owner==1 && !view_busy) writer_owner<=2;
            else if(lower && grant<2) writer_owner<=grant;
            if(rd_en) begin owners[tail]<=mask_rd ? 2'd2 : tf_rd ? 2'd1 : 2'd0;tail<=tail+1'b1;end
            if(rd_valid && pending!=0) head<=head+1'b1;
            case({rd_en,rd_valid && pending!=0})
                2'b10:pending<=pending+1'b1;
                2'b01:pending<=pending-1'b1;
                default:;
            endcase
            if((cap_wr && view_wr) || (mask_wr && (cap_wr || view_wr || tf_wr)) || (display_rd && (tf_rd || mask_rd)) || (tf_rd && mask_rd) || (wr_en && rd_en) || (rd_valid && pending==0) || pending>1000) error<=1;
        end
    end
endmodule
