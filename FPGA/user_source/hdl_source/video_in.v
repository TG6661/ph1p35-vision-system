// Complete-frame DDR writer. Four banks: never write the current read bank or
// the latest published bank. Publication follows the final accepted DDR word.
// Camera start/mode is a held-bus transaction, acknowledged only at completion.
module video_in #(parameter WIDTH=1280,HEIGHT=720, ELASTIC=0, SYNC_RELEASE=0,
    parameter [24:0] BASE0=0,BASE1=7000000,BASE2=14000000,BASE3=21000000)(
    input wire [50:0] I_frame_tag,
    input wire [91:0] I_diagnostics,
    output reg [50:0] O_frame_tag,
    output reg [91:0] O_diagnostics,
    output reg [31:0] O_frame_sequence,
    input wire I_rst_n,I_camera_clk,I_camera_frame_start,I_camera_valid,
    input wire [127:0] I_camera_data,
    input wire [1:0] I_camera_mode,
    input wire I_camera_abort,I_mipi_rx_error,I_ddr_clk,I_display_pause,I_video_out_rd_busy,
    input wire [1:0] I_read_bank,
    output wire O_camera_ready,O_frame_ready,O_video_in_wr_busy,
    output reg [1:0] O_video_out_rp,O_frame_mode,
    output reg O_frame_valid,
    output reg O_ddr_user_wr_en,
    output reg [24:0] O_ddr_user_addr,
    output wire [127:0] O_ddr_user_wr_data,
    input wire I_ddr_user_ready,output reg O_capture_error
);
    localparam WORDS=WIDTH*HEIGHT*3/16;
    wire idle,srn,drn,pending;
    reg submit,ack_frame;
    reg [1:0] published;
    reg [50:0] published_tag;
    reg [91:0] published_diagnostics;
    reg [$clog2(WORDS+1)-1:0] source_words;
    target_result_cdc #(.SYNC_RELEASE(SYNC_RELEASE)) u_cdc(.src_clk(I_camera_clk),.dst_clk(I_ddr_clk),.reset_n(I_rst_n),
        .src_submit(submit),.src_idle(idle),.src_reset_n(srn),.dst_reset_n(drn),
        .dst_pending(pending),.dst_accept(ack_frame));
    reg source_busy,source_bad;
    reg [6:0] settle;
    reg [3:0] flush;
    wire fifo_reset=!I_rst_n || flush!=0;
    wire [8:0] used_write,used_read;
    wire fifo_full;
    assign O_frame_ready=idle && !submit && !source_busy;
    assign O_camera_ready=source_busy && settle>=32 && !source_bad && used_write<400 && !fifo_full;
    always @(posedge I_camera_clk or negedge srn) begin
        if(!srn) begin submit<=0;published<=0;published_tag<=0;published_diagnostics<=0;source_words<=0;source_busy<=0;source_bad<=0;settle<=0;flush<=0;O_capture_error<=0;end
        else begin
            submit<=0;
            if(flush!=0) flush<=flush-1'b1;
            if(source_busy && settle<127) settle<=settle+1'b1;
            if(I_camera_frame_start && O_frame_ready) begin
                published<=I_camera_mode;published_tag<=I_frame_tag;source_words<=0;submit<=1;source_busy<=1;source_bad<=0;settle<=0;flush<=8;
            end else if(source_busy) begin
                if(I_camera_frame_start || I_camera_abort || I_mipi_rx_error || (!ELASTIC && I_camera_valid && !O_camera_ready)) begin
                    source_bad<=1;
                    if(I_mipi_rx_error || (!ELASTIC && I_camera_valid && !O_camera_ready && !I_camera_abort)) O_capture_error<=1;
                end
                if(I_camera_valid && O_camera_ready) begin
                    source_words<=source_words+1'b1;
                    if(source_words==WORDS-1) published_diagnostics<=I_diagnostics;
                end
                if(settle>=32 && idle && !submit) source_busy<=0;
            end
        end
    end
    (* ASYNC_REG="TRUE" *) reg [1:0] bad_sync;
    always @(posedge I_ddr_clk or negedge drn)
        if(!drn) bad_sync<=0;else bad_sync<={bad_sync[0],source_bad};
    reg active,finishing,burst;
    reg [5:0] guard_count;
    reg [1:0] write_bank;
    reg [7:0] burst_count;
    reg [$clog2(WORDS+1)-1:0] word_count;
    wire pop=burst && I_ddr_user_ready;
    assign O_video_in_wr_busy=burst || O_ddr_user_wr_en;
    w128_d512_fifo U_w128_d512_fifo(.rst(fifo_reset),.clkw(I_camera_clk),
        .we(I_camera_valid && O_camera_ready),.di(I_camera_data),.afull(),.full_flag(fifo_full),.wrusedw(used_write),
        .clkr(I_ddr_clk),.re(pop),.dout(O_ddr_user_wr_data),.rdusedw(used_read),.valid(),.empty_flag(),.aempty());
    function [24:0] base;
        input [1:0] bank;
        begin case(bank)
            0:base=BASE0;1:base=BASE1;2:base=BASE2;default:base=BASE3;
        endcase end
    endfunction
    reg [1:0] free_bank;
    integer k;
    always @(*) begin
        free_bank=0;
        for(k=3;k>=0;k=k-1)
            if(k!=I_read_bank && (!O_frame_valid || k!=O_video_out_rp)) free_bank=k;
    end
    always @(posedge I_ddr_clk or negedge drn) begin
        if(!drn) begin
            active<=0;finishing<=0;burst<=0;guard_count<=0;write_bank<=0;burst_count<=0;word_count<=0;
            O_frame_sequence<=0;O_frame_tag<=0;O_diagnostics<=0;O_video_out_rp<=0;O_frame_mode<=0;O_frame_valid<=0;O_ddr_user_wr_en<=0;O_ddr_user_addr<=0;ack_frame<=0;
        end else begin
            O_ddr_user_wr_en<=pop;ack_frame<=0;
            // O_ddr_user_wr_en/data are the FIFO's registered output, one cycle after pop.
            if(O_ddr_user_wr_en) begin
                O_ddr_user_addr<=O_ddr_user_addr+8;
                word_count<=word_count+1'b1;
                if(word_count==WORDS-1) begin
                    if(!bad_sync[1] && !I_display_pause) begin
                        O_video_out_rp<=write_bank;O_frame_mode<=published;O_frame_valid<=1;
                        O_frame_sequence<=O_frame_sequence+1'b1;
                        O_frame_tag<=published_tag;O_diagnostics<=published_diagnostics;
                    end
                    active<=0;finishing<=1;ack_frame<=1;
                end
            end
            if(finishing) begin
                if(!pending) finishing<=0;
            end else if(!active && pending) begin
                active<=1;write_bank<=free_bank;O_ddr_user_addr<=base(free_bank);
                word_count<=0;guard_count<=0;
            end
            if(active) begin
                if(guard_count<63) guard_count<=guard_count+1'b1;
                if(bad_sync[1] && guard_count>=32 && !burst && !O_ddr_user_wr_en) begin
                    active<=0;finishing<=1;ack_frame<=1;
                end
                else if(!burst && !O_ddr_user_wr_en && !I_video_out_rd_busy && used_read>=240 && guard_count>=32 && !bad_sync[1]) begin
                    burst<=1;burst_count<=0;
                end
            end
            if(pop) begin
                if(burst_count==239) begin burst<=0;burst_count<=0;end
                else burst_count<=burst_count+1'b1;
            end
        end
    end
endmodule
