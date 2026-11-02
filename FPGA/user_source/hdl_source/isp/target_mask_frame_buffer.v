// Nonblocking camera tap -> complete-frame, backpressured mask replay.
// Five 4-pixel beats per 20-bit RAM word fit PH1 ERAM widths without padding.
module target_mask_frame_buffer #(parameter WIDTH=1280,HEIGHT=720)(
    input wire clk,rst_n,
    input wire [3:0] s_data,
    input wire s_valid,s_user,s_last,
    output wire [3:0] m_data,
    output wire m_valid,m_user,m_last,
    input wire m_ready,process_done,
    output reg [31:0] frame_id,
    output wire busy,
    output reg capture_error,
    output reg [31:0] skipped_frames
);
    localparam BEATS=WIDTH*HEIGHT/4,WORDS=(BEATS+4)/5,AW=$clog2(WORDS);
    localparam IDLE=0,CAPTURE=1,READ_ADDR=2,READ_WAIT=3,REPLAY=4,WAIT_DONE=5;
    reg [2:0] state;
    reg [8:0] cx,rx;
    reg [9:0] cy,ry;
    reg [2:0] pack_index,read_index;
    reg [15:0] pack;
    reg [AW-1:0] wa,ra;
    reg [19:0] word;
    reg [31:0] next_frame_id;
    (* ram_style="bram" *) reg [19:0] memory[0:WORDS-1];
    reg [19:0] q;
    wire legal_last=s_last==(cx==WIDTH/4-1);
    wire store=rst_n && state==CAPTURE && s_valid && !s_user && legal_last && pack_index==4;
    always @(posedge clk) begin
        if(store) memory[wa]<={pack,s_data};
        if(state==READ_ADDR) q<=memory[ra];
    end
    assign m_valid=rst_n && state==REPLAY;
    assign m_data=word[19:16];
    assign m_user=rx==0 && ry==0;
    assign m_last=rx==WIDTH/4-1;
    assign busy=state!=IDLE;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE; cx<=0; cy<=0; rx<=0; ry<=0; wa<=0; ra<=0;
            pack_index<=0; read_index<=0; pack<=0; word<=0; frame_id<=0;
            next_frame_id<=0; capture_error<=0; skipped_frames<=0;
        end else begin
            capture_error<=0;
            if(s_valid && s_user) begin
                next_frame_id<=next_frame_id+1'b1;
                if(state!=IDLE && state!=CAPTURE) skipped_frames<=skipped_frames+1'b1;
            end
            // A new SOF abandons a truncated capture and starts afresh.
            if(s_valid && s_user && (state==IDLE || state==CAPTURE)) begin
                capture_error<=state==CAPTURE || s_last;
                if(!s_last) begin
                    frame_id<=next_frame_id; pack<={12'b0,s_data}; pack_index<=1;
                    cx<=1; cy<=0; wa<=0; state<=CAPTURE;
                end else state<=IDLE;
            end else case(state)
                CAPTURE: if(s_valid) begin
                    if(!legal_last) begin state<=IDLE; capture_error<=1; end
                    else begin
                        pack<={pack[11:0],s_data};
                        if(pack_index==4) begin pack_index<=0; wa<=wa+1'b1; end
                        else pack_index<=pack_index+1'b1;
                        if(cx==WIDTH/4-1) begin
                            cx<=0; cy<=cy+1'b1;
                            if(cy==HEIGHT-1) begin ra<=0; rx<=0; ry<=0; read_index<=0; state<=READ_ADDR; end
                        end else cx<=cx+1'b1;
                    end
                end
                READ_ADDR: state<=READ_WAIT;
                READ_WAIT: begin word<=q; read_index<=0; state<=REPLAY; end
                REPLAY: if(m_ready) begin
                    if(rx==WIDTH/4-1 && ry==HEIGHT-1) state<=WAIT_DONE;
                    else begin
                        if(rx==WIDTH/4-1) begin rx<=0; ry<=ry+1'b1; end else rx<=rx+1'b1;
                        if(read_index==4) begin ra<=ra+1'b1; state<=READ_ADDR; end
                        else begin read_index<=read_index+1'b1; word<={word[15:0],4'b0}; end
                    end
                end
                WAIT_DONE: if(process_done) state<=IDLE;
                default: state<=IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial if(WIDTH<20 || WIDTH>1280 || WIDTH%20!=0 || HEIGHT<1 || HEIGHT>720)
        $fatal(1,"Frame buffer requires width divisible by 20 and height <=720");
    // synthesis translate_on
endmodule

// Production DDR-backed single-frame mask. Kept in this registered compilation
// unit so an older TD GUI source list cannot omit the new implementation.
// Addresses use the existing controller's 16-bit units: 128-bit word stride=8.
// Reserve [0x200000,0x210000), inside the gap after display bank 0. All writes
// retire at the MC command/data handshake before reads are issued. The MC must
// preserve the ordinary write-before-read memory dependency (as for RGB frames).
// rst_n is the SHARED DDR/arbiter reset. cancel is a local detector reset: it
// flushes pixels but retains outstanding transactions until their returns drain.
module target_mask_ddr #(
    parameter WIDTH=1280,HEIGHT=720,
    parameter [24:0] BASE=25'h0200000
)(
    input wire clk,rst_n,cancel,
    input wire [3:0] s_data,
    input wire s_valid,s_user,s_last,
    output wire [3:0] m_data,
    output wire m_valid,m_user,m_last,
    input wire m_ready,process_done,
    output reg [31:0] frame_id,skipped_frames,
    output wire busy,
    output reg capture_error,protocol_error,
    output wire request,wr_en,rd_en,
    output wire [24:0] address,
    output wire [127:0] wr_data,
    input wire bus_ready,rd_valid,write_retired,
    input wire [127:0] rd_data
);
    localparam BEATS=WIDTH*HEIGHT/4,WORDS=(WIDTH*HEIGHT+127)/128;
    localparam BW=$clog2(BEATS+1),CW=$clog2(WORDS+1);
    localparam XW=(WIDTH/4>1)?$clog2(WIDTH/4):1;
    localparam PAD=(128-(WIDTH*HEIGHT)%128)%128;
    localparam IDLE=0,CAPTURE=1,WRITE_DRAIN=2,READ=3,WAIT_DONE=4,ABORT=5;
    reg [2:0] state;
    reg [31:0] next_frame_id;
    reg [BW-1:0] captured,emitted;
    reg [XW-1:0] cx,rx;
    reg [4:0] pack_index,lane;
    reg [123:0] pack;
    reg [127:0] pixel_word;
    reg pixel_valid;
    reg [CW-1:0] written,read_issued,writes_pending;
    reg [4:0] outstanding;
    wire capture_last=captured==BEATS-1;
    wire legal_last=s_last==(cx==WIDTH/4-1);
    wire make_word=state==CAPTURE && s_valid && !s_user && legal_last &&
                   (pack_index==31 || capture_last) && !cancel;
    wire [127:0] packed_word={pack,s_data};
    wire [127:0] tx_input=(PAD!=0 && capture_last)?(packed_word<<PAD):packed_word;
    wire tx_ready,tx_valid,rx_ready,rx_valid;
    wire [127:0] tx_data,rx_data;
    wire [9:0] tx_used,rx_used;
    wire flush=cancel || state==IDLE || state==ABORT;
    wire load=state==READ && !cancel && !pixel_valid && rx_valid;
    mask_ddr_fifo128 u_write_fifo(.clk(clk),.rst_n(rst_n),.flush(flush),
        .s_data(tx_input),.s_valid(make_word),.s_ready(tx_ready),
        .m_data(tx_data),.m_valid(tx_valid),.m_ready(wr_en),.used(tx_used));
    mask_ddr_fifo128 u_read_fifo(.clk(clk),.rst_n(rst_n),.flush(flush),
        .s_data(rd_data),.s_valid(rd_valid && outstanding!=0 && state==READ && !cancel),.s_ready(rx_ready),
        .m_data(rx_data),.m_valid(rx_valid),.m_ready(load),.used(rx_used));
    wire want_write=(state==CAPTURE || state==WRITE_DRAIN) && tx_valid;
    // Reserve space before issue, including responses still in the adapter/MC.
    // 16 in flight bounds interference and leaves ample FIFO skid margin.
    wire want_read=state==READ && read_issued<WORDS && outstanding<16 &&
                   ({1'b0,rx_used}+outstanding)<448;
    assign request=rst_n && !cancel && (want_write || want_read);
    assign wr_en=request && bus_ready && want_write;
    assign rd_en=request && bus_ready && want_read;
    assign address=BASE+((want_write?{{(25-CW){1'b0}},written}:{{(25-CW){1'b0}},read_issued})<<3);
    assign wr_data=tx_data;
    assign busy=state!=IDLE || cancel;
    assign m_valid=rst_n && !cancel && state==READ && pixel_valid;
    assign m_data=pixel_word[127:124];
    assign m_user=emitted==0;
    assign m_last=rx==WIDTH/4-1;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;next_frame_id<=0;frame_id<=0;skipped_frames<=0;
            captured<=0;emitted<=0;cx<=0;rx<=0;pack_index<=0;lane<=0;pack<=0;
            pixel_word<=0;pixel_valid<=0;written<=0;read_issued<=0;
            writes_pending<=0;outstanding<=0;capture_error<=0;protocol_error<=0;
        end else begin
            capture_error<=0;
            case({wr_en,write_retired && writes_pending!=0})
                2'b10:writes_pending<=writes_pending+1'b1;
                2'b01:writes_pending<=writes_pending-1'b1;
                default:;
            endcase
            case({rd_en,rd_valid && outstanding!=0})
                2'b10:outstanding<=outstanding+1'b1;
                2'b01:outstanding<=outstanding-1'b1;
                default:;
            endcase
            if(wr_en) written<=written+1'b1;
            if(rd_en) read_issued<=read_issued+1'b1;
            if((write_retired && writes_pending==0) || (rd_valid && outstanding==0) ||
               (rd_valid && state==READ && !cancel && !rx_ready)) protocol_error<=1;
            if(s_valid && s_user && !cancel) begin
                next_frame_id<=next_frame_id+1'b1;
                if(state!=IDLE) skipped_frames<=skipped_frames+1'b1;
            end
            if(cancel) begin
                state<=ABORT;pixel_valid<=0;next_frame_id<=0;frame_id<=0;skipped_frames<=0;
            end else case(state)
                IDLE:if(s_valid && s_user) begin
                    if(s_last!=(WIDTH==4)) begin capture_error<=1;state<=ABORT;end
                    else begin
                        frame_id<=next_frame_id;captured<=1;cx<=(WIDTH==4)?0:1;
                        pack<={120'b0,s_data};pack_index<=1;written<=0;read_issued<=0;
                        emitted<=0;rx<=0;pixel_valid<=0;lane<=0;state<=CAPTURE;
                    end
                end
                CAPTURE:if(s_valid) begin
                    // An early SOF or overflow invalidates this entire frame.
                    // Drain accepted DDR writes before admitting another SOF.
                    if(s_user || !legal_last || (make_word && !tx_ready)) begin
                        state<=ABORT;capture_error<=1;
                    end else begin
                        pack<={pack[119:0],s_data};pack_index<=pack_index+1'b1;
                        cx<=s_last?0:cx+1'b1;captured<=captured+1'b1;
                        if(capture_last) state<=WRITE_DRAIN;
                    end
                end
                WRITE_DRAIN:if(written==WORDS && writes_pending==0 && !tx_valid && tx_used==0) state<=READ;
                READ:begin
                    if(load) begin pixel_word<=rx_data;pixel_valid<=1;lane<=0;end
                    else if(m_valid && m_ready) begin
                        pixel_word<=pixel_word<<4;lane<=lane+1'b1;emitted<=emitted+1'b1;
                        rx<=m_last?0:rx+1'b1;
                        if(lane==31) pixel_valid<=0;
                        if(emitted==BEATS-1) begin pixel_valid<=0;state<=WAIT_DONE;end
                    end
                end
                WAIT_DONE:if(process_done) state<=IDLE;
                ABORT:begin
                    pixel_valid<=0;
                    if(writes_pending==0 && outstanding==0 && !rd_valid && !write_retired) state<=IDLE;
                end
                default:state<=ABORT;
            endcase
        end
    end
    // synthesis translate_off
    initial begin
        if(WIDTH<4 || WIDTH>1280 || WIDTH%4!=0 || HEIGHT<2 || HEIGHT>720)
            $fatal(1,"DDR mask dimensions outside supported raster");
        if(BASE[15:0]!=0 || BASE<25'd1382400 || BASE+25'd65536>25'd7000000 || WORDS*8>65536)
            $fatal(1,"DDR mask slot overlaps display storage or is misaligned");
    end
    always @(posedge clk) if(rst_n) begin
        if(wr_en && rd_en) $fatal(1,"Mask read/write collision");
        if(rd_en && writes_pending!=0) $fatal(1,"Mask read overtook write retirement");
        if((wr_en || rd_en) && (address<BASE || address>=BASE+WORDS*8 || address[2:0]!=0))
            $fatal(1,"Mask DDR address outside frame");
    end
    // synthesis translate_on
endmodule

// 512-word synchronous FIFO, with a prefetched head included in the budget.
// RAM data/output have no reset; only pointers, count and validity are reset.
module mask_ddr_fifo128(
    input wire clk,rst_n,flush,
    input wire [127:0] s_data,input wire s_valid,output wire s_ready,
    output reg [127:0] m_data,output reg m_valid,input wire m_ready,
    output wire [9:0] used
);
    (* ram_style="bram" *) reg [127:0] memory[0:511];
    reg [8:0] wp,rp;
    reg [9:0] stored;
    assign used=stored+m_valid;
    assign s_ready=rst_n && !flush && used<512;
    wire push=s_valid && s_ready;
    wire fetch=rst_n && !flush && (!m_valid || m_ready) && stored!=0;
    always @(posedge clk) begin
        if(push) memory[wp]<=s_data;
        if(fetch) m_data<=memory[rp];
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin wp<=0;rp<=0;stored<=0;m_valid<=0;end
        else if(flush) begin wp<=0;rp<=0;stored<=0;m_valid<=0;end
        else begin
            if(push) wp<=wp+1'b1;
            if(fetch) begin rp<=rp+1'b1;m_valid<=1;end
            else if(m_ready) m_valid<=0;
            case({push,fetch})
                2'b10:stored<=stored+1'b1;
                2'b01:stored<=stored-1'b1;
                default:;
            endcase
        end
    end
endmodule
