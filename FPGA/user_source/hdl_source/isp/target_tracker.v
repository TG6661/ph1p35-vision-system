// Completed-detection tracker. 8 slots, no frame RAM. Record format matches
// target_result_buffer[51:0]. Only observed tracks are emitted; missed tracks
// retain identity for two updates. Skipped camera frames never enter this module.
module target_tracker(
    input wire clk,rst_n,
    input wire s_valid, output wire s_ready,
    input wire [1:0] s_class,
    input wire [10:0] s_xmin,s_xmax,
    input wire [9:0] s_ymin,s_ymax,
    input wire s_geometry_error,
    input wire s_done_valid, output wire s_done_ready,
    input wire [15:0] s_count, input wire [3:0] s_error,
    output wire m_valid, input wire m_ready,
    output reg [51:0] m_record,
    output wire m_done_valid, input wire m_done_ready,
    output reg [15:0] m_count, output reg [3:0] m_error
);
    localparam COLLECT=0,LOAD=1,MEASURE=2,SCORE=3,SELECT=4,AGE=5,
        NEW_DET=6,FIND_SLOT=7,ID_SCAN=8,CREATE=9,EMIT_FIND=10,EMIT=11,DONE=12;
    reg [3:0] state,nr;
    reg [43:0] detections[0:7];
    reg [51:0] tracks[0:7];
    reg [1:0] missed[0:7];
    reg [7:0] active,matched,used,next_id;
    reg bad;
    reg [2:0] ti,di,best_t,best_d,index,new_slot;
    reg best_valid,slot_found,free_found;
    reg [1:0] oldest;
    reg [11:0] best_cost;
    reg [51:0] a;
    reg [43:0] b;
    reg eligible,shape_penalty;
    reg [10:0] dx,dy,aw,bw,ah,bh;
    wire [11:0] distance={1'b0,dx}+{1'b0,dy};
    wire [11:0] cost=distance+(shape_penalty?12'd32:12'd0);
    function [10:0] cx;
        input [43:0] r; reg [11:0] sum;
        begin sum={1'b0,r[41:31]}+{1'b0,r[30:20]}; cx=sum[11:1]; end
    endfunction
    function [9:0] cy;
        input [43:0] r; reg [10:0] sum;
        begin sum={1'b0,r[19:10]}+{1'b0,r[9:0]}; cy=sum[10:1]; end
    endfunction
    function [10:0] difference;
        input [10:0] p,q; begin difference=p>=q?p-q:q-p; end
    endfunction
    function [7:0] increment_id;
        input [7:0] id; begin increment_id=id==255?8'd1:id+1'b1; end
    endfunction
    assign s_ready=rst_n && state==COLLECT;
    assign s_done_ready=s_ready && !s_valid;
    assign m_valid=rst_n && state==EMIT;
    assign m_done_valid=rst_n && state==DONE;
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=COLLECT; nr<=0; active<=0; matched<=0; used<=0; next_id<=1; bad<=0;
            ti<=0; di<=0; best_t<=0; best_d<=0; index<=0; new_slot<=0;
            best_valid<=0; best_cost<=4095; slot_found<=0; free_found<=0; oldest<=0;
            a<=0; b<=0; eligible<=0; shape_penalty<=0; dx<=0; dy<=0; aw<=0; bw<=0; ah<=0; bh<=0;
            m_record<=0; m_count<=0; m_error<=0;
            for(k=0;k<8;k=k+1) begin tracks[k]<=0; missed[k]<=0; end
        end else case(state)
            COLLECT: begin
                if(s_valid) begin
                    if(nr<8) detections[nr[2:0]]<={s_class,s_xmin,s_xmax,s_ymin,s_ymax};
                    if(nr<9) nr<=nr+1'b1;
                    if(nr>=8 || s_geometry_error || s_class==3 || s_xmin>s_xmax ||
                        s_ymin>s_ymax || s_xmax>=1280 || s_ymax>=720) bad<=1;
                end else if(s_done_valid) begin
                    matched<=0; used<=0; m_count<=0; index<=0;
                    m_error<=s_error | ((bad || s_count!={12'b0,nr})?4'd8:4'd0);
                    if(s_error!=0 || bad || s_count!={12'b0,nr}) begin active<=0; state<=DONE; end
                    else begin ti<=0; di<=0; best_valid<=0; best_cost<=4095; state<=LOAD; end
                end
            end
            LOAD: begin
                a<=tracks[ti]; b<=detections[di];
                eligible<=active[ti] && !matched[ti] && !used[di] && {1'b0,di}<nr;
                state<=MEASURE;
            end
            MEASURE: begin
                dx<=difference(cx(a[43:0]),cx(b)); dy<=difference({1'b0,cy(a[43:0])},{1'b0,cy(b)});
                aw<=a[30:20]-a[41:31]+11'd1; bw<=b[30:20]-b[41:31]+11'd1;
                ah<={1'b0,a[9:0]}-{1'b0,a[19:10]}+11'd1; bh<={1'b0,b[9:0]}-{1'b0,b[19:10]}+11'd1;
                shape_penalty<=a[43:42]!=0 && b[43:42]!=0 && a[43:42]!=b[43:42];
                state<=SCORE;
            end
            SCORE: begin
                if(eligible && distance<=96 && {1'b0,aw}<={bw,1'b0} && {1'b0,bw}<={aw,1'b0} &&
                    {1'b0,ah}<={bh,1'b0} && {1'b0,bh}<={ah,1'b0} && cost<best_cost) begin
                    best_valid<=1; best_cost<=cost; best_t<=ti; best_d<=di;
                end
                if(di==7) begin
                    di<=0;
                    if(ti==7) state<=SELECT; else begin ti<=ti+1'b1; state<=LOAD; end
                end else begin di<=di+1'b1; state<=LOAD; end
            end
            SELECT: begin
                if(best_valid) begin
                    tracks[best_t]<={tracks[best_t][51:44],
                        detections[best_d][43:42]==0?tracks[best_t][43:42]:detections[best_d][43:42],detections[best_d][41:0]};
                    missed[best_t]<=0; matched[best_t]<=1; used[best_d]<=1;
                    best_valid<=0; best_cost<=4095; ti<=0; di<=0; state<=LOAD;
                end else begin index<=0; state<=AGE; end
            end
            AGE: begin
                if(active[index] && !matched[index]) begin
                    if(missed[index]>=2) active[index]<=0;
                    else missed[index]<=missed[index]+1'b1;
                end
                if(index==7) begin di<=0; state<=NEW_DET; end else index<=index+1'b1;
            end
            NEW_DET: begin
                if({1'b0,di}>=nr) begin index<=0; state<=EMIT_FIND; end
                else if(used[di]) begin
                    if(di==7) begin index<=0; state<=EMIT_FIND; end else di<=di+1'b1;
                end else begin index<=0; slot_found<=0; free_found<=0; oldest<=0; state<=FIND_SLOT; end
            end
            FIND_SLOT: begin
                if(!active[index] && !free_found) begin
                    slot_found<=1; free_found<=1; new_slot<=index;
                end else if(!free_found && !matched[index] && (!slot_found || missed[index]>oldest)) begin
                    slot_found<=1; new_slot<=index; oldest<=missed[index];
                end
                if(index==7) begin index<=0; state<=ID_SCAN; end else index<=index+1'b1;
            end
            ID_SCAN: begin
                if(active[index] && tracks[index][51:44]==next_id) begin next_id<=increment_id(next_id); index<=0; end
                else if(index==7) state<=CREATE; else index<=index+1'b1;
            end
            CREATE: begin
                if(slot_found) begin
                    tracks[new_slot]<={next_id,detections[di]}; next_id<=increment_id(next_id);
                    active[new_slot]<=1; matched[new_slot]<=1; missed[new_slot]<=0;
                end
                if(di==7) begin index<=0; state<=EMIT_FIND; end
                else begin di<=di+1'b1; state<=NEW_DET; end
            end
            EMIT_FIND: begin
                if(matched[index]) begin m_record<=tracks[index]; state<=EMIT; end
                else if(index==7) state<=DONE; else index<=index+1'b1;
            end
            EMIT: if(m_ready) begin
                m_count<=m_count+1'b1;
                if(index==7) state<=DONE; else begin index<=index+1'b1; state<=EMIT_FIND; end
            end
            DONE: if(m_done_ready) begin nr<=0; bad<=0; state<=COLLECT; end
            default: state<=COLLECT;
        endcase
    end
endmodule
