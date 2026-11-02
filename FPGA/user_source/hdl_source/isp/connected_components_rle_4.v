// Run-length exact 4-connected CCL, four binary pixels per accepted beat.
// Bit 3 is leftmost. Zero-based inclusive bbox. Sorted adjacent-row run sweep.
// Errors: [0] labels, [1] targets, [2] framing, [3] runs per row.
// Input may be stalled while runs are linked. Upstream MUST respect ready.
// No partial results on error; complete frame drained before done. No resync.
module connected_components_rle_4 #(
    parameter WIDTH=1280, HEIGHT=720, MIN_AREA=100,
    parameter MAX_LABELS=255, MAX_TARGETS=64, MAX_RUNS=(WIDTH+1)/2,
    parameter LW=$clog2(MAX_LABELS+1), RW=$clog2(MAX_RUNS+1)
)(
    input wire clk,rst_n,
    input wire [3:0] s_tdata,
    input wire s_tvalid,s_tuser,s_tlast,
    output wire s_tready,
    output reg target_valid,
    input wire target_ready,
    output reg [LW-1:0] target_id,
    output reg [19:0] target_area,
    output reg [10:0] target_xmin,target_xmax,
    output reg [9:0] target_ymin,target_ymax,
    output reg done_valid,
    input wire done_ready,
    output reg [15:0] target_count,
    output reg [3:0] frame_error
);
    localparam SCAN_WORD=0, START_RUN=1, PREV_READ=2, PREV_GOT=3,
        ROOT_READ=4, ROOT_GOT=5, UNION=6,
        ASSIGN_RUN=8, NEW_LABEL=9, STAT_READ=10, STAT_WRITE=11,
        STORE_RUN=12, GROUP_NEXT=13, END_LINE=14,
        FOLD_READ=15,FOLD_GOT=16,PARENT_STAT_READ=17,FOLD_WRITE=18,FOLD_NEXT=19,
        COUNT_READ=20,COUNT_GOT=21,EMIT_READ=22,EMIT_GOT=23,EMIT_WAIT=24,FINISH=25;
    reg [4:0] state;
    reg [10:0] x;
    reg [9:0] y;
    reg run_open,group_eol,bank;
    reg [10:0] open_start;
    reg [10:0] pending_start[0:2],pending_end[0:2];
    reg [1:0] pending_count, pending_index;
    reg [10:0] run_a,run_b;
    reg [RW-1:0] prev_count,curr_count,prev_index;
    reg [LW-1:0] labels,selected,cursor,merge_child,scan,fold_parent;
    reg [61:0] child_stats;
    reg [15:0] count_work;

    // Unroll exactly four pixels. At most three closures: a carried run,
    // another interior run, and a run closed at the final pixel of a row.
    reg ex_open;
    reg [10:0] ex_start;
    reg [1:0] ex_count;
    reg [10:0] ex_a[0:2],ex_b[0:2];
    integer lane;
    always @* begin
        ex_open=run_open; ex_start=open_start; ex_count=0;
        for(lane=0;lane<3;lane=lane+1) begin ex_a[lane]=0; ex_b[lane]=0; end
        for(lane=0;lane<4;lane=lane+1) begin
            if(s_tdata[3-lane] && !ex_open) begin
                ex_open=1; ex_start=x+lane;
            end else if(!s_tdata[3-lane] && ex_open) begin
                ex_a[ex_count]=ex_start; ex_b[ex_count]=x+lane-1;
                ex_count=ex_count+1'b1; ex_open=0;
            end
        end
        if(x==WIDTH-4 && ex_open) begin
            ex_a[ex_count]=ex_start; ex_b[ex_count]=WIDTH-1;
            ex_count=ex_count+1'b1; ex_open=0;
        end
    end
    wire framing_bad=(s_tuser!=((x==0)&&(y==0))) || (s_tlast!=(x==WIDTH-4));
    wire [19:0] run_length={9'd0,run_b}-{9'd0,run_a}+20'd1;
    wire [61:0] run_stats={run_length,run_a,run_b,y,y};
    assign s_tready=rst_n && state==SCAN_WORD;

    reg row_re,row_we,par_re,par_we,stat_re,stat_we;
    reg [RW:0] row_addr;
    reg [LW-1:0] par_addr,par_data,stat_addr;
    reg [61:0] stat_data;
    wire [LW+21:0] row_q;
    wire [10:0] prev_a=row_q[LW+21:LW+11];
    wire [10:0] prev_b=row_q[LW+10:LW];
    wire [LW-1:0] prev_label=row_q[LW-1:0];
    wire [LW-1:0] par_q;
    wire [61:0] stat_q;
    ccl_rle_sync_ram #(.DW(LW+22),.AW(RW+1)) u_runs(
        .clk(clk),.re(row_re),.we(row_we),.addr(row_addr),.din({run_a,run_b,selected}),.q(row_q));
    ccl_rle_sync_ram #(.DW(LW),.AW(LW)) u_parent(
        .clk(clk),.re(par_re),.we(par_we),.addr(par_addr),.din(par_data),.q(par_q));
    ccl_rle_sync_ram #(.DW(62),.AW(LW)) u_stats(
        .clk(clk),.re(stat_re),.we(stat_we),.addr(stat_addr),.din(stat_data),.q(stat_q));
    // Record = {area[19:0], xmin[10:0], xmax[10:0], ymin[9:0], ymax[9:0]}.
    function [61:0] combine;
        input [61:0] a,b;
        begin
            combine={a[61:42]+b[61:42],
                (a[41:31]<b[41:31]?a[41:31]:b[41:31]),
                (a[30:20]>b[30:20]?a[30:20]:b[30:20]),
                (a[19:10]<b[19:10]?a[19:10]:b[19:10]),
                (a[9:0]>b[9:0]?a[9:0]:b[9:0])};
        end
    endfunction

    always @* begin
        row_re=0; row_we=0; row_addr=0;
        par_re=0; par_we=0; par_addr=0; par_data=0;
        stat_re=0; stat_we=0; stat_addr=0; stat_data=0;
        if(rst_n) case(state)
            PREV_READ: if(prev_index<prev_count) begin row_re=1; row_addr={!bank,prev_index}; end
            ROOT_READ: begin par_re=1; par_addr=cursor; end
            UNION: begin par_we=1; par_addr=merge_child; par_data=selected; end
            NEW_LABEL: begin
                par_we=1; par_addr=selected; par_data=selected;
                stat_we=1; stat_addr=selected; stat_data=run_stats;
            end
            STAT_READ: begin stat_re=1; stat_addr=selected; end
            STAT_WRITE: begin stat_we=1; stat_addr=selected; stat_data=combine(stat_q,run_stats); end
            STORE_RUN: begin row_we=1; row_addr={bank,curr_count}; end
            FOLD_READ,COUNT_READ,EMIT_READ: begin
                par_re=1; par_addr=scan; stat_re=1; stat_addr=scan;
            end
            PARENT_STAT_READ: begin stat_re=1; stat_addr=fold_parent; end
            FOLD_WRITE: begin stat_we=1; stat_addr=fold_parent; stat_data=combine(stat_q,child_stats); end
            default: begin end
        endcase
    end
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=SCAN_WORD; x<=0; y<=0; run_open<=0; open_start<=0;
            group_eol<=0; bank<=0; prev_count<=0; curr_count<=0; prev_index<=0;
            pending_count<=0; pending_index<=0; run_a<=0; run_b<=0;
            for(k=0;k<3;k=k+1) begin pending_start[k]<=0; pending_end[k]<=0; end
            labels<=0; selected<=0; cursor<=0; merge_child<=0; scan<=0; fold_parent<=0;
            child_stats<=0; count_work<=0; target_count<=0; frame_error<=0;
            target_valid<=0; target_id<=0; target_area<=0;
            target_xmin<=0; target_xmax<=0; target_ymin<=0; target_ymax<=0; done_valid<=0;
        end else case(state)
            SCAN_WORD: if(s_tvalid) begin
                group_eol<=(x==WIDTH-4); x<=x==WIDTH-4?0:x+11'd4;
                if(framing_bad) frame_error[2]<=1;
                if(frame_error!=0 || framing_bad) begin
                    run_open<=0;
                    if(x==WIDTH-4) state<=END_LINE;
                end else begin
                    run_open<=ex_open; open_start<=ex_start;
                    pending_count<=ex_count; pending_index<=0;
                    for(k=0;k<3;k=k+1) begin pending_start[k]<=ex_a[k]; pending_end[k]<=ex_b[k]; end
                    if(ex_count!=0) state<=START_RUN;
                    else if(x==WIDTH-4) state<=END_LINE;
                end
            end
            START_RUN: begin
                run_a<=pending_start[pending_index]; run_b<=pending_end[pending_index]; selected<=0;
                if(curr_count==MAX_RUNS) begin frame_error[3]<=1; state<=GROUP_NEXT; end
                else state<=PREV_READ;
            end
            PREV_READ: state<=prev_index<prev_count?PREV_GOT:(selected==0?ASSIGN_RUN:STAT_READ);
            PREV_GOT: begin
                if(prev_b<run_a) begin prev_index<=prev_index+1'b1; state<=PREV_READ; end
                else if(prev_a>run_b) state<=selected==0?ASSIGN_RUN:STAT_READ;
                else begin cursor<=prev_label; state<=ROOT_READ; end
            end
            ROOT_READ: state<=ROOT_GOT;
            ROOT_GOT: begin
                if(par_q!=cursor) begin cursor<=par_q; state<=ROOT_READ; end
                else if(selected!=0 && selected!=cursor) begin
                    merge_child<=selected>cursor?selected:cursor;
                    selected<=selected<cursor?selected:cursor; state<=UNION;
                end else begin
                    selected<=cursor;
                    if(prev_b<=run_b) begin prev_index<=prev_index+1'b1; state<=PREV_READ; end
                    else state<=STAT_READ;
                end
            end
            UNION: begin
                if(prev_b<=run_b) begin prev_index<=prev_index+1'b1; state<=PREV_READ; end
                else state<=STAT_READ;
            end
            ASSIGN_RUN: begin
                if(selected==0) begin
                    if(labels==MAX_LABELS) begin frame_error[0]<=1; state<=GROUP_NEXT; end
                    else begin labels<=labels+1'b1; selected<=labels+1'b1; state<=NEW_LABEL; end
                end else state<=STAT_READ;
            end
            NEW_LABEL: state<=STORE_RUN;
            STAT_READ: state<=STAT_WRITE;
            STAT_WRITE: state<=STORE_RUN;
            STORE_RUN: begin curr_count<=curr_count+1'b1; state<=GROUP_NEXT; end
            GROUP_NEXT: begin
                if(frame_error==0 && pending_index+1<pending_count) begin
                    pending_index<=pending_index+1'b1; state<=START_RUN;
                end else state<=group_eol?END_LINE:SCAN_WORD;
            end
            END_LINE: begin
                if(y==HEIGHT-1) begin
                    scan<=labels;
                    if(frame_error!=0 || labels==0) begin target_count<=0; state<=FINISH; end
                    else state<=FOLD_READ;
                end else begin
                    y<=y+1'b1; bank<=!bank;
                    prev_count<=curr_count; curr_count<=0; prev_index<=0; state<=SCAN_WORD;
                end
            end
            // Parent pointers strictly decrease. Folding in descending order
            // includes descendants before sending each record to its parent.
            FOLD_READ: state<=FOLD_GOT;
            FOLD_GOT: begin
                if(par_q!=scan) begin fold_parent<=par_q; child_stats<=stat_q; state<=PARENT_STAT_READ; end
                else state<=FOLD_NEXT;
            end
            PARENT_STAT_READ: state<=FOLD_WRITE;
            FOLD_WRITE: state<=FOLD_NEXT;
            FOLD_NEXT: begin
                if(scan==1) begin scan<=1; count_work<=0; state<=COUNT_READ; end
                else begin scan<=scan-1'b1; state<=FOLD_READ; end
            end
            COUNT_READ: state<=COUNT_GOT;
            COUNT_GOT: begin
                if(par_q==scan && stat_q[61:42]>=MIN_AREA) begin
                    if(count_work==MAX_TARGETS) begin
                        frame_error[1]<=1; target_count<=0; state<=FINISH;
                    end else begin
                        count_work<=count_work+1'b1;
                        if(scan==labels) begin target_count<=count_work+1'b1; scan<=1; state<=EMIT_READ; end
                        else begin scan<=scan+1'b1; state<=COUNT_READ; end
                    end
                end else if(scan==labels) begin
                    target_count<=count_work; scan<=1;
                    state<=(count_work==0)?FINISH:EMIT_READ;
                end else begin scan<=scan+1'b1; state<=COUNT_READ; end
            end
            EMIT_READ: state<=EMIT_GOT;
            EMIT_GOT: begin
                if(par_q==scan && stat_q[61:42]>=MIN_AREA) begin
                    target_id<=scan;
                    {target_area,target_xmin,target_xmax,target_ymin,target_ymax}<=stat_q;
                    target_valid<=1; state<=EMIT_WAIT;
                end else if(scan==labels) state<=FINISH;
                else begin scan<=scan+1'b1; state<=EMIT_READ; end
            end
            EMIT_WAIT: if(target_ready) begin
                target_valid<=0;
                if(scan==labels) state<=FINISH;
                else begin scan<=scan+1'b1; state<=EMIT_READ; end
            end
            FINISH: begin
                done_valid<=1;
                if(done_valid && done_ready) begin
                    done_valid<=0; target_count<=0; frame_error<=0;
                    x<=0; y<=0; labels<=0; run_open<=0; open_start<=0;
                    bank<=0; prev_count<=0; curr_count<=0; prev_index<=0; state<=SCAN_WORD;
                end
            end
            default: state<=SCAN_WORD;
        endcase
    end
    // synthesis translate_off
    initial begin
        if(WIDTH<4 || WIDTH>1280 || WIDTH%4!=0 || HEIGHT<1 || HEIGHT>720 ||
           MAX_LABELS<1 || MAX_LABELS>65535 || MAX_TARGETS<1 || MAX_TARGETS>65535 ||
           MAX_RUNS<1 || MAX_RUNS>640 || MIN_AREA<1 || MIN_AREA>921600 ||
           LW!=$clog2(MAX_LABELS+1) || RW!=$clog2(MAX_RUNS+1))
            $fatal(1,"Unsupported RLE configuration");
    end
    // synthesis translate_on
endmodule

module ccl_rle_sync_ram #(parameter DW=8,AW=8)(
    input wire clk,re,we,
    input wire [AW-1:0] addr,
    input wire [DW-1:0] din,
    output reg [DW-1:0] q
);
    (* ram_style="bram" *) reg [DW-1:0] mem[0:(1<<AW)-1];
    always @(posedge clk) begin
        if(we) mem[addr]<=din;
        if(re) q<=mem[addr];
    end
endmodule
