// Public display + motion tap and mode/config coordinator. The red detector
// remains in the original top. No mode transition resets the shared DDR path.
module final1_runtime #(parameter WIDTH=1280,HEIGHT=720,LINE_PERIOD=1024)(
 input camera_clk,ddr_clk,ahb_clk,pixel_clk,rst_n,
 input [39:0] raw_data,input raw_valid,raw_user,raw_last,
 input blc_enable,input [7:0] blc_offset, // Already coherent in camera_clk; latched by u_front at RAW SOF.
 input ext_write,input [8:0] ext_write_word,ext_read_word,input [31:0] ext_wdata,output [31:0] ext_rdata,
 input red_capture_ready,red_replay_idle,red_detector_ready,
 output red_camera_enable,red_replay_enable,output [50:0] camera_tag,
 output [18:0] generation,output [1:0] active_mode,
 input final_frame_ready,
 output post_start,output [127:0] post_data,output post_valid,output [50:0] post_tag,
 output linear_busy,linear_wr,output [24:0] linear_addr,output [127:0] linear_data,input linear_ready,
 output linear_rd,output [24:0] linear_rd_addr,input linear_rd_ready,linear_rd_valid,input [127:0] rd_data,
 input [7:0] external_faults,output [7:0] faults,
 input pixel_vs,input [31:0] red_display_frame,
 output show_red,show_motion,output [127:0] motion_boxes,output [3:0] motion_box_valid,
 output [1:0] pixel_mode,output pixel_running,output reg [31:0] pixel_ui,
 input [14:0] motion_mask_rd_addr,output motion_mask_rd_data,motion_mask_wr_buf,motion_mask_enable,
 output signed [7:0] motion_y_offset,
 output [95:0] shared_rgb_data,
 output shared_rgb_valid,
 output shared_rgb_user,
 output shared_rgb_last
);
 wire camera_rst_n,ddr_rst_n,ahb_rst_n,pixel_rst_n;
 final1_reset_release u_camera_reset(.clk(camera_clk),.async_reset_n(rst_n),.reset_n(camera_rst_n));
 final1_reset_release u_ddr_reset(.clk(ddr_clk),.async_reset_n(rst_n),.reset_n(ddr_rst_n));
 final1_reset_release u_ahb_reset(.clk(ahb_clk),.async_reset_n(rst_n),.reset_n(ahb_rst_n));
 final1_reset_release u_pixel_reset(.clk(pixel_clk),.async_reset_n(rst_n),.reset_n(pixel_rst_n));
 wire camera_diag_valid,post_diag_valid;wire [63:0] camera_diag;wire [127:0] post_diag;
 wire motion_bg_reset,motion_bg_requested,motion_mask_requested;
 wire signed [7:0] motion_y_requested;
 wire [7:0] motion_dwell_limit,motion_dwell_requested;
 wire [31:0] ui_data,ui_received;reg [31:0] ui_sent,ui_pending;wire ui_ready,ui_valid;
 wire ui_send=ui_ready && ui_data!=ui_sent;
 always @(posedge ahb_clk or negedge ahb_rst_n)
  if(!ahb_rst_n) ui_sent<=0;else if(ui_send) ui_sent<=ui_data;
 final1_mailbox #(.WIDTH(32)) u_ui(.src_clk(ahb_clk),.dst_clk(pixel_clk),.rst_n(rst_n),
  .send(ui_send),.data(ui_data),.ready(ui_ready),.valid(ui_valid),.received(ui_received));
 wire cfg_send,cfg_ready,cfg_rx;wire [95:0] cfg_data,cfg_received;
 wire cfg_done_src,cfg_done_ready,cfg_done;wire [31:0] cfg_applied;
 wire result_send,result_ready,result_valid;wire [223:0] result_data,result_received;
 wire [103:0] gain_data,gain_received;
 wire gain_send,gain_ready,gain_valid,gain_mail_ready,gain_finish_ready,gain_finish_valid;
 wire [31:0] gain_finished_gen;reg gain_inflight;reg [31:0] gain_inflight_gen;
 reg gain_wait,gain_finish_pending;reg [31:0] gain_finish_gen;
 assign gain_ready=gain_mail_ready && !gain_inflight;
 always @(posedge ahb_clk or negedge ahb_rst_n)
  if(!ahb_rst_n) begin gain_inflight<=0;gain_inflight_gen<=0;end
  else begin
   if(cfg_done || (gain_finish_valid && gain_finished_gen==gain_inflight_gen)) gain_inflight<=0;
   if(gain_send && gain_ready) begin gain_inflight<=1;gain_inflight_gen<=gain_data[103:72];end
  end
 final1_mailbox #(.WIDTH(32)) u_gain_complete(.src_clk(ddr_clk),.dst_clk(ahb_clk),.rst_n(rst_n),
  .send(gain_finish_pending && gain_finish_ready),.data(gain_finish_gen),.ready(gain_finish_ready),
  .valid(gain_finish_valid),.received(gain_finished_gen));
 wire motion_valid,awb_valid;wire [223:0] motion_received;wire [255:0] awb_received;
 (* ASYNC_REG="TRUE" *) reg [7:0] fault_meta,fault_sync;
 always @(posedge ahb_clk or negedge ahb_rst_n)
  if(!ahb_rst_n) begin fault_meta<=0;fault_sync<=0;end
  else begin fault_meta<=faults | external_faults;fault_sync<=fault_meta;end
 // Extension reads already wait three AHB clocks. Decode the held address
 // during that window; data is still sampled on the original completion edge.
 final1_regs #(.READ_DECODE_REGISTERED(1)) u_regs(.clk(ahb_clk),.rst_n(ahb_rst_n),.write(ext_write),.write_word(ext_write_word),
  .read_word(ext_read_word),.wdata(ext_wdata),.rdata(ext_rdata),.ui_data(ui_data),
  .motion_bg_reset(motion_bg_requested),.motion_mask_enable(motion_mask_requested),
  .motion_y_offset(motion_y_requested),.motion_dwell_limit(motion_dwell_requested),
  .cfg_send(cfg_send),.cfg_data(cfg_data),.cfg_ready(cfg_ready),.cfg_done(cfg_done),.cfg_applied(cfg_applied),.faults(fault_sync),
  .camera_diag_valid(camera_diag_valid),.camera_diag(camera_diag),.post_diag_valid(post_diag_valid),.post_diag(post_diag),
  .motion_valid(motion_valid),.motion_data(motion_received),.awb_valid(awb_valid),.awb_data(awb_received),
  .result_send(result_send),.result_data(result_data),.result_ready(result_ready),
  .gain_send(gain_send),.gain_data(gain_data),.gain_ready(gain_ready));
 // u_regs owns these three payloads until ready; shadow writes cannot alter them.
 final1_mailbox #(.WIDTH(96),.EXTERNAL_HOLD(1)) u_cfg(.src_clk(ahb_clk),.dst_clk(ddr_clk),.rst_n(rst_n),
  .send(cfg_send),.data(cfg_data),.ready(cfg_ready),.valid(cfg_rx),.received(cfg_received));
 final1_mailbox #(.WIDTH(32)) u_applied(.src_clk(ddr_clk),.dst_clk(ahb_clk),.rst_n(rst_n),
  .send(cfg_done_src),.data({13'd0,generation}),.ready(cfg_done_ready),.valid(cfg_done),.received(cfg_applied));
 final1_mailbox #(.WIDTH(224),.EXTERNAL_HOLD(1)) u_results(.src_clk(ahb_clk),.dst_clk(pixel_clk),.rst_n(rst_n),
  .send(result_send),.data(result_data),.ready(result_ready),.valid(result_valid),.received(result_received));
 final1_mailbox #(.WIDTH(104),.EXTERNAL_HOLD(1)) u_gains(.src_clk(ahb_clk),.dst_clk(ddr_clk),.rst_n(rst_n),
  .send(gain_send),.data(gain_data),.ready(gain_mail_ready),.valid(gain_valid),.received(gain_received));

 localparam RUN=0,STOP_SEND=1,STOP_WAIT=2,DRAIN=3,START_SEND=4,START_WAIT=5,REPORT=6;
 reg [2:0] state;
 reg [95:0] requested;
 reg [31:0] config_active,motion_config;
 reg [18:0] gen;
 wire running=state==RUN;
 assign active_mode=config_active[1:0];assign generation=gen;
 assign red_replay_enable=running && active_mode==0;
 wire replay_idle,capture_ready,capture_error;
 wire cam_send,cam_ready,cam_received_valid;wire [83:0] cam_received;
 reg camera_ack,camera_enable;
 reg [83:0] camera_command;
 reg camera_pending;reg [3:0] camera_settle;
 reg [31:0] camera_config,camera_motion,source_id,first_source;
 reg [18:0] camera_generation;
 (* ASYNC_REG="TRUE" *) reg [1:0] cam_ack_sync,capture_ready_sync,red_ready_sync;
 reg expected_ack;
 wire camera_apply=raw_user && camera_pending && camera_settle>=8;
 wire camera_run_now=camera_apply?camera_command[83]:camera_enable;
 wire [31:0] config_now=camera_apply?camera_command[31:0]:camera_config;
 wire [18:0] gen_now=camera_apply?camera_command[82:64]:camera_generation;
 assign red_camera_enable=camera_run_now && config_now[1:0]==0;
 assign camera_tag={gen_now,raw_user?source_id+32'd1:source_id};
 assign cam_send=(state==STOP_SEND || state==START_SEND) && cam_ready;
 final1_mailbox #(.WIDTH(84)) u_camera_config(.src_clk(ddr_clk),.dst_clk(camera_clk),.rst_n(rst_n),
  .send(cam_send),.data({state==START_SEND,gen,motion_config,config_active}),.ready(cam_ready),
  .valid(cam_received_valid),.received(cam_received));
 always @(posedge camera_clk or negedge camera_rst_n) begin
  if(!camera_rst_n) begin
   camera_command<=0;camera_pending<=0;camera_settle<=0;camera_ack<=0;camera_enable<=1;
   camera_config<=131072;camera_motion<=(20|(3<<8)|(5<<11)|(10<<17));camera_generation<=0;source_id<=0;first_source<=1;
  end else begin
   if(camera_pending && camera_settle<15) camera_settle<=camera_settle+1'b1;
   if(cam_received_valid) begin camera_command<=cam_received;camera_pending<=1;camera_settle<=0;end
   if(raw_user) source_id<=source_id+1'b1;
   if(camera_apply) begin
    camera_pending<=0;camera_enable<=camera_command[83];camera_config<=camera_command[31:0];
    camera_motion<=camera_command[63:32];camera_generation<=camera_command[82:64];camera_ack<=~camera_ack;
    if(camera_command[83]) first_source<=source_id+1'b1;
   end
  end
 end
 always @(posedge ddr_clk or negedge ddr_rst_n) begin
  if(!ddr_rst_n) begin
   state<=RUN;requested<=0;config_active<=131072;motion_config<=(20|(3<<8)|(5<<11)|(10<<17));gen<=0;
   cam_ack_sync<=0;capture_ready_sync<=0;red_ready_sync<=0;expected_ack<=0;
  end else begin
   cam_ack_sync<={cam_ack_sync[0],camera_ack};
   capture_ready_sync<={capture_ready_sync[0],capture_ready};red_ready_sync<={red_ready_sync[0],red_capture_ready};
   case(state)
    RUN:if(cfg_rx) begin requested<=cfg_received;state<=STOP_SEND;end
    STOP_SEND:if(cam_ready) begin expected_ack<=~cam_ack_sync[1];state<=STOP_WAIT;end
    STOP_WAIT:if(cam_ack_sync[1]==expected_ack) state<=DRAIN;
    DRAIN:if(capture_ready_sync[1] && red_ready_sync[1] && replay_idle && red_replay_idle &&
             red_detector_ready && final_frame_ready) begin
     config_active<=requested[31:0];motion_config<=requested[63:32];gen<=requested[82:64];state<=START_SEND;
    end
    START_SEND:if(cam_ready) begin expected_ack<=~cam_ack_sync[1];state<=START_WAIT;end
    START_WAIT:if(cam_ack_sync[1]==expected_ack) state<=REPORT;
    REPORT:if(cfg_done_ready) state<=RUN;
    default:state<=STOP_SEND;
   endcase
  end
 end
 assign cfg_done_src=state==REPORT && cfg_done_ready;

 wire [95:0] front_rgb;wire front_valid,front_user,front_last;
 // Raw frames always run through display frontend. Capture gates only at RAW
 // frame boundaries, so stopping never truncates a frame already in flight.
 final1_raw_front #(.IMG_WIDTH(WIDTH),.IMG_HEIGHT(HEIGHT)) u_front(.I_clk(camera_clk),.I_rst_n(camera_rst_n),.I_data(raw_data),
  .I_valid(raw_valid),.I_user(raw_user),.I_last(raw_last),
  // config_now includes a command applied on this RAW SOF, never an unapplied shadow.
  .I_sf_enable(config_now[1:0]==2'd0),
  .I_blc_enable(blc_enable),.I_blc_offset(blc_offset),
  .O_data(front_rgb),.O_valid(front_valid),.O_user(front_user),.O_last(front_last));
 assign shared_rgb_data  = front_rgb;
 assign shared_rgb_valid = front_valid;
 assign shared_rgb_user  = front_user;
 assign shared_rgb_last  = front_last;
 wire [127:0] packed_linear;wire pack_valid;
 final1_pack #(.LINE_BEATS(WIDTH*3/16)) u_pack(.I_clk(camera_clk),.I_rst_n(camera_rst_n),.I_96b_frame_start(front_user),
  .I_96b_valid(front_valid),.I_96b_data(front_rgb),.O_128b_data(packed_linear),
  .O_128b_valid(pack_valid),.O_128b_frame_start(),.O_128b_last());
 wire cap_valid;wire [1:0] cap_bank,cap_lock;wire [31:0] cap_sequence;wire [50:0] cap_tag;
 video_in #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.SYNC_RELEASE(1),.BASE0(3500000),.BASE1(10500000),.BASE2(17500000),.BASE3(24500000)) u_capture(
  .I_rst_n(rst_n),.I_camera_clk(camera_clk),.I_camera_frame_start(raw_user && camera_run_now),
  .I_camera_valid(pack_valid),.I_camera_data(packed_linear),.I_camera_mode(config_now[1:0]),
  .I_frame_tag(camera_tag),.I_diagnostics(92'd0),.O_frame_tag(cap_tag),.O_diagnostics(),.O_frame_sequence(cap_sequence),
  .I_camera_abort(raw_user && !camera_run_now),.I_mipi_rx_error(1'b0),.I_ddr_clk(ddr_clk),.I_display_pause(1'b0),
  .I_video_out_rd_busy(1'b0),.I_read_bank(cap_lock),.O_camera_ready(),.O_frame_ready(capture_ready),
  .O_capture_error(capture_error),.O_video_in_wr_busy(linear_busy),.O_video_out_rp(cap_bank),.O_frame_mode(),.O_frame_valid(cap_valid),
  .O_ddr_user_wr_en(linear_wr),.O_ddr_user_addr(linear_addr),.O_ddr_user_wr_data(linear_data),.I_ddr_user_ready(linear_ready));
 wire [47:0] replay_rgb;wire replay_valid,replay_user,replay_last,replay_error,post_last,post_user;
 wire post_done,cl_overflow;
 reg cl_overflow_sticky;
 always @(posedge ddr_clk or negedge ddr_rst_n)
  if(!ddr_rst_n) cl_overflow_sticky<=0;else if(cl_overflow) cl_overflow_sticky<=1;
 final1_line_replay #(.PIXELS(2),.WIDTH(WIDTH),.HEIGHT(HEIGHT),.LINE_PERIOD(LINE_PERIOD)) u_replay(.clk(ddr_clk),.rst_n(ddr_rst_n),.enable(running),.frame_valid(cap_valid),
  .frame_sequence(cap_sequence),.bank(cap_bank),.tag(cap_tag),.generation(gen),.sink_frame_ready(final_frame_ready),
  .post_done(post_done),.locked_bank(cap_lock),.frame_start(post_start),.active_tag(post_tag),.idle(replay_idle),
  .rd_en(linear_rd),.address(linear_rd_addr),.bus_ready(linear_rd_ready),.rd_valid(linear_rd_valid),.rd_data(rd_data),
  .rgb(replay_rgb),.valid(replay_valid),.user(replay_user),.last(replay_last),.error(replay_error));
 reg [17:0] post_words;
 assign post_done=post_valid && post_words==(WIDTH*HEIGHT*3/16-1);
 always @(posedge ddr_clk or negedge ddr_rst_n)
  if(!ddr_rst_n) post_words<=0;
  else if(post_start) post_words<=0;
  else if(post_valid) post_words<=post_words==(WIDTH*HEIGHT*3/16-1)?0:post_words+1'b1;
 wire awb_request,awb_ack;wire [191:0] awb_stats;
 reg gain_request;reg [71:0] gain_payload;
 wire auto_enable=config_active[8];
 wire post_rst_n=ddr_rst_n && state!=START_SEND && state!=START_WAIT && state!=REPORT;
 always @(posedge ddr_clk or negedge ddr_rst_n)
  if(!ddr_rst_n) begin gain_request<=0;gain_payload<=0;gain_wait<=0;gain_finish_pending<=0;gain_finish_gen<=0;end
  else begin
   if(gain_finish_pending && gain_finish_ready) gain_finish_pending<=0;
   if(gain_wait && gain_request==awb_ack) begin gain_wait<=0;gain_finish_pending<=1;end
   if(!post_rst_n) begin gain_request<=0;gain_payload<=0;gain_wait<=0;end
   if(gain_valid) begin
    gain_finish_gen<=gain_received[103:72];
    if(gain_received[103:72]=={13'd0,gen} && running && auto_enable && gain_request==awb_ack && !gain_wait) begin
     gain_payload<=gain_received[71:0];gain_request<=~gain_request;gain_wait<=1;
    end else gain_finish_pending<=1;
   end
  end
 final1_post #(.PIXELS(2),.IMG_WIDTH(WIDTH),.IMG_HEIGHT(HEIGHT),.RGB_INPUT_ENABLE(1),.PIX_FIXED_LINE_PERIOD(LINE_PERIOD),.GREEN_GAIN_ENABLE(1),.MCU_AWB_ENABLE(1),.SERIAL_CL_ENABLE(0)) u_post(
  .axi4s_video_aclk(ddr_clk),.I_rst_n(post_rst_n),.I_style_enable(active_mode==2),
  .I_tdata(40'd0),.I_tvalid(1'b0),.I_tuser(1'b0),.I_tlast(1'b0),.I_tdest(10'd0),
  .I_rgb_data(replay_rgb),.I_rgb_valid(replay_valid),.I_rgb_user(replay_user),.I_rgb_last(replay_last),
  .I_mode({config_active[18],config_active[5:4]}),.I_color_select(config_active[7:6]),.I_green_gain(config_active[17:9]),
  .O_tready(1'b1),.I_tready(),.O_tdata(post_data),.O_tvalid(post_valid),.O_tuser(post_user),.O_tlast(post_last),.O_frame_config(),.O_cl_overflow(cl_overflow),
  .I_awb_mcu_ready(auto_enable),.O_awb_stats_request(awb_request),.O_awb_stats_payload(awb_stats),
  .I_awb_gain_request(gain_request),.I_awb_gain_payload(gain_payload),.O_awb_gain_ack(awb_ack));
 reg awb_seen;wire stats_ready;reg awb_drop;
 wire stats_event=awb_request!=awb_seen; // AE metering is independent of display AWB.
 always @(posedge ddr_clk or negedge ddr_rst_n)
  if(!ddr_rst_n) begin awb_seen<=0;awb_drop<=0;end
  else begin awb_seen<=awb_request;if(stats_event && !stats_ready) awb_drop<=1;end
 final1_mailbox #(.WIDTH(256)) u_awb_stats(.src_clk(ddr_clk),.dst_clk(ahb_clk),.rst_n(rst_n),
  .send(stats_event && stats_ready),.data({13'd0,gen,post_tag[31:0],awb_stats}),
  .ready(stats_ready),.valid(awb_valid),.received(awb_received));

 wire motion_reset=camera_rst_n && camera_enable && camera_config[1:0]==1 && !camera_pending;
 final1_motion_controls u_motion_controls(
  .ahb_clk(ahb_clk),.camera_clk(camera_clk),.pixel_clk(pixel_clk),.rst_n(rst_n),
  .ahb_rst_n(ahb_rst_n),.camera_rst_n(camera_rst_n),.pixel_rst_n(pixel_rst_n),
  .requested_dwell(motion_dwell_requested),.requested_mask(motion_mask_requested),.requested_y(motion_y_requested),
  .requested_bg_reset(motion_bg_requested),.camera_sof(front_valid && front_user),.motion_running(motion_reset),.pixel_vs(pixel_vs),
  .dwell(motion_dwell_limit),.mask_enable(motion_mask_enable),.y_offset(motion_y_offset),.bg_reset(motion_bg_reset));
 wire motion_toggle,motion_result_valid,motion_cluster_error;wire [31:0] motion_frame;
 wire [3:0] box_valid;wire [119:0] boxes;wire [14:0] block_count;
 wire motion_mask_wr_en,motion_mask_wr_data;wire [13:0] motion_mask_wr_addr;
  // Concatenated bank addressing reserves 16384 locations per 14400-bit mask.
 motion_mask_ram u_motion_mask_ram(.I_wr_clk(camera_clk),.I_wr_en(motion_mask_wr_en),
  .I_wr_addr({motion_mask_wr_buf,motion_mask_wr_addr}),.I_wr_data(motion_mask_wr_data),
  .I_rd_clk(pixel_clk),.I_rd_addr(motion_mask_rd_addr),.O_rd_data(motion_mask_rd_data));
 motion_detect_8x8 #(.IMG_WIDTH(WIDTH),.IMG_HEIGHT(HEIGHT),.EXTERNAL_FRAME_ID(1)) u_motion(.I_clk(camera_clk),.I_rst_n(motion_reset),
  .I_bg_reset(motion_bg_reset),.I_motion_dwell_limit(motion_dwell_limit),
  .I_tdata(front_rgb),.I_tvalid(front_valid),.I_tready(1'b1),.I_tuser(front_user),.I_tlast(front_last),
  .I_frame_id(source_id),.I_diff_threshold(camera_motion[7:0]),.I_neighbor_threshold(camera_motion[10:8]),
  .I_min_motion_blocks(camera_motion[16:11]),.I_hold_frames(camera_motion[21:17]),
  .O_result_toggle(motion_toggle),.O_result_valid(motion_result_valid),.O_result_frame_id(motion_frame),
  .O_left(),.O_right(),.O_top(),.O_bottom(),.O_block_count(block_count),.O_box_valid(box_valid),.O_boxes(boxes),
  .O_mask_wr_buf(motion_mask_wr_buf),.O_mask_wr_en(motion_mask_wr_en),
  .O_mask_wr_addr(motion_mask_wr_addr),.O_mask_wr_data(motion_mask_wr_data),.O_cluster_error(motion_cluster_error));
 reg motion_seen,motion_drop;wire motion_ready;
 wire motion_event=motion_reset && motion_toggle!=motion_seen;
 always @(posedge camera_clk or negedge camera_rst_n)
  if(!camera_rst_n) begin motion_seen<=0;motion_drop<=0;end
  else begin motion_seen<=motion_toggle;if(motion_event && !motion_ready) motion_drop<=1;end
 final1_mailbox #(.WIDTH(224)) u_motion_stats(.src_clk(camera_clk),.dst_clk(ahb_clk),.rst_n(rst_n),
  .send(motion_event && motion_ready),.data({13'd0,camera_generation,motion_frame,12'd0,block_count,motion_result_valid,box_valid,
   2'd0,boxes[119:90],2'd0,boxes[89:60],2'd0,boxes[59:30],2'd0,boxes[29:0]}),
  .ready(motion_ready),.valid(motion_valid),.received(motion_received));
 // Bit 0 reports the public replay/post stream; bits 4..7 belong to external faults.
 assign faults={4'd0,capture_error,(motion_drop || motion_cluster_error),awb_drop,(replay_error || cl_overflow_sticky)};

 wire camera_diag_ready,post_diag_ready;
 reg [31:0] post_completed;
 always @(posedge ddr_clk or negedge ddr_rst_n)
  if(!ddr_rst_n) post_completed<=0;else if(post_done) post_completed<=post_completed+1'b1;
 final1_mailbox #(.WIDTH(64)) u_camera_diag(.src_clk(camera_clk),.dst_clk(ahb_clk),.rst_n(rst_n),
  .send(raw_user && camera_diag_ready),.data({13'd0,gen_now,source_id+32'd1}),.ready(camera_diag_ready),
  .valid(camera_diag_valid),.received(camera_diag));
 final1_mailbox #(.WIDTH(128)) u_post_diag(.src_clk(ddr_clk),.dst_clk(ahb_clk),.rst_n(rst_n),
  .send(post_done && post_diag_ready),.data({13'd0,gen,post_tag[31:0],post_completed+32'd1,cap_sequence}),.ready(post_diag_ready),
  .valid(post_diag_valid),.received(post_diag));

 // Pixel profile crosses as one held packet. Old boxes are hidden on VS;
 // motion results also expire after 500 ms even if the MCU stops responding.
 wire profile_ready,profile_valid;wire [66:0] profile_received;
 reg [66:0] profile_last;
 wire [66:0] profile_now={camera_enable,camera_config[1:0],13'd0,camera_generation,first_source};
 wire profile_send=profile_ready && profile_last!=profile_now;
 always @(posedge camera_clk or negedge camera_rst_n)
  if(!camera_rst_n) profile_last<=0;else if(profile_send) profile_last<=profile_now;
 final1_mailbox #(.WIDTH(67)) u_profile(.src_clk(camera_clk),.dst_clk(pixel_clk),.rst_n(rst_n),
  .send(profile_send),.data(profile_now),.ready(profile_ready),.valid(profile_valid),.received(profile_received));
 reg [66:0] profile_pending,profile_active;
 reg vs_d,result_pending;
 reg [223:0] result_hold,result_active;
 reg [25:0] result_age;
 always @(posedge pixel_clk or negedge pixel_rst_n) begin
  if(!pixel_rst_n) begin
   profile_pending<=0;profile_active<=0;ui_pending<=0;pixel_ui<=0;vs_d<=0;result_pending<=0;result_hold<=0;result_active<=0;result_age<=37500000;
  end else begin
   vs_d<=pixel_vs;
   if(ui_valid) ui_pending<=ui_received;
   if(profile_valid) profile_pending<=profile_received;
   if(result_valid) begin result_hold<=result_received;result_pending<=1;end
   if(result_age<37500000) result_age<=result_age+1'b1;
   if(pixel_vs && !vs_d) begin
    profile_active<=profile_pending;pixel_ui<=ui_pending;
    if(profile_active!=profile_pending) begin result_active<=0;result_pending<=0;result_age<=37500000;end
    else if(result_pending) begin
     result_pending<=0;
     if(result_hold[223:192]==profile_pending[63:32] && profile_pending[66:64]==3'b101) begin
      result_active<=result_hold;result_age<=0;
     end
    end
   end
  end
 end
 assign pixel_mode=profile_active[65:64];assign pixel_running=profile_active[66];
 wire red_current=(red_display_frame-profile_active[31:0])<32'h80000000;
 assign show_red=pixel_running && pixel_mode==0 && red_current;
 assign show_motion=pixel_running && pixel_mode==1 && result_age<37500000 && result_active[223:192]==profile_active[63:32];
 assign motion_boxes=result_active[127:0];assign motion_box_valid=show_motion?result_active[131:128]:4'd0;
endmodule

// Registers at 0x1ac remain requested values. Each destination applies the latest
// coherent mailbox snapshot at its frame boundary; intermediate writes may merge.
// Reset requests have one in-flight and one sticky queued slot (further requests
// coalesce). ACK means a running motion frame has consumed the reset event.
module final1_motion_controls(
 input ahb_clk,camera_clk,pixel_clk,rst_n,
 input ahb_rst_n,camera_rst_n,pixel_rst_n,
 input [7:0] requested_dwell,input requested_mask,input signed [7:0] requested_y,
 input requested_bg_reset,camera_sof,motion_running,pixel_vs,
 output reg [7:0] dwell,output reg mask_enable,output reg signed [7:0] y_offset,
 output reg bg_reset
);
 wire dwell_ready,dwell_valid,display_ready,display_valid;
 wire [7:0] dwell_received;
 wire [8:0] display_received;
 wire [8:0] display_requested={requested_mask,requested_y};
 reg [7:0] dwell_sent;
 reg [8:0] display_sent;
 wire dwell_send=dwell_ready && requested_dwell!=dwell_sent;
 wire display_send=display_ready && display_requested!=display_sent;
 final1_mailbox #(.WIDTH(8)) u_dwell(.src_clk(ahb_clk),.dst_clk(camera_clk),.rst_n(rst_n),
  .send(dwell_send),.data(requested_dwell),.ready(dwell_ready),.valid(dwell_valid),.received(dwell_received));
 final1_mailbox #(.WIDTH(9)) u_display(.src_clk(ahb_clk),.dst_clk(pixel_clk),.rst_n(rst_n),
  .send(display_send),.data(display_requested),.ready(display_ready),.valid(display_valid),.received(display_received));
 reg bg_seen,bg_queued,bg_request,bg_ack;
 (* ASYNC_REG="TRUE" *) reg [1:0] bg_req_sync,bg_ack_sync;
 always @(posedge ahb_clk or negedge ahb_rst_n)
  if(!ahb_rst_n) begin
   dwell_sent<=20;display_sent<=9'h100;
   bg_seen<=0;bg_queued<=0;bg_request<=0;bg_ack_sync<=0;
  end else begin
   if(dwell_send) dwell_sent<=requested_dwell;
   if(display_send) display_sent<=display_requested;
   bg_seen<=requested_bg_reset;
   bg_ack_sync<={bg_ack_sync[0],bg_ack};
   if(bg_queued && bg_request==bg_ack_sync[1]) begin bg_request<=~bg_request;bg_queued<=0;end
   // Set wins over send: a concurrent fresh event is retained for the next ACK.
   if(requested_bg_reset && !bg_seen) bg_queued<=1;
  end
 reg dwell_seen,display_seen,vs_d,bg_armed;
 reg [2:0] bg_guard;
 always @(posedge camera_clk or negedge camera_rst_n)
  if(!camera_rst_n) begin
   dwell<=20;dwell_seen<=0;bg_req_sync<=0;bg_ack<=0;bg_reset<=0;bg_armed<=0;bg_guard<=0;
  end else begin
   if(dwell_valid) dwell_seen<=1;
   if(camera_sof && (dwell_seen || dwell_valid)) dwell<=dwell_received;
   bg_req_sync<={bg_req_sync[0],bg_request};bg_reset<=0;
   // A mode stop resets the detector's pending event. Re-issue after restart,
   // without acknowledging, until a frame can actually consume it.
   if(!motion_running) begin bg_armed<=0;bg_guard<=0;end
   else if(bg_req_sync[1]!=bg_ack) begin
    if(!bg_armed) begin bg_reset<=1;bg_armed<=1;bg_guard<=0;end
    else if(bg_guard<4) bg_guard<=bg_guard+1'b1;
    else if(camera_sof) begin bg_ack<=bg_req_sync[1];bg_armed<=0;bg_guard<=0;end
   end
  end
 always @(posedge pixel_clk or negedge pixel_rst_n)
  if(!pixel_rst_n) begin mask_enable<=1;y_offset<=0;display_seen<=0;vs_d<=0;end
  else begin
   vs_d<=pixel_vs;
   if(display_valid) display_seen<=1;
   if(pixel_vs && !vs_d && (display_seen || display_valid)) begin
    mask_enable<=display_received[8];y_offset<=display_received[7:0];
   end
  end
endmodule
