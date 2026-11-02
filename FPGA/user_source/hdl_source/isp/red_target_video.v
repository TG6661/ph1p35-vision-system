// Post-Gamma RGB detection and post-mixer HDMI insertion. Video never stalls.
// The legacy awb_* port names are retained; isp_top now supplies Gamma output.
// MCU_POSTPROCESS=0 retains the old pipeline only for standalone reference tests.
// The production top explicitly selects 1: no RTL classifier/tracker instances.
module red_target_video #(parameter WIDTH=1280,HEIGHT=720,MIN_AREA=2500,MCU_POSTPROCESS=0,MASK_DDR=0,EXTERNAL_FRAME_ID=0)(
    output wire input_frame_ready,threshold_sof,
    // DDR transport keeps shared reset across local HDMI/detector cancellation.
    input wire mask_reset_n,mask_bus_ready,mask_rd_valid,mask_write_retired,
    input wire [127:0] mask_rd_data,
    output wire mask_request,mask_wr,mask_rd,mask_protocol_error,
    output wire [24:0] mask_addr,output wire [127:0] mask_wr_data,
    input wire detector_clk,pixel_clk,reset_n,
    input wire show_targets,input wire [31:0] source_frame_id,
    input wire [7:0] red_rmin,red_rgap,red_bgap,
    output wire [3:0] debug_raw_data,debug_erode_data,debug_clean_data,
    output wire debug_raw_valid,debug_raw_user,debug_erode_valid,debug_erode_user,debug_clean_valid,debug_clean_user,
    input wire debug_raw_ready,debug_erode_ready,debug_clean_ready,
    input wire [95:0] awb_data,
    input wire awb_valid,awb_user,awb_last,
    input wire [23:0] video_rgb,
    input wire video_de,video_hs,video_vs,
    output wire [23:0] out_rgb,
    output wire out_de,out_hs,out_vs,
    output wire [15:0] display_count,
    output wire [7:0] display_error,
    output wire [31:0] display_frame_id,
    output wire display_valid,display_commit,
    output wire candidate_valid,candidate_done,
    output wire [69:0] candidate_record,
    output wire [15:0] candidate_count,candidate_total,
    output wire [3:0] candidate_error,
    output wire [31:0] candidate_frame,
    input wire candidate_ready,candidate_done_ready,
    input wire result_valid,result_done,result_alive,result_reset_n,
    input wire [51:0] result_record,
    input wire [15:0] result_count,
    input wire [3:0] result_error,
    input wire [31:0] result_frame,
    output wire result_ready,result_done_ready
);
    (* ASYNC_REG="TRUE" *) reg [1:0] src_reset,dst_reset;
    always @(posedge detector_clk or negedge reset_n)
        if(!reset_n) src_reset<=0; else src_reset<={src_reset[0],1'b1};
    always @(posedge pixel_clk or negedge reset_n)
        if(!reset_n) dst_reset<=0; else dst_reset<={dst_reset[0],1'b1};
    wire [3:0] raw,buffered,clean;
    wire rv,ru,rl,bv,bu,bl,br,cv,cu,cl,cr,open_ready,ccl_ready;
    assign br=open_ready && debug_raw_ready;
    assign debug_raw_data=buffered;
    assign debug_raw_valid=bv && open_ready;
    assign debug_raw_user=bu;
    assign cr=ccl_ready && debug_clean_ready;
    assign debug_clean_data=clean;
    assign debug_clean_valid=cv && ccl_ready;
    assign debug_clean_user=cu;
    wire [31:0] captured_id,skipped;
    wire capture_busy,capture_error;
    assign input_frame_ready=src_reset[1] && !capture_busy;
    wire done_valid,done_ready,shape_done_valid,shape_done_ready;
    wire detector_complete;
    // Segment output is always ready, so this is the accepted input SOF.
    assign threshold_sof=src_reset[1] && awb_valid && awb_user;
    color_segment_96 u_red(.clk(detector_clk),.rst_n(src_reset[1]),
        .cfg_rmin(red_rmin),.cfg_rgap(red_rgap),.cfg_bgap(red_bgap),
        .s_tdata(awb_data),.s_tvalid(awb_valid),.s_tready(),.s_tuser(awb_user),.s_tlast(awb_last),
        .m_tdata(raw),.m_tvalid(rv),.m_tready(1'b1),.m_tuser(ru),.m_tlast(rl));
    generate if(MASK_DDR) begin: ddr_capture
        target_mask_ddr #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) u_capture(
            .clk(detector_clk),.rst_n(mask_reset_n),.cancel(!src_reset[1]),
            .s_data(raw),.s_valid(rv),.s_user(ru),.s_last(rl),
            .m_data(buffered),.m_valid(bv),.m_user(bu),.m_last(bl),.m_ready(br),
            .process_done(detector_complete),.frame_id(captured_id),.busy(capture_busy),
            .capture_error(capture_error),.skipped_frames(skipped),.protocol_error(mask_protocol_error),
            .request(mask_request),.wr_en(mask_wr),.rd_en(mask_rd),.address(mask_addr),.wr_data(mask_wr_data),
            .bus_ready(mask_bus_ready),.rd_valid(mask_rd_valid),.write_retired(mask_write_retired),.rd_data(mask_rd_data));
    end else begin: bram_capture
        assign mask_request=1'b0,mask_wr=1'b0,mask_rd=1'b0,mask_protocol_error=1'b0;
        assign mask_addr=25'd0,mask_wr_data=128'd0;
    target_mask_frame_buffer #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) u_capture(
        .clk(detector_clk),.rst_n(src_reset[1]),.s_data(raw),.s_valid(rv),.s_user(ru),.s_last(rl),
        .m_data(buffered),.m_valid(bv),.m_user(bu),.m_last(bl),.m_ready(br),
        .process_done(detector_complete),.frame_id(captured_id),.busy(capture_busy),
        .capture_error(capture_error),.skipped_frames(skipped));
    end endgenerate
    // DLFPGA legacy wrapper name: ERODE=3x3, clean/DILATE=effective 5x5 dilation.
    binary_open_bram_4 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) u_open(
        .clk(detector_clk),.rst_n(src_reset[1]),.s_tdata(buffered),.s_tvalid(bv && debug_raw_ready),.s_tuser(bu),.s_tlast(bl),.s_tready(open_ready),
        .m_tdata(clean),.m_tvalid(cv),.m_tuser(cu),.m_tlast(cl),.m_tready(cr),
        .debug_erode_data(debug_erode_data),.debug_erode_valid(debug_erode_valid),
        .debug_erode_user(debug_erode_user),.debug_erode_ready(debug_erode_ready));
    wire tv,tr,dv,dr,lv,lr,ldv,ldr;
    wire [69:0] td,limited;
    wire [15:0] all_count,limited_count;
    wire [3:0] ce,le;
    // Minimum foreground-pixel count after morphology, not bounding-box area.
    connected_components_rle_4 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.MIN_AREA(MIN_AREA),.MAX_TARGETS(255)) u_ccl(
        .clk(detector_clk),.rst_n(src_reset[1]),.s_tdata(clean),.s_tvalid(cv && debug_clean_ready),.s_tuser(cu),.s_tlast(cl),.s_tready(ccl_ready),
        .target_valid(tv),.target_ready(tr),.target_id(td[69:62]),.target_area(td[61:42]),
        .target_xmin(td[41:31]),.target_xmax(td[30:20]),.target_ymin(td[19:10]),.target_ymax(td[9:0]),
        .done_valid(dv),.done_ready(dr),.target_count(all_count),.frame_error(ce));
    target_first_eight u_limit(.clk(detector_clk),.rst_n(src_reset[1]),.s_valid(tv),.s_ready(tr),.s_data(td),
        .s_done_valid(dv),.s_done_ready(dr),.s_error(ce),.m_valid(lv),.m_ready(lr),.m_data(limited),
        .m_done_valid(ldv),.m_done_ready(ldr),.m_count(limited_count),.m_error(le));
    wire stv,str,ge;
    wire [7:0] id;
    wire [19:0] area;
    wire [10:0] xmin,xmax;
    wire [9:0] ymin,ymax;
    wire [1:0] cls;
    wire [15:0] target_count;
    wire [3:0] error;
    wire tracked_valid,tracked_ready;
    wire [51:0] tracked_record;
    wire [15:0] tracked_count;
    wire [3:0] tracked_error;
    wire [31:0] result_frame_id;
    assign candidate_valid=MCU_POSTPROCESS ? lv : 1'b0;
    assign candidate_done=MCU_POSTPROCESS ? ldv : 1'b0;
    assign candidate_record=limited;
    assign candidate_count=limited_count;assign candidate_total=all_count;
    reg [31:0] captured_source;
    always @(posedge detector_clk or negedge src_reset[1])
      if(!src_reset[1]) captured_source<=0;else if(threshold_sof && input_frame_ready) captured_source<=source_frame_id;
    assign candidate_error=le;assign candidate_frame=EXTERNAL_FRAME_ID ? captured_source : captured_id;
    assign result_ready=MCU_POSTPROCESS ? tracked_ready : 1'b0;
    assign result_done_ready=MCU_POSTPROCESS ? done_ready : 1'b0;
    generate if(MCU_POSTPROCESS) begin: mcu_postprocess
        assign lr=candidate_ready;assign ldr=candidate_done_ready;
        assign detector_complete=ldv && ldr;
        assign tracked_valid=result_valid;assign tracked_record=result_record;
        assign tracked_count=result_count;assign tracked_error=result_error;
        assign done_valid=result_done;assign result_frame_id=result_frame;
    end else begin: legacy_postprocess
    assign detector_complete=done_valid && done_ready;
    assign result_frame_id=captured_id;
    target_shape_classifier_v2 u_shape(.clk(detector_clk),.rst_n(src_reset[1]),
        .s_target_valid(lv),.s_target_ready(lr),.s_target_id(limited[69:62]),.s_target_area(limited[61:42]),
        .s_target_xmin(limited[41:31]),.s_target_xmax(limited[30:20]),.s_target_ymin(limited[19:10]),.s_target_ymax(limited[9:0]),
        .s_done_valid(ldv),.s_done_ready(ldr),.s_target_count(limited_count),.s_frame_error(le),
        .target_valid(stv),.target_ready(str),.target_id(id),.target_area(area),
        .target_xmin(xmin),.target_xmax(xmax),.target_ymin(ymin),.target_ymax(ymax),.class_id(cls),.geometry_error(ge),
        .done_valid(shape_done_valid),.done_ready(shape_done_ready),.target_count(target_count),.frame_error(error));
    target_tracker u_tracker(.clk(detector_clk),.rst_n(src_reset[1]),
        .s_valid(stv),.s_ready(str),.s_class(cls),.s_xmin(xmin),.s_xmax(xmax),.s_ymin(ymin),.s_ymax(ymax),
        .s_geometry_error(ge),.s_done_valid(shape_done_valid),.s_done_ready(shape_done_ready),
        .s_count(target_count),.s_error(error),.m_valid(tracked_valid),.m_ready(tracked_ready),.m_record(tracked_record),
        .m_done_valid(done_valid),.m_done_ready(done_ready),.m_count(tracked_count),.m_error(tracked_error));
    end endgenerate
    reg vs_d;
    reg [10:0] x;
    reg [9:0] y;
    wire frame_start=video_vs && !vs_d && !video_de;
    (* ASYNC_REG="TRUE" *) reg [1:0] alive_sync;
    reg frame_alive;
    always @(posedge pixel_clk or negedge reset_n) begin
        if(!reset_n) begin alive_sync<=0;frame_alive<=0;end
        else begin
            alive_sync<={alive_sync[0],result_alive};
            if(frame_start) frame_alive<=alive_sync[1];
        end
    end
    always @(posedge pixel_clk or negedge reset_n) begin
        if(!reset_n) begin vs_d<=0; x<=0; y<=0; end
        else if(!dst_reset[1]) begin vs_d<=0; x<=0; y<=0; end
        else begin
            vs_d<=video_vs;
            if(frame_start) begin x<=0; y<=0; end
            else if(video_de) begin
                if(x==WIDTH-1) begin x<=0; y<=y==HEIGHT-1?0:y+1'b1; end
                else x<=x+1'b1;
            end
        end
    end
    wire [511:0] records;
    wire [3:0] visible_count;
    wire [1:0] color;
    wire overflow;
    target_result_buffer #(.SYNC_RELEASE(MCU_POSTPROCESS),.COMPACT(1)) u_results(.src_clk(detector_clk),.dst_clk(pixel_clk),
        .reset_n(reset_n && (!MCU_POSTPROCESS || result_reset_n)),
         .target_valid(tracked_valid),.target_ready(tracked_ready),.target_id(tracked_record[51:44]),.class_id(tracked_record[43:42]),
        .xmin(tracked_record[41:31]),.xmax(tracked_record[30:20]),.ymin(tracked_record[19:10]),.ymax(tracked_record[9:0]),
         .geometry_error(1'b0),.done_valid(done_valid),.done_ready(done_ready),.target_count(tracked_count),.frame_error(tracked_error),
        .frame_id(result_frame_id),.color_id(2'd0),.display_frame_start(frame_start),.display_records(records),
        .display_count(visible_count),.display_total(display_count),.display_error(display_error),.display_frame_id(display_frame_id),
        .display_color(color),.display_overflow(overflow),.display_valid(display_valid),.display_commit(display_commit));
    target_track_osd u_osd(.clk(pixel_clk),.reset_n(dst_reset[1]),.commit(display_commit),
        .rgb(video_rgb),.de(video_de),.hs(video_hs),.vs(video_vs),.x(x),.y(y),
        .records(records),.count(visible_count),.total(display_count),.error(display_error),
        .overflow(overflow),.result_valid(display_valid && show_targets && (!MCU_POSTPROCESS || frame_alive)),
        .out_rgb(out_rgb),.out_de(out_de),.out_hs(out_hs),.out_vs(out_vs));
endmodule
