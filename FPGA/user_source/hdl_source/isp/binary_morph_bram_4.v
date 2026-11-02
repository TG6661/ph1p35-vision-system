// 3x3 binary morphology, four pixels per beat (leftmost pixel in bit 3).
// One 512x8 synchronous RAM packs the two previous rows at each group address.
// The current row bypasses RAM. No frame RAM, bulk clear or row copy.
// Contract: WIDTH divisible by 4, 4<=WIDTH<=2048, HEIGHT>=2; complete raster frames.
// Input user/last must match dimensions. An aborted frame requires reset.
module binary_morph_bram_4 #(
    parameter WIDTH=1280, HEIGHT=720, DILATE=0
)(
    input wire clk, rst_n,
    input wire [3:0] s_tdata,
    input wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    output reg [3:0] m_tdata,
    output reg m_tvalid, m_tuser, m_tlast,
    input wire m_tready
);
    localparam G=WIDTH/4;
    localparam AW=(G>1)?$clog2(G):1;
    localparam YW=$clog2(HEIGHT+1);
    localparam RECEIVE=2'd0, RIGHT_PAD=2'd1, BOTTOM=2'd2;
    reg [1:0] state;
    reg [AW-1:0] group_x;
    reg [YW-1:0] row_y;

    // A shared enable stalls RAM outputs AND every associated token/register.
    // Thus an outstanding synchronous read cannot overwrite a stalled token.
    wire advance = !m_tvalid || m_tready;
    assign s_tready = rst_n && advance && state==RECEIVE;
    wire take = s_tvalid && s_tready;
    wire issue_read = rst_n && advance && ((take && row_y!=0) || state==BOTTOM);
    wire issue_pad = rst_n && advance && state==RIGHT_PAD;
    // Read old history, then write {previous row, current row} one clock later.
    // The pending write drains even if the output stalls: it belongs to an
    // already accepted input, and does not advance the read/token pipeline.
    (* ram_style = "bram" *) reg [7:0] row_mem [0:511];
    reg [7:0] ram_q, forward_word;
    reg forward_valid, write_pending, write_first_row;
    reg [AW-1:0] write_addr;
    reg [3:0] write_bottom;
    wire [7:0] history = forward_valid ? forward_word : ram_q;
    wire [7:0] write_word = {write_first_row ? 4'b0 : history[3:0], write_bottom};
    wire row_read = rst_n && advance && (take || state==BOTTOM);
    wire collision = write_pending && write_addr==group_x;
    // Explicit forwarding also supports WIDTH=4 (one group per row). Suppress
    // the colliding physical read; no vendor read-during-write mode is assumed.
    always @(posedge clk) begin
        if(rst_n && write_pending) row_mem[write_addr] <= write_word;
        if(row_read && !collision) ram_q <= row_mem[group_x];
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            write_pending<=0; write_first_row<=0; write_addr<=0; write_bottom<=0;
            forward_valid<=0; forward_word<=0;
        end else begin
            write_pending<=take;
            if(take) begin
                write_addr<=group_x; write_bottom<=s_tdata; write_first_row<=row_y==0;
            end
            if(row_read) begin
                forward_valid<=collision;
                if(collision) forward_word<=write_word;
            end
        end
    end

    // Read-stage metadata is captured on the same edge as synchronous RAM data.
    reg q_valid, q_pad;
    reg [AW-1:0] q_group;
    reg [YW-1:0] q_row;
    reg [3:0] q_bottom;
    wire [3:0] top_ram = history[7:4];
    wire [3:0] mid_ram = history[3:0];
    wire [3:0] top_pixels = q_row==1 ? 4'b0 : top_ram;
    // A rectangular 3x3 AND/OR separates exactly into vertical then horizontal.
    wire [3:0] vertical = DILATE ? (top_pixels | mid_ram | q_bottom)
                                      : (top_pixels & mid_ram & q_bottom);
    reg [3:0] previous_group;
    reg left_column;
    wire [5:0] window_bits = {left_column, previous_group, (q_pad ? 1'b0 : vertical[3])};
    wire [3:0] result_bits;
    genvar lane;
    generate for(lane=0; lane<4; lane=lane+1) begin: g_lane
        assign result_bits[3-lane] = DILATE ? (|window_bits[5-lane -: 3])
                                                   : (&window_bits[5-lane -: 3]);
    end endgenerate

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=RECEIVE; group_x<=0; row_y<=0;
            q_valid<=0; q_pad<=0; q_group<=0; q_row<=0; q_bottom<=0;
            previous_group<=0; left_column<=0;
            m_tvalid<=0; m_tdata<=0; m_tuser<=0; m_tlast<=0;
        end else if(advance) begin
            q_valid<=issue_read || issue_pad;
            q_pad<=issue_pad;
            q_group<=group_x; q_row<=row_y;
            // Bypass current accepted input; bottom virtual row is all zeros.
            q_bottom<=(state==BOTTOM) ? 4'b0 : s_tdata;
            m_tvalid<=0; m_tuser<=0; m_tlast<=0;
            if(q_valid) begin
                if(q_pad || q_group!=0) begin
                    m_tdata<=result_bits; m_tvalid<=1;
                    m_tlast<=q_pad;
                    m_tuser<=(q_row==1 && ((q_pad && G==1) || (!q_pad && q_group==1)));
                end
                if(!q_pad) begin
                    previous_group<=vertical;
                    left_column<=(q_group==0) ? 1'b0 : previous_group[0];
                end
            end
            case(state)
                RECEIVE: if(take) begin
                    if(group_x==G-1) begin
                        group_x<=0;
                        if(row_y==0) begin
                            row_y<=1;
                        end else state<=RIGHT_PAD;
                    end else group_x<=group_x+1'b1;
                end
                RIGHT_PAD: begin
                    group_x<=0;
                    if(row_y==HEIGHT) begin
                        state<=RECEIVE; row_y<=0;
                    end else begin
                        row_y<=row_y+1'b1;
                        state<=(row_y==HEIGHT-1) ? BOTTOM : RECEIVE;
                    end
                end
                BOTTOM: begin
                    if(group_x==G-1) begin group_x<=0; state<=RIGHT_PAD; end
                    else group_x<=group_x+1'b1;
                end
                default: begin state<=RECEIVE; row_y<=0; group_x<=0; end
            endcase
        end
    end
    // synthesis translate_off
    initial if(WIDTH<4 || WIDTH>2048 || WIDTH%4!=0 || HEIGHT<2)
        $fatal(1,"Packed morphology requires WIDTH=4..2048 divisible by 4, HEIGHT>=2");
    // synthesis translate_on
endmodule
