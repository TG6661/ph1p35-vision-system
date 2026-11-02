// Complete-frame DDR reader: reserve FIFO space at read-command issue.
module video_out #(parameter WIDTH=1280,HEIGHT=720,FRAME_ID_ENABLE=0) (
    input wire I_rst_n,I_ddr_clk,
    output wire O_video_out_rd_busy,
    input wire I_video_in_wr_busy,
    input wire [1:0] I_video_out_rp,I_frame_mode,
    input wire I_frame_valid,
    input wire [31:0] I_frame_id,
    input wire I_frame_id_valid, // New publication in the current monitor/reset epoch.
    output wire [31:0] O_display_frame_id,
    output wire O_display_good,
    output reg [1:0] O_read_bank,
    output reg [2:0] O_read_metadata,O_display_metadata,
    output wire O_ddr_user_rd_en,
    output reg [24:0] O_ddr_user_addr,
    input wire I_ddr_user_ready,I_ddr_user_rd_valid,
    input wire [127:0] I_ddr_user_rd_data,
    input wire I_dsi_clk,I_video_vsync,I_video_rd_en,
    output reg [23:0] O_vdieo_data
);
    localparam FRAME_WORDS=WIDTH*HEIGHT*3/16;
    // Existing FIFO has 511 usable entries. Write-domain occupancy
    // conservatively lags pixel reads. Keep margin and bounded read bursts.
    localparam READ_BURST=64,FIFO_BUDGET=448;
    wire [2:0] pixel_metadata;
    wire display_id_valid;
    (* ASYNC_REG="TRUE" *) reg S_video_vsync_1d,S_video_vsync_2d;
    reg S_video_vsync_3d;
    wire S_video_frame_start=S_video_vsync_2d && !S_video_vsync_3d;
    // ID is latched on exactly the same DDR VS edge as bank/valid/mode.
    // A newer published bank during active video cannot relabel this frame.
    generate if(FRAME_ID_ENABLE) begin:g_frame_id
        reg [31:0] read_id,display_id;reg read_id_valid,shown_id_valid;wire [35:0] received;
        always @(posedge I_ddr_clk or negedge I_rst_n)
            if(!I_rst_n) begin read_id<=0;read_id_valid<=0;end
            else if(S_video_frame_start) begin read_id<=I_frame_id;read_id_valid<=I_frame_id_valid;end
        view_mode_cdc #(.BITS(36)) u_metadata(.src_clk(I_ddr_clk),.dst_clk(I_dsi_clk),.reset_n(I_rst_n),
            .value({read_id_valid,read_id,O_read_metadata}),.received(received));
        assign pixel_metadata=received[2:0];
        always @(posedge I_dsi_clk or negedge I_rst_n)
            if(!I_rst_n) begin display_id<=0;shown_id_valid<=0;end
            else if(!I_video_rd_en) begin display_id<=received[34:3];shown_id_valid<=received[35];end
        assign O_display_frame_id=display_id;
        assign display_id_valid=shown_id_valid;
    end else begin:g_no_frame_id
        view_mode_cdc #(.BITS(3)) u_metadata(.src_clk(I_ddr_clk),.dst_clk(I_dsi_clk),.reset_n(I_rst_n),
            .value(O_read_metadata),.received(pixel_metadata));
        assign O_display_frame_id=32'd0;
        assign display_id_valid=1'b1;
    end endgenerate
    always @(posedge I_dsi_clk or negedge I_rst_n)
        if(!I_rst_n) O_display_metadata<=0;
        else if(!I_video_rd_en) O_display_metadata<=pixel_metadata;
    always @(posedge I_ddr_clk or negedge I_rst_n)
        if(!I_rst_n) begin S_video_vsync_1d<=0;S_video_vsync_2d<=0;S_video_vsync_3d<=0;end
        else begin S_video_vsync_1d<=I_video_vsync;S_video_vsync_2d<=S_video_vsync_1d;S_video_vsync_3d<=S_video_vsync_2d;end

    reg [17:0] read_words;
    reg [9:0] outstanding;
    reg S_fifo_rst,S_ddr_rd_valid,overflow_frame,pixel_fault;
    reg [3:0] S_fifo_rst_cnt;
    reg [5:0] S_ddr_rd_cnt;
    wire [8:0] S_fifo_wr_num;
    wire [127:0] S_fifo_rd_data;
    wire S_fifo_full,S_fifo_emtpy,S_fifo_valid,S_fifo_rd_en;
    wire [10:0] reserved_words={2'b0,S_fifo_wr_num}+{1'b0,outstanding};
    (* ASYNC_REG="TRUE" *) reg [1:0] fault_sync,overflow_sync,fifo_reset_sync;
    assign O_display_good=display_id_valid && O_display_metadata[2] && !pixel_fault && !overflow_sync[1] && !fifo_reset_sync[1];
    // Saturating diagnostics for simulation and optional on-board capture.
    reg [15:0] fifo_underflow_frames;
    reg [15:0] fifo_overflow_frames;
    reg [15:0] discarded_returns;
    function [24:0] base;
        input [1:0] bank;
        begin case(bank)
            0:base=0;1:base=7000000;2:base=14000000;default:base=21000000;
        endcase end
    endfunction
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin O_read_bank<=0;O_read_metadata<=0;read_words<=0;O_ddr_user_addr<=0;end
        else if(S_video_frame_start) begin
            O_read_bank<=I_video_out_rp;O_read_metadata<={I_frame_valid,I_frame_mode};
            read_words<=0;O_ddr_user_addr<=base(I_video_out_rp);
        end else if(O_ddr_user_rd_en) begin
            read_words<=read_words+1'b1;O_ddr_user_addr<=O_ddr_user_addr+25'd8;
        end
    end
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin S_fifo_rst<=1;S_fifo_rst_cnt<=0;end
        else if(S_video_frame_start) begin S_fifo_rst<=1;S_fifo_rst_cnt<=0;end
        else if(S_fifo_rst) begin
            if(S_fifo_rst_cnt<15) S_fifo_rst_cnt<=S_fifo_rst_cnt+1'b1;
            // Outstanding transactions survive VS. Discard old responses
            // while reset is held, then reopen the FIFO for the new frame.
            else if(outstanding==0 && !I_ddr_user_rd_valid) S_fifo_rst<=0;
        end
    end
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin outstanding<=0;fault_sync<=0;overflow_frame<=0;fifo_overflow_frames<=0;discarded_returns<=0;end
        else begin
            fault_sync<={fault_sync[0],pixel_fault};
            case({O_ddr_user_rd_en,I_ddr_user_rd_valid && outstanding!=0})
                2'b10: outstanding<=outstanding+1'b1;
                2'b01: outstanding<=outstanding-1'b1;
                default: ;
            endcase
            if(S_video_frame_start) overflow_frame<=0;
            else if(I_ddr_user_rd_valid && !S_fifo_rst && S_fifo_full) begin
                overflow_frame<=1;
                if(!overflow_frame && fifo_overflow_frames!=16'hffff) fifo_overflow_frames<=fifo_overflow_frames+1'b1;
            end
            if(I_ddr_user_rd_valid && (S_fifo_rst || S_video_frame_start || outstanding==0) && discarded_returns!=16'hffff)
                discarded_returns<=discarded_returns+1'b1;
        end
    end
    // Include commands still waiting inside mc_to_user_interface.
    wire S_ddr_rd_trig=reserved_words<=FIFO_BUDGET-READ_BURST &&
        !I_video_in_wr_busy && !S_ddr_rd_valid && !S_fifo_rst && !S_video_frame_start &&
        !fault_sync[1] && !overflow_frame && I_rst_n && O_read_metadata[2] && read_words<FRAME_WORDS;
    assign O_ddr_user_rd_en=S_ddr_rd_valid && I_ddr_user_ready && !S_video_frame_start &&
        !S_fifo_rst && !fault_sync[1] && !overflow_frame && reserved_words<FIFO_BUDGET;
    assign O_video_out_rd_busy=S_ddr_rd_trig || S_ddr_rd_valid;
    always @(posedge I_ddr_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin S_ddr_rd_valid<=0;S_ddr_rd_cnt<=0;end
        else if(S_video_frame_start || S_fifo_rst || fault_sync[1] || overflow_frame) begin
            S_ddr_rd_valid<=0;S_ddr_rd_cnt<=0;
        end else if(O_ddr_user_rd_en) begin
            if(S_ddr_rd_cnt==READ_BURST-1 || read_words==FRAME_WORDS-1) begin
                S_ddr_rd_valid<=0;S_ddr_rd_cnt<=0;
            end else S_ddr_rd_cnt<=S_ddr_rd_cnt+1'b1;
        end else if(S_ddr_rd_trig) begin S_ddr_rd_valid<=1;S_ddr_rd_cnt<=0;end
    end
    w128_d512_fifo U_w128_d512_fifo(
        .rst(S_fifo_rst),.clkw(I_ddr_clk),
        .we(I_ddr_user_rd_valid && outstanding!=0 && !S_fifo_rst && !S_video_frame_start && !S_fifo_full),
        .di(I_ddr_user_rd_data),.wrusedw(S_fifo_wr_num),.afull(),.full_flag(S_fifo_full),
        .clkr(I_dsi_clk),.re(S_fifo_rd_en),.dout(S_fifo_rd_data),.rdusedw(),
        .valid(S_fifo_valid),.empty_flag(S_fifo_emtpy),.aempty());

    reg pixel_vs_d,S_video_rd_en_1d;
    reg [3:0] S_fifo_rd_cnt,S_fifo_rd_cnt_1d;
    reg [127:0] S_fifo_rd_data_1d;
    wire word_phase=S_fifo_rd_cnt==0 || S_fifo_rd_cnt==5 || S_fifo_rd_cnt==10;
    wire word_phase_d=S_fifo_rd_cnt_1d==0 || S_fifo_rd_cnt_1d==5 || S_fifo_rd_cnt_1d==10;
    wire missing_word=(I_video_rd_en && (fifo_reset_sync[1] || (word_phase && S_fifo_emtpy))) ||
                      (S_video_rd_en_1d && word_phase_d && !S_fifo_valid);
    // HDMI cannot stall. Black the rest of a damaged frame, preserve sync,
    // and re-align at VS instead of repeating old data at new pixel positions.
    always @(posedge I_dsi_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            pixel_vs_d<=0;fifo_reset_sync<=3;overflow_sync<=0;pixel_fault<=0;fifo_underflow_frames<=0;
        end else begin
            pixel_vs_d<=I_video_vsync;
            fifo_reset_sync<={fifo_reset_sync[0],S_fifo_rst};
            overflow_sync<={overflow_sync[0],overflow_frame};
            if(I_video_vsync && !pixel_vs_d) pixel_fault<=0;
            else if(pixel_metadata[2] && !pixel_fault && (missing_word || (I_video_rd_en && overflow_sync[1]))) begin
                pixel_fault<=1;
                if(missing_word && fifo_underflow_frames!=16'hffff) fifo_underflow_frames<=fifo_underflow_frames+1'b1;
            end
        end
    end
    assign S_fifo_rd_en=I_video_rd_en && word_phase && pixel_metadata[2] &&
        !pixel_fault && !overflow_sync[1] && !fifo_reset_sync[1] && !S_fifo_emtpy;
    always @(posedge I_dsi_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin S_fifo_rd_cnt<=0;S_video_rd_en_1d<=0;S_fifo_rd_cnt_1d<=0;S_fifo_rd_data_1d<=0;end
        else begin
            if(I_video_rd_en) S_fifo_rd_cnt<=S_fifo_rd_cnt+1'b1;else S_fifo_rd_cnt<=0;
            S_video_rd_en_1d<=I_video_rd_en;S_fifo_rd_cnt_1d<=S_fifo_rd_cnt;S_fifo_rd_data_1d<=S_fifo_rd_data;
        end
    end
    // Preserve the original 16 pixels / three 128-bit words packing and latency.
    always @(posedge I_dsi_clk or negedge I_rst_n) begin
        if(!I_rst_n) O_vdieo_data<=0;
        else if(S_video_rd_en_1d && pixel_metadata[2] && !pixel_fault && !overflow_sync[1] &&
                !fifo_reset_sync[1] && !(word_phase_d && !S_fifo_valid)) begin
            case(S_fifo_rd_cnt_1d)
                0: O_vdieo_data<=S_fifo_rd_data[127:104];
                1: O_vdieo_data<=S_fifo_rd_data[103:80];
                2: O_vdieo_data<=S_fifo_rd_data[79:56];
                3: O_vdieo_data<=S_fifo_rd_data[55:32];
                4: O_vdieo_data<=S_fifo_rd_data[31:8];
                5: O_vdieo_data<={S_fifo_rd_data_1d[7:0],S_fifo_rd_data[127:112]};
                6: O_vdieo_data<=S_fifo_rd_data[111:88];
                7: O_vdieo_data<=S_fifo_rd_data[87:64];
                8: O_vdieo_data<=S_fifo_rd_data[63:40];
                9: O_vdieo_data<=S_fifo_rd_data[39:16];
                10: O_vdieo_data<={S_fifo_rd_data_1d[15:0],S_fifo_rd_data[127:120]};
                11: O_vdieo_data<=S_fifo_rd_data[119:96];
                12: O_vdieo_data<=S_fifo_rd_data[95:72];
                13: O_vdieo_data<=S_fifo_rd_data[71:48];
                14: O_vdieo_data<=S_fifo_rd_data[47:24];
                15: O_vdieo_data<=S_fifo_rd_data[23:0];
            endcase
        end else O_vdieo_data<=0;
    end
endmodule

// Latency observer modules live in this established TD compilation unit.
// The final1_latency.v compatibility entry deliberately has no definitions.
// Passive RAW SOF -> first active pixel at hdmi_tx input measurement.
// Both events are timestamped on receipt in measure_clk (100 MHz): 1 us
// quantization plus the small difference between the two mailbox CDC delays.
// This does not measure exposure, TMDS serialization or the display panel.
module final1_latency #(parameter CLOCK_HZ=100000000,
    parameter REFRESH_US=1000000, parameter FRESH_US=1000000)(
    input capture_clk,measure_clk,pixel_clk,rst_n,
    input capture_sof,input [31:0] capture_id,
    input display_vs,display_de,display_good,input [31:0] display_id,
    output [88:0] hud_data,output hud_valid
);
    wire crn,mrn,prn;
    final1_reset_release u_cr(.clk(capture_clk),.async_reset_n(rst_n),.reset_n(crn));
    final1_reset_release u_mr(.clk(measure_clk),.async_reset_n(rst_n),.reset_n(mrn));
    final1_reset_release u_pr(.clk(pixel_clk),.async_reset_n(rst_n),.reset_n(prn));
    wire cap_ready,cap_valid,disp_ready,disp_valid;
    wire [31:0] cap_id;wire [32:0] disp_data;
    reg vs_d,active_seen;
    wire display_event=prn && display_de && !active_seen && !display_vs;
    // Events must never silently overwrite an in-flight frame. A pathological
    // overrun makes readings invalid until shared reset; video is unaffected.
    reg cap_overrun,disp_overrun;
    always @(posedge capture_clk or negedge crn)
        if(!crn) cap_overrun<=0;
        else if(capture_sof && !cap_ready) cap_overrun<=1;
    always @(posedge pixel_clk or negedge prn)
        if(!prn) begin vs_d<=0;active_seen<=1;disp_overrun<=0;end
        else begin
            vs_d<=display_vs;
            if(display_vs && !vs_d) active_seen<=0;
            else if(display_event) active_seen<=1;
            if(display_event && !disp_ready) disp_overrun<=1;
        end
    final1_mailbox #(.WIDTH(32)) u_capture(.src_clk(capture_clk),.dst_clk(measure_clk),.rst_n(rst_n),
        .send(capture_sof && crn),.data(capture_id),.ready(cap_ready),.valid(cap_valid),.received(cap_id));
    final1_mailbox #(.WIDTH(33)) u_display(.src_clk(pixel_clk),.dst_clk(measure_clk),.rst_n(rst_n),
        .send(display_event),.data({display_good,display_id}),.ready(disp_ready),.valid(disp_valid),.received(disp_data));
    (* ASYNC_REG="TRUE" *) reg [1:0] over_meta,over_sync;
    always @(posedge measure_clk or negedge mrn)
        if(!mrn) begin over_meta<=0;over_sync<=0;end
        else begin over_meta<={cap_overrun,disp_overrun};over_sync<=over_meta;end

    localparam US_DIV=CLOCK_HZ/1000000;
    localparam DIV_BITS=US_DIV>1?$clog2(US_DIV):1;
    reg [DIV_BITS-1:0] us_div;reg [31:0] now_us;
    reg [19:0] refresh_count;
    wire [19:0] fresh_count;
    wire us_tick=us_div==US_DIV-1;
    wire refresh_tick=us_tick && refresh_count==REFRESH_US-1;
    wire fresh_tick=us_tick && fresh_count==FRESH_US-1;
    // Equal production periods share a counter. Unequal parameters retain
    // the original independent expiry counter and exact tick timing.
    generate if(REFRESH_US==FRESH_US) begin:g_shared_fresh
        assign fresh_count=refresh_count;
    end else begin:g_separate_fresh
        reg [19:0] count;
        assign fresh_count=count;
        always @(posedge measure_clk or negedge mrn)
            if(!mrn) count<=0;
            else if(us_tick) count<=fresh_tick?20'd0:count+1'b1;
    end endgenerate
    always @(posedge measure_clk or negedge mrn)
        if(!mrn) begin us_div<=0;now_us<=0;refresh_count<=0;end
        else if(us_tick) begin
            us_div<=0;now_us<=now_us+1'b1;
            refresh_count<=refresh_tick?20'd0:refresh_count+1'b1;
        end else us_div<=us_div+1'b1;

    // 16 x 64 distributed RAM; NEVER reset the RAM array. Full IDs prevent
    // ring alias. Two freshness masks expire unused entries within 2 seconds,
    // even if the camera stops, so a 32-bit us timer wrap cannot revive them.
    (* ram_style="dram" *) reg [63:0] stamps[0:15];
    reg [15:0] recent,previous;
    wire [15:0] cap_bit=16'b1<<cap_id[3:0];
    always @(posedge measure_clk)
        if(mrn && cap_valid) stamps[cap_id[3:0]]<={cap_id,now_us};
    // received holds the latest capture ID. The old design forwarded cap_id
    // on cap_valid and otherwise held the same value in a redundant register.
    wire [31:0] newest_id=cap_id;reg capture_seen;
    always @(posedge measure_clk or negedge mrn)
        if(!mrn) begin recent<=0;previous<=0;capture_seen<=0;end
        else begin
            if(fresh_tick) begin previous<=recent;recent<=cap_valid?cap_bit:16'd0;end
            else if(cap_valid) recent<=recent|cap_bit;
            if(cap_valid) capture_seen<=1;
        end

    reg lookup_pending,lookup_good,lookup_in_valid,lookup_hit;
    reg [31:0] lookup_id,lookup_in,lookup_time,lookup_stamp;
    wire [63:0] table_word=stamps[disp_data[3:0]];
    wire table_hit=(recent[disp_data[3:0]] || previous[disp_data[3:0]]) &&
        table_word[63:32]==disp_data[31:0];
    // Retain the displayed timestamp across arbitrary repeated frames, even
    // after its ring slot is overwritten. Sticky saturation prevents wrapback.
    reg cache_valid,cache_saturated;reg [31:0] cache_id,cache_stamp;
    wire [31:0] cache_age=now_us-cache_stamp;
    wire [31:0] elapsed=lookup_time-lookup_stamp;
    wire [31:0] frame_delta=lookup_in-lookup_id;
    wire repeat_hit=cache_valid && cache_id==lookup_id;
    wire matched=lookup_good && lookup_hit && lookup_in_valid && !frame_delta[31] && !(|over_sync);
    reg sample_pulse;
    // The display mailbox cannot deliver in consecutive measure_clk cycles.
    // lookup IDs stay stable through sample_pulse consumption, so keep only
    // the arithmetic/flags stage instead of another two full ID registers.
    wire [31:0] sample_in=lookup_in,sample_out=lookup_id;
    reg [9:0] sample_fd;
    reg [19:0] sample_us;
    reg [4:0] sample_flags;
    always @(posedge measure_clk or negedge mrn)
        if(!mrn) begin
            lookup_pending<=0;lookup_good<=0;lookup_in_valid<=0;lookup_hit<=0;
            lookup_id<=0;lookup_in<=0;lookup_time<=0;lookup_stamp<=0;
            cache_valid<=0;cache_saturated<=0;cache_id<=0;cache_stamp<=0;
            sample_pulse<=0;sample_fd<=0;sample_us<=0;sample_flags<=0;
        end else begin
            lookup_pending<=disp_valid;sample_pulse<=lookup_pending;
            if(cache_valid && us_tick && cache_age>32'd999999) cache_saturated<=1;
            if(disp_valid) begin
                lookup_id<=disp_data[31:0];lookup_good<=disp_data[32];lookup_time<=now_us;
                lookup_in<=cap_valid?cap_id:newest_id;lookup_in_valid<=capture_seen || cap_valid;
                // Explicit same-edge bypass avoids dependence on RAM collision mode.
                if(cap_valid && cap_id==disp_data[31:0]) begin lookup_stamp<=now_us;lookup_hit<=1;end
                else if(cache_valid && cache_id==disp_data[31:0]) begin lookup_stamp<=cache_stamp;lookup_hit<=1;end
                else begin lookup_stamp<=table_word[31:0];lookup_hit<=table_hit;end
            end
            if(lookup_pending) begin
                sample_fd<=frame_delta>999?10'd999:frame_delta[9:0];
                sample_us<=((repeat_hit && cache_saturated) || elapsed>999999)?20'd999999:elapsed[19:0];
                // {IN valid, OUT valid, FD/LAT valid, FD overflow, LAT overflow}
                sample_flags<={lookup_in_valid && !over_sync[1],lookup_good && !over_sync[0],matched,
                    frame_delta>999,(repeat_hit && cache_saturated) || elapsed>999999};
                if(matched) begin
                    cache_valid<=1;cache_id<=lookup_id;cache_stamp<=lookup_stamp;
                    cache_saturated<=(repeat_hit && cache_saturated) || elapsed>999999;
                end
            end
        end

    // One shared 6-digit double-dabble engine, 32 cycles per field.
    // IN/OUT display the low six decimal digits; full 32-bit IDs are matched.
    // FD and LAT saturate, with a '+' glyph when the numeric range is exceeded.
    reg [1:0] format_state,field;reg [5:0] bit_count;
    // In-place workspace: unconsumed binary data precedes completed BCD.
    // Consume 32/32/10/20 bits and append 24/24/12/24 BCD bits, respectively.
    // At completion packet={IN_BCD,OUT_BCD,FD_BCD,LAT_BCD,10'b0}.
    // Reuses the workspace as the held mailbox payload; no result copy.
    reg [93:0] packet;
    reg [4:0] packet_flags;
    reg [23:0] bcd,bcd_adjust;
    reg refresh_pending;integer digit_index;
    wire binary_bit=field<2 || (field==2 && bit_count>=22) ||
                    (field==3 && bit_count>=12);
    wire [88:0] hud_packet={packet_flags,packet[93:10]};
    wire hud_ready;wire hud_send=format_state==2 && hud_ready;
    always @* begin
        bcd_adjust=bcd;
        for(digit_index=0;digit_index<6;digit_index=digit_index+1)
            if(bcd[digit_index*4+:4]>=5) bcd_adjust[digit_index*4+:4]=bcd[digit_index*4+:4]+4'd3;
    end
    wire [23:0] bcd_next={bcd_adjust[22:0],binary_bit && packet[93]};
    always @(posedge measure_clk or negedge mrn)
        if(!mrn) begin
            format_state<=0;field<=0;bit_count<=0;bcd<=0;packet<=0;packet_flags<=0;refresh_pending<=1;
        end else begin
            if(refresh_tick) refresh_pending<=1;
            case(format_state)
                0:if(refresh_pending && sample_pulse && hud_ready) begin
                    packet<={sample_in,sample_out,sample_fd,sample_us};
                    packet_flags<=sample_flags;field<=0;bit_count<=0;bcd<=0;
                    format_state<=1;refresh_pending<=0;
                end
                1:begin
                    if(binary_bit) packet<={packet[92:0],1'b0};
                    bcd<=bcd_next;
                    if(bit_count==31) begin
                        case(field)
                            0:packet[31:8]<=bcd_next;
                            1:packet[39:16]<=bcd_next;
                            2:packet[25:14]<=bcd_next[11:0];
                            3:packet[33:10]<=bcd_next;
                        endcase
                        bit_count<=0;bcd<=0;field<=field+1'b1;
                        if(field==3) format_state<=2;
                    end else bit_count<=bit_count+1'b1;
                end
                2:if(hud_ready) format_state<=3;
                3:if(hud_ready) format_state<=0;
            endcase
        end
    // packet remains held until the destination acknowledges; no duplicate
    // source payload register is needed for this low-rate HUD transfer.
    final1_mailbox #(.WIDTH(89),.EXTERNAL_HOLD(1)) u_hud(.src_clk(measure_clk),.dst_clk(pixel_clk),.rst_n(rst_n),
        .send(hud_send),.data(hud_packet),.ready(hud_ready),.valid(hud_valid),.received(hud_data));
endmodule

// A MCU/HDMI reset can leave the final DDR writer/reader and an old image alive.
// Wait for a NEW completed publication, then two output VS edges. The first VS
// could follow a reader bank selection made just before that publication; by
// the second VS the old epoch has drained. This guard never controls video.
module final1_latency_epoch_gate(
    input ddr_clk,pixel_clk,rst_n,input [1:0] published_bank,
    input frame_valid,display_vs,output reg published,output display_armed
);
    wire drn,prn;
    final1_reset_release u_dr(.clk(ddr_clk),.async_reset_n(rst_n),.reset_n(drn));
    final1_reset_release u_pr(.clk(pixel_clk),.async_reset_n(rst_n),.reset_n(prn));
    reg [1:0] last_bank;reg initialized;
    always @(posedge ddr_clk or negedge drn)
        if(!drn) begin last_bank<=0;initialized<=0;published<=0;end
        else begin
            last_bank<=published_bank;initialized<=1;
            if(initialized && frame_valid && published_bank!=last_bank) published<=1;
        end
    (* ASYNC_REG="TRUE" *) reg [1:0] fresh_sync;
    reg [1:0] arm_pipe;reg vs_d;
    always @(posedge pixel_clk or negedge prn)
        if(!prn) begin fresh_sync<=0;arm_pipe<=0;vs_d<=0;end
        else begin
            fresh_sync<={fresh_sync[0],published};vs_d<=display_vs;
            if(display_vs && !vs_d) arm_pipe<={arm_pipe[0],fresh_sync[1]};
        end
    assign display_armed=arm_pipe[1];
endmodule
