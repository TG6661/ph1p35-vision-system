// Frozen target bridge contract for timing regression; not a TD source.
module mcu_target_bridge_timing_reference #(parameter STALE_CYCLES=33333333)(
    input wire ahb_clk,detector_clk,reset_n,
    input wire write,input wire [4:0] write_word,input wire [31:0] wdata,
    input wire [4:0] read_word,output reg [31:0] rdata,
    input wire s_valid,output wire s_ready,input wire [69:0] s_record,
    input wire s_done_valid,output wire s_done_ready,
    input wire [15:0] s_count,s_total,input wire [3:0] s_error,input wire [31:0] s_frame,
    output wire m_valid,input wire m_ready,output reg [51:0] m_record,
    output wire m_done_valid,input wire m_done_ready,
    output reg [15:0] m_count,output reg [3:0] m_error,output reg [31:0] m_frame,
    output wire alive,result_reset_n
);
    wire rx_idle,drn,arn,rx_pending;
    reg [4:0] rx_index;
    localparam WAIT_RESULT=0,LOAD_RECORD=1,EMIT_RECORD=2,EMIT_DONE=3,WAIT_ACK=4;
    reg [2:0] state,index;
    reg rx_accept;
    // Source records reside in distributed RAM, held until mailbox release.
    wire [69:0] published_record_q;
    reg [31:0] published_sequence,published_frame,published_dropped;
    reg [15:0] published_total;
    reg [3:0] published_count,published_error;
    reg [31:0] detection_sequence,dropped;
    reg [3:0] received;
    reg keep_frame;
    assign s_ready=drn;
    assign s_done_ready=drn && !s_valid;
    wire finish=s_done_valid && s_done_ready;
    wire publish=finish && rx_idle && (received==0 || keep_frame);
    wire raw_write=s_valid && s_ready && received<8 &&
        ((received==0 && rx_idle) || (received!=0 && keep_frame));
    wire [2:0] raw_address=(write && write_word==4 && wdata<32 && wdata[1:0]!=3)?
        wdata[4:2]:rx_index[4:2];
    // Tiny tables use distributed storage. Keep the original one-cycle reads;
    // the publication handshake holds records stable until the AHB consumer
    // releases them. Do not reset the arrays or bypass that ownership protocol.
    (* ram_style = "dram" *) reg [69:0] raw_records[0:7];
    reg [69:0] raw_record_read;
    always @(posedge detector_clk) if(raw_write) raw_records[received[2:0]]<=s_record;
    always @(posedge ahb_clk) raw_record_read<=raw_records[raw_address];
    assign published_record_q=raw_record_read;
    target_result_cdc #(.SYNC_RELEASE(1)) u_raw_cdc(
        .src_clk(detector_clk),.dst_clk(ahb_clk),.reset_n(reset_n),
        .src_submit(publish),.src_idle(rx_idle),.src_reset_n(drn),.dst_reset_n(arn),
        .dst_pending(rx_pending),.dst_accept(rx_accept));
    always @(posedge detector_clk or negedge drn) begin
        if(!drn) begin
            published_sequence<=0;published_frame<=0;published_dropped<=0;
            published_total<=0;published_count<=0;published_error<=0;
            detection_sequence<=0;dropped<=0;received<=0;keep_frame<=0;
        end else begin
            if(s_valid && s_ready) begin
                if(received==0) keep_frame<=rx_idle;
                if(received<9) received<=received+1'b1;
            end
            if(finish) begin
                detection_sequence<=detection_sequence+1'b1;received<=0;keep_frame<=0;
                if(publish) begin
                    published_sequence<=detection_sequence+1'b1;published_frame<=s_frame;
                    published_total<=s_total;published_dropped<=dropped;
                    published_count<=received<=8 && s_count==received ? received : 0;
                    published_error<=s_error | ((received>8 || s_count!=received)?4'd8:4'd0);
                end else dropped<=dropped+1'b1;
            end
        end
    end

    reg rx_ready,rx_released;
    reg [1:0] rx_guard;
    reg [31:0] rx_sequence,rx_frame,rx_dropped;
    reg [15:0] rx_total;
    reg [3:0] rx_count,rx_error;
    wire [31:0] tx_low_q,tx_low_out;
    wire [19:0] tx_high_q,tx_high_out;
    reg [31:0] tx_sequence,tx_frame,accepted_sequence,delivered_sequence,accepted_count;
    reg [3:0] tx_count,tx_error,tx_index;
    reg tx_meta_legal,tx_submit,tx_inflight,rejected,accepted_valid;
    reg [15:0] tx_written;
    reg [7:0] tx_geometry,tx_high_clean;
    wire tx_idle,tx_arn,tx_drn,tx_pending;
    assign result_reset_n=tx_drn;
    wire tx_busy=tx_inflight || !tx_idle || tx_submit;
    // Each required record needs both written halves and both legality flags.
    // Combinational checks preserve last-half-write -> next-cycle commit.
    wire [7:0] record_pass;
    genvar record_i;
    generate for(record_i=0;record_i<8;record_i=record_i+1) begin:g_record_complete
        localparam [3:0] RECORD_INDEX=record_i;
        assign record_pass[record_i]=(tx_count<=RECORD_INDEX) ||
            (tx_written[2*record_i] && tx_written[2*record_i+1] &&
             tx_geometry[record_i] && tx_high_clean[record_i]);
    end endgenerate
    wire table_complete=&record_pass;
    wire tx_write=write && write_word==11 && !tx_busy && arn;
    wire [2:0] tx_address=(write && write_word==10 && !tx_busy && wdata<16)?wdata[3:1]:tx_index[3:1];
    // READBEFOREWRITE returns the previous half; forward the latest write when
    // successive operations address the same record. Index writes prefetch.
    reg low_forward_valid,high_forward_valid;
    reg [2:0] low_forward_address,high_forward_address;
    // Forward only the geometry information needed from the previous half.
    // The complete 52-bit payload remains in return_low/return_high RAM.
    // xmin straddles halves: bit 0 in low[31], bits 10:1 in high[9:0].
    function [12:0] low_geometry_summary;
        input [31:0] value;
        begin low_geometry_summary={
            (value[30:20]<11'd1280 && value[19:10]<=value[9:0] && value[9:0]<10'd720),
            value[31:20]};end
    endfunction
    function [10:0] high_geometry_summary;
        input [19:0] value;
        begin high_geometry_summary={
            (value[19:12]!=8'd0 && value[11:10]!=2'd3),value[9:0]};end
    endfunction
    reg [12:0] low_forward;
    reg [10:0] high_forward;
    wire [12:0] prior_low=low_forward_valid && low_forward_address==tx_index[3:1]?
        low_forward:low_geometry_summary(tx_low_q);
    wire [10:0] prior_high=high_forward_valid && high_forward_address==tx_index[3:1]?
        high_forward:high_geometry_summary(tx_high_q);
    wire [2:0] return_address=state==WAIT_RESULT?3'd0:
        ((state==EMIT_RECORD && m_ready)?index+3'd1:index);
    (* ram_style = "dram" *) reg [31:0] return_low[0:7];
    (* ram_style = "dram" *) reg [19:0] return_high[0:7];
    reg [31:0] return_low_local,return_low_remote;
    reg [19:0] return_high_local,return_high_remote;
    always @(posedge ahb_clk) begin
        // Nonblocking updates preserve READBEFOREWRITE; existing forwarding
        // still covers consecutive writes of the two halves of a record.
        return_low_local<=return_low[tx_address];
        return_high_local<=return_high[tx_address];
        if(tx_write && !tx_index[0]) return_low[tx_address]<=wdata;
        if(tx_write && tx_index[0]) return_high[tx_address]<=wdata[19:0];
    end
    always @(posedge detector_clk) begin
        return_low_remote<=return_low[return_address];
        return_high_remote<=return_high[return_address];
    end
    assign tx_low_q=return_low_local,tx_high_q=return_high_local;
    assign tx_low_out=return_low_remote,tx_high_out=return_high_remote;
    always @(posedge ahb_clk or negedge arn) begin
        if(!arn) begin
            low_forward_valid<=0;high_forward_valid<=0;low_forward_address<=0;high_forward_address<=0;
            low_forward<=0;high_forward<=0;
        end else if(tx_write) begin
            if(tx_index[0]) begin high_forward<=high_geometry_summary(wdata[19:0]);high_forward_address<=tx_index[3:1];high_forward_valid<=1;end
            else begin low_forward<=low_geometry_summary(wdata);low_forward_address<=tx_index[3:1];low_forward_valid<=1;end
        end
    end
    wire [12:0] candidate_low=tx_index[0]?prior_low:low_geometry_summary(wdata);
    wire [10:0] candidate_high=tx_index[0]?high_geometry_summary(wdata[19:0]):prior_high;
    wire geometry_ok=candidate_low[12] && candidate_high[10] &&
        {candidate_high[9:0],candidate_low[11]}<=candidate_low[10:0];
    wire result_legal=tx_meta_legal && tx_count<=rx_count &&
        (tx_error | rx_error)==tx_error && (tx_error==0 || tx_count==0) &&
        table_complete;
    reg tx_accept;
    target_result_cdc #(.SYNC_RELEASE(1)) u_result_cdc(
        .src_clk(ahb_clk),.dst_clk(detector_clk),.reset_n(reset_n),
        .src_submit(tx_submit),.src_idle(tx_idle),.src_reset_n(tx_arn),.dst_reset_n(tx_drn),
        .dst_pending(tx_pending),.dst_accept(tx_accept));
    always @(posedge ahb_clk or negedge arn) begin
        if(!arn) begin
            rx_accept<=0;rx_ready<=0;rx_released<=0;rx_guard<=0;
            rx_sequence<=0;rx_frame<=0;rx_dropped<=0;rx_total<=0;rx_count<=0;rx_error<=0;rx_index<=0;
            tx_sequence<=0;tx_frame<=0;tx_count<=0;tx_error<=0;tx_index<=0;
            tx_meta_legal<=1;tx_submit<=0;tx_inflight<=0;rejected<=0;accepted_valid<=0;
            tx_written<=0;tx_geometry<=0;tx_high_clean<=0;
            accepted_sequence<=0;delivered_sequence<=0;accepted_count<=0;
        end else begin
            rx_accept<=0;tx_submit<=0;
            // Extra destination settling before exposing the held source bus.
            if(!rx_pending) begin rx_ready<=0;rx_released<=0;rx_guard<=0;end
            else if(!rx_ready && !rx_released) begin
                if(rx_guard==3) begin
                    rx_sequence<=published_sequence;rx_frame<=published_frame;
                    rx_count<=published_count;rx_error<=published_error;
                    rx_total<=published_total;rx_dropped<=published_dropped;rx_ready<=1;
                end else rx_guard<=rx_guard+1'b1;
            end
            if(tx_inflight && tx_idle && !tx_submit) begin
                tx_inflight<=0;delivered_sequence<=accepted_sequence;
            end
            if(write) case(write_word)
                5'd4: if(wdata<32 && wdata[1:0]!=3) rx_index<=wdata[4:0];else rejected<=1;
                5'd6: begin
                    if(wdata[2]) rejected<=0;
                    if(wdata[31:3]!=0 || wdata[1:0]==3) rejected<=1;
                    else if(wdata[1]) begin
                        if(rx_ready && !tx_busy && tx_sequence==rx_sequence && result_legal) begin
                            tx_frame<=rx_frame;tx_submit<=1;tx_inflight<=1;
                            accepted_sequence<=rx_sequence;accepted_count<=accepted_count+1'b1;accepted_valid<=1;
                            rx_ready<=0;rx_released<=1;rx_accept<=1;tx_written<=0;
                        end else rejected<=1;
                    end else if(wdata[0] && rx_ready) begin
                        rx_ready<=0;rx_released<=1;rx_accept<=1;tx_written<=0;
                    end
                end
                5'd8: if(!tx_busy) begin tx_sequence<=wdata;tx_written<=0;tx_geometry<=0;tx_high_clean<=0;end else rejected<=1;
                5'd9: if(!tx_busy) begin
                    tx_count<=wdata[3:0];tx_error<=wdata[7:4];tx_meta_legal<=wdata[31:8]==0 && wdata[3:0]<=8;
                end else rejected<=1;
                5'd10: if(!tx_busy && wdata<16) tx_index<=wdata[3:0];else rejected<=1;
                5'd11: if(!tx_busy) begin
                    tx_written[tx_index]<=1;tx_geometry[tx_index[3:1]]<=geometry_ok;
                    if(tx_index[0]) tx_high_clean[tx_index[3:1]]<=wdata[31:20]==0;
                end else rejected<=1;
                default: begin end // All snapshot/status registers are read-only.
            endcase
        end
    end
    // Source records remain immutable until COMMAND release/accepted return.
    // Split the 16-word read mux into four registered banks. The AHB response
    // captures the selected bank after three waits, including index write->read.
    // Payload keeps its registered AHB read after distributed RAM inference.
    // Published metadata and table ownership still use the existing mailbox.
    reg [69:0] raw_record;
    reg [31:0] raw_word;
    reg [31:0] read_bank0,read_bank1,read_bank2,read_bank3;
    always @* begin
        raw_record=0;
        if(rx_ready && {1'b0,rx_index[4:2]}<rx_count) raw_record=published_record_q;
        case(rx_index[1:0])
            0:raw_word={4'd0,raw_record[69:62],raw_record[61:42]};
            1:raw_word={5'd0,raw_record[30:20],5'd0,raw_record[41:31]};
            2:raw_word={6'd0,raw_record[9:0],6'd0,raw_record[19:10]};
            default:raw_word=0;
        endcase
        case(read_word[4:2])
            0:rdata=read_bank0;
            1:rdata=read_bank1;
            2:rdata=read_bank2;
            3:rdata=read_bank3;
            default:rdata=0;
        endcase
    end
    always @(posedge ahb_clk or negedge arn) begin
        if(!arn) begin read_bank0<=0;read_bank1<=0;read_bank2<=0;read_bank3<=0;end
        else case(read_word[1:0])
            0:begin
                read_bank0<={27'd0,(!tx_busy),accepted_valid,rejected,tx_busy,rx_ready};
                read_bank1<={27'd0,rx_index};read_bank2<=tx_sequence;read_bank3<=accepted_sequence;
            end
            1:begin
                read_bank0<=rx_sequence;read_bank1<=raw_word;
                read_bank2<={24'd0,tx_error,tx_count};read_bank3<=delivered_sequence;
            end
            2:begin
                read_bank0<=rx_frame;read_bank1<=0;
                read_bank2<={28'd0,tx_index};read_bank3<=accepted_count;
            end
            3:begin
                read_bank0<={rx_total,8'd0,rx_error,rx_count};read_bank1<=rx_dropped;
                read_bank2<=0;read_bank3<=32'h00010008;
            end
        endcase
    end

    localparam AGE_BITS=$clog2(STALE_CYCLES+1);
    reg [AGE_BITS-1:0] alive_count;
    reg alive_flag;
    assign alive=alive_flag;
    assign m_valid=tx_drn && state==EMIT_RECORD;
    assign m_done_valid=tx_drn && state==EMIT_DONE;
    always @(posedge detector_clk or negedge tx_drn) begin
        if(!tx_drn) begin
            state<=WAIT_RESULT;index<=0;m_record<=0;m_count<=0;m_error<=0;m_frame<=0;
            tx_accept<=0;alive_count<=0;alive_flag<=0;
        end else begin
            tx_accept<=0;
            if(alive_count!=0) alive_count<=alive_count-1'b1;
            if(alive_count==1) alive_flag<=0;
            case(state)
                WAIT_RESULT:if(tx_pending) begin
                    m_count<={12'd0,tx_count};m_error<=tx_error;m_frame<=tx_frame;index<=0;
                    state<=tx_count==0?EMIT_DONE:LOAD_RECORD;
                end
                LOAD_RECORD:begin m_record<={tx_high_out,tx_low_out};state<=EMIT_RECORD;end
                EMIT_RECORD:if(m_ready) begin
                    if(index+1>=m_count) state<=EMIT_DONE;
                    else begin index<=index+1'b1;state<=LOAD_RECORD;end
                end
                EMIT_DONE:if(m_done_ready) begin tx_accept<=1;state<=WAIT_ACK;alive_count<=STALE_CYCLES;alive_flag<=1;end
                WAIT_ACK:if(!tx_pending) state<=WAIT_RESULT;
                default:state<=WAIT_RESULT;
            endcase
        end
    end
endmodule
