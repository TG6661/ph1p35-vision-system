// MCU diagnostics and frame-boundary threshold control.
module mcu_bringup(
    input wire I_sys_clk, I_rst_n,
    input wire I_uart0_rx,
    output wire O_uart0_tx,
    input wire [3:0] I_button,
    input wire [7:0] I_hw_status,
    input wire I_ctrl_clk,I_seg_clk,I_video_rst_n,I_seg_sof,
    input wire [23:0] I_menu_value,
    output wire O_threshold_owner,
    output wire [23:0] O_selected,O_seg_config,
    output wire [42:0] O_menu_settings,
    input wire I_target_valid,I_target_done,
    input wire [69:0] I_target_record,
    input wire [15:0] I_target_count,I_target_total,
    input wire [3:0] I_target_error,
    input wire [31:0] I_target_frame,
    output wire O_target_ready,O_target_done_ready,
    output wire O_result_valid,O_result_done,O_result_alive,O_result_reset_n,
    output wire [51:0] O_result_record,
    output wire [15:0] O_result_count,
    output wire [3:0] O_result_error,
    output wire [31:0] O_result_frame,
    input wire I_result_ready,I_result_done_ready,
    input wire I_camera_ready,
    output wire O_cam_scl,inout wire IO_cam_sda,
    output wire O_cam_cfg_done,O_cam_ae_done,O_cam_id_ok,O_cam_error,
    output wire [15:0] O_cam_id,
    output wire O_hud_clk,O_hud_reset_n,O_hud_submit,
    output wire [95:0] O_hud_command,
    input wire I_hud_ready,I_hud_done,
    output wire O_ext_write,output wire [8:0] O_ext_write_word,O_ext_read_word,
    output wire [31:0] O_ext_wdata,input wire [31:0] I_ext_rdata,
    output wire O_servo_pan,O_servo_tilt
);
    wire core_clk, timer_clk, apb_clk, ahb_clk, pll_locked;
    wire core_reset_n, apb_reset_n, ahb_reset_n;
    wire reset_source_n=I_rst_n && pll_locked;
    MCU_PLL u_mcu_pll(.refclk(I_sys_clk),.reset(!I_rst_n),
        .clk0_out(core_clk),.clk1_out(timer_clk),.lock(pll_locked));
    PH1P_LOGIC_BUFG u_apb_clock(.i(I_sys_clk),.o(apb_clk));
    mcu_reset_sync u_core_reset(.clk(core_clk),.async_reset_n(reset_source_n),.reset_n(core_reset_n));
    mcu_reset_sync u_apb_reset(.clk(apb_clk),.async_reset_n(reset_source_n),.reset_n(apb_reset_n));
    mcu_reset_sync u_ahb_reset(.clk(ahb_clk),.async_reset_n(reset_source_n && I_video_rst_n),.reset_n(ahb_reset_n));
    wire [1:0] htrans,hresp;
    wire hwrite,hready;
    wire [30:0] haddr;
    wire [2:0] hsize;
    wire [31:0] hwdata,hrdata;
    RISCV_F6F1D1P0_0 u_core(
        .core_clk(core_clk),.timer_clk(timer_clk),
        .core_reset(!core_reset_n),.por_reset(!core_reset_n),.core_sysrst(),
        .nmi(1'b0),.clic_irq(23'd0),
        .uart0_rx(I_uart0_rx),.uart0_tx(O_uart0_tx),
        .ahb_clk(ahb_clk),.htrans(htrans),.hwrite(hwrite),.haddr(haddr),
        .hsize(hsize),.hburst(),.hprot(),.hmastlock(),
        .hwdata(hwdata),.hrdata(hrdata),.hresp(hresp),.hready(hready),
        .apb_clk(apb_clk),.apb_rst(!apb_reset_n),
        .paddr(),.psel(),.penable(),.pwrite(),.pwdata(),.pstrobe(),.pprot(),
        .prdata(32'd0),.pready(1'b1),.pslverr(1'b0)
    );
    wire submit,ctrl_ready,ctrl_done;
    wire [24:0] command,completed,selected_status;
    wire [24:0] active_status;
    wire menu_submit,menu_ready,menu_done;
    wire [42:0] menu_command;
    wire target_write;
    wire [4:0] target_write_word,target_read_word;
    wire [31:0] target_wdata,target_rdata;
    wire service_write;
    wire [4:0] service_write_word,service_read_word;
    wire [31:0] service_rdata;
    assign O_ext_wdata=target_wdata;
    assign O_hud_clk=ahb_clk;assign O_hud_reset_n=ahb_reset_n;
    mcu_camera_hud #(.I2C_CLK_DIV(23809524/100000-1)) u_services(
        .ahb_clk(ahb_clk),.ctrl_clk(I_ctrl_clk),.reset_n(ahb_reset_n),.camera_ready(I_camera_ready),
        .write(service_write),.write_word(service_write_word),.wdata(target_wdata),
        .read_word(service_read_word),.rdata(service_rdata),
        .cam_scl(O_cam_scl),.cam_sda(IO_cam_sda),.cfg_done(O_cam_cfg_done),.ae_done(O_cam_ae_done),
        .id_ok(O_cam_id_ok),.iic_error(O_cam_error),.sensor_id(O_cam_id),
        .hud_command(O_hud_command),.hud_submit(O_hud_submit),.hud_ready(I_hud_ready),.hud_done(I_hud_done));
    mcu_target_bridge u_targets(.ahb_clk(ahb_clk),.detector_clk(I_seg_clk),.reset_n(ahb_reset_n),
        .write(target_write),.write_word(target_write_word),.wdata(target_wdata),
        .read_word(target_read_word),.rdata(target_rdata),
        .s_valid(I_target_valid),.s_ready(O_target_ready),.s_record(I_target_record),
        .s_done_valid(I_target_done),.s_done_ready(O_target_done_ready),
        .s_count(I_target_count),.s_total(I_target_total),.s_error(I_target_error),.s_frame(I_target_frame),
        .m_valid(O_result_valid),.m_ready(I_result_ready),.m_record(O_result_record),
        .m_done_valid(O_result_done),.m_done_ready(I_result_done_ready),.m_count(O_result_count),
        .m_error(O_result_error),.m_frame(O_result_frame),.alive(O_result_alive),.result_reset_n(O_result_reset_n));
    mcu_menu_bridge u_menu(.ahb_clk(ahb_clk),.ctrl_clk(I_ctrl_clk),.reset_n(ahb_reset_n),
        .submit(menu_submit),.command(menu_command),.ready(menu_ready),.done(menu_done),
        .settings(O_menu_settings));
    mcu_threshold_ctrl u_thresholds(.ahb_clk(ahb_clk),.ctrl_clk(I_ctrl_clk),
        .seg_clk(I_seg_clk),.reset_n(ahb_reset_n),.submit(submit),.command(command),
        .ready(ctrl_ready),.done(ctrl_done),.completed(completed),.menu_value(I_menu_value),
        .seg_sof(I_seg_sof),.owner(O_threshold_owner),.selected(O_selected),
        .seg_config(O_seg_config),.selected_readback(selected_status),.active_readback(active_status));
    ahb_ctrl_regs u_regs(.I_ahb_clk(ahb_clk),.I_ahb_rst_n(ahb_reset_n),
        .I_htrans(htrans),.I_hwrite(hwrite),.I_haddr(haddr),.I_hsize(hsize),
        .I_hwdata(hwdata),.O_hrdata(hrdata),.O_hresp(hresp),.O_hready(hready),
        .I_button(I_button),.I_hw_status(I_hw_status),
        .I_ctrl_ready(ctrl_ready),.I_ctrl_done(ctrl_done),.I_completed(completed),
        .I_selected(selected_status),.I_active(active_status),.O_submit(submit),.O_command(command),
        .I_menu_ready(menu_ready),.I_menu_done(menu_done),.O_menu_submit(menu_submit),.O_menu_command(menu_command),
        .O_target_write(target_write),.O_target_write_word(target_write_word),.O_target_wdata(target_wdata),
        .O_target_read_word(target_read_word),.I_target_rdata(target_rdata),
        .O_service_write(service_write),.O_service_write_word(service_write_word),
        .O_service_read_word(service_read_word),.I_service_rdata(service_rdata),
        .O_ext_write(O_ext_write),.O_ext_write_word(O_ext_write_word),
        .O_ext_read_word(O_ext_read_word),.I_ext_rdata(I_ext_rdata),
        .O_servo_pan(O_servo_pan),.O_servo_tilt(O_servo_tilt));
endmodule

// v5 peripheral bank 0x100..0x17c. Keep in this registered compilation unit.
// Firmware owns camera sequencing and decimal conversion. Only one physical
// I2C transaction can be outstanding; timeout recovery must never replay it.
module mcu_camera_hud #(parameter I2C_CLK_DIV=237)(
    input wire ahb_clk,ctrl_clk,reset_n,camera_ready,
    input wire write,input wire [4:0] write_word,input wire [31:0] wdata,
    input wire [4:0] read_word,output reg [31:0] rdata,
    output wire cam_scl,inout wire cam_sda,
    output wire cfg_done,ae_done,id_ok,iic_error,output wire [15:0] sensor_id,
    output reg [95:0] hud_command,output reg hud_submit,
    input wire hud_ready,hud_done
);
    localparam [95:0] HUD_DEFAULT={1'b0,2'd0,1'b1,4'd5,12'h065,12'h065,12'h100,12'h032,12'h000,12'h190,16'h1991};
    reg [15:0] address_shadow;
    reg [7:0] data_shadow;
    reg [31:0] state_shadow,state_completed;
    reg [2:0] camera_legal;
    reg [57:0] command;
    reg submit,busy,rejected,valid,last_nack,sticky_nack;
    reg [31:0] accepted,completed;
    reg [7:0] read_data;
    wire idle,arn,crn,pending;
    reg accept;
    reg [8:0] response;
    (* ASYNC_REG="TRUE" *) reg [1:0] ready_sync;
    wire available=idle && !busy && !submit && ready_sync[1];
    target_result_cdc #(.SYNC_RELEASE(1)) u_camera_cdc(
        .src_clk(ahb_clk),.dst_clk(ctrl_clk),.reset_n(reset_n),
        .src_submit(submit),.src_idle(idle),.src_reset_n(arn),.dst_reset_n(crn),
        .dst_pending(pending),.dst_accept(accept));

    reg [95:0] hud_shadow;
    reg [2:0] hud_legal;
    reg hud_busy,hud_rejected,hud_valid;
    reg [31:0] hud_accepted,hud_completed;
    function digits_ok;
        input [31:0] value;integer i;
        begin digits_ok=1;for(i=0;i<8;i=i+1)
            if(value[i*4+:4]>9) digits_ok=0;end
    endfunction
    always @(posedge ahb_clk or negedge arn) begin
        if(!arn) begin
            address_shadow<=0;data_shadow<=0;state_shadow<=0;state_completed<=0;camera_legal<=7;
            command<=0;submit<=0;busy<=0;rejected<=0;valid<=0;last_nack<=0;sticky_nack<=0;
            accepted<=0;completed<=0;read_data<=0;ready_sync<=0;
            hud_shadow<=HUD_DEFAULT;hud_command<=HUD_DEFAULT;hud_legal<=7;hud_submit<=0;
            hud_busy<=0;hud_rejected<=0;hud_valid<=0;hud_accepted<=0;hud_completed<=0;
        end else begin
            ready_sync<={ready_sync[0],camera_ready};submit<=0;hud_submit<=0;
            // Idle-follow payloads reduce commit fanout, including consecutive writes.
            if(!busy) command[55:0]<={state_shadow,data_shadow,address_shadow};
            if(busy && idle && !submit) begin
                busy<=0;completed<=accepted;valid<=1;
                last_nack<=response[8];sticky_nack<=sticky_nack|response[8];read_data<=response[7:0];
                if(command[57]) state_completed<=command[55:24];
            end
            if(!hud_busy) hud_command<=hud_shadow;
            if(hud_busy && hud_done) begin hud_busy<=0;hud_completed<=hud_accepted;hud_valid<=1;end
            if(write) case(write_word)
                0:begin address_shadow<=wdata[15:0];camera_legal[0]<=wdata[31:16]==0;end
                1:begin data_shadow<=wdata[7:0];camera_legal[1]<=wdata[31:8]==0;end
                2:begin
                    if(wdata[2]) rejected<=0;
                    if(wdata[0]) begin
                        if(available && wdata[31:4]==0 && !(wdata[3] && wdata[1]) &&
                           (wdata[3]?camera_legal[2]:(camera_legal[0] && camera_legal[1]))) begin
                            command[57:56]<={wdata[3],wdata[1]};submit<=1;busy<=1;accepted<=accepted+1'b1;
                        end else rejected<=1;
                    end
                end
                7:begin state_shadow<=wdata;camera_legal[2]<=wdata[15:4]==0;end
                // HUD v2 top nibble is AWB/mask flags, not a BCD digit.
                16:begin hud_shadow[31:0]<=wdata;hud_legal[0]<=digits_ok(wdata & 32'h0fffffff) && wdata[31:30]==0;end
                17:begin hud_shadow[63:32]<=wdata;hud_legal[1]<=digits_ok(wdata & 32'hffffff7f);end // bit39 AUTO EXP
                18:begin
                    hud_shadow[95:64]<=wdata;
                    hud_legal[2]<=wdata[27:24]<=10 && digits_ok({8'd0,wdata[23:0]});
                end
                19:begin
                    if(wdata[2]) hud_rejected<=0;
                    if(wdata[0]) begin
                        if(!hud_busy && hud_ready && (&hud_legal) && (wdata&32'hfffffffa)==0) begin
                            hud_submit<=1;hud_busy<=1;hud_accepted<=hud_accepted+1'b1;
                        end else hud_rejected<=1;
                    end
                end
                default:begin end
            endcase
        end
    end
    // An extra peripheral register stage retains the existing three-wait read path.
    always @(posedge ahb_clk or negedge arn) begin
        if(!arn) rdata<=0;
        else case(read_word)
            0:rdata<={16'd0,address_shadow};1:rdata<={24'd0,data_shadow};
            3:rdata<={26'd0,sticky_nack,last_nack,available,valid,rejected,busy};
            4:rdata<=accepted;5:rdata<=completed;6:rdata<={24'd0,read_data};
            7:rdata<=state_shadow;8:rdata<=state_completed;
            16:rdata<=hud_shadow[31:0];17:rdata<=hud_shadow[63:32];18:rdata<=hud_shadow[95:64];
            20:rdata<={28'd0,hud_ready,hud_valid,hud_rejected,hud_busy};
            21:rdata<=hud_accepted;22:rdata<=hud_completed;
            default:rdata<=0;
        endcase
    end

    reg [1:0] state;
    reg req,mode,transaction_nack,hardware_nack;
    reg [31:0] wr_data,camera_state;
    wire engine_busy,engine_error,engine_reset_n;
    wire [7:0] rd_data;
    mcu_reset_sync u_engine_reset(.clk(ctrl_clk),.async_reset_n(crn && camera_ready),.reset_n(engine_reset_n));
    assign cfg_done=camera_state[0];assign ae_done=camera_state[1];
    assign id_ok=camera_state[2];assign sensor_id=camera_state[31:16];
    assign iic_error=hardware_nack|camera_state[3];
    always @(posedge ctrl_clk or negedge crn) begin
        if(!crn) begin
            state<=0;req<=0;mode<=0;wr_data<=0;accept<=0;response<=0;
            camera_state<=0;transaction_nack<=0;hardware_nack<=0;
        end else begin
            accept<=0;
            if(engine_error) hardware_nack<=1;
            if((state==1 || state==2) && engine_error) transaction_nack<=1;
            case(state)
                0:if(pending && engine_reset_n && !engine_busy) begin
                    transaction_nack<=0;
                    if(command[57]) begin
                        camera_state<=command[55:24];response<=0;accept<=1;state<=3;
                    end else begin
                        wr_data<={command[23:16],command[7:0],command[15:8],8'h6c};
                        mode<=command[56];req<=1;state<=1;
                    end
                end
                1:if(engine_busy) begin req<=0;state<=2;end
                2:if(!engine_busy) begin
                    response<={transaction_nack|engine_error,rd_data};accept<=1;state<=3;
                end
                3:if(!pending) state<=0;
                default:state<=0;
            endcase
        end
    end
    uii2c #(.WMEN_LEN(4),.RMEN_LEN(1),.CLK_DIV(I2C_CLK_DIV)) u_i2c(
        .I_clk(ctrl_clk),.I_rstn(engine_reset_n),.O_iic_scl(cam_scl),.IO_iic_sda(cam_sda),
        .I_wr_data(wr_data),.I_wr_cnt(mode?8'd3:8'd4),.O_rd_data(rd_data),
        .I_rd_cnt(mode?8'd1:8'd0),.I_iic_req(req),.I_iic_mode(mode),
        .O_iic_busy(engine_busy),.O_iic_bus_error(engine_error),.IO_iic_sda_dg());
endmodule

// Detection mailbox and MCU result return. No classifier/tracker hardware here.
// Kept in the already registered compilation unit to survive TD GUI source lists.
module mcu_target_bridge #(parameter STALE_CYCLES=33333333)(
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
    // Sample mailbox startup once. tx_inflight already owns the entire
    // submit/request/ack interval and is cleared only after synchronized idle.
    // Keep the reset/idle decode off every payload write/commit enable.
    reg tx_armed;
    always @(posedge ahb_clk or negedge arn)
        if(!arn) tx_armed<=0;
        else if(tx_idle) tx_armed<=1;
    wire tx_busy=tx_inflight || !tx_armed || tx_submit;
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

// Keep MCU control helpers in this registered compilation unit.
// Atomic MCU menu settings -> control domain. Completion means the control
// registers accepted the snapshot, NOT sensor I2C completion or a displayed frame.
module mcu_menu_bridge(
    input wire ahb_clk,ctrl_clk,reset_n,
    input wire submit,
    input wire [42:0] command,
    output wire ready,
    output reg done,
    output reg [42:0] settings
);
    // {selected[3:0],gamma[3:0],BL,BO[7:0],SF[1:0],AG[7:0],AE[15:0]}
    localparam [42:0] DEFAULTS={4'd0,4'd6,1'b1,8'd32,2'd3,8'd190,16'd1991};
    wire idle,arn,crn,pending;
    reg waiting;
    target_result_cdc #(.SYNC_RELEASE(1)) u_cdc(
        .src_clk(ahb_clk),.dst_clk(ctrl_clk),.reset_n(reset_n),
        .src_submit(submit),.src_idle(idle),.src_reset_n(arn),.dst_reset_n(crn),
        .dst_pending(pending),.dst_accept(pending));
    assign ready=idle && !waiting && !submit;
    always @(posedge ctrl_clk or negedge crn)
        if(!crn) settings<=DEFAULTS;
        else if(pending) settings<=command;
    always @(posedge ahb_clk or negedge arn)
        if(!arn) begin waiting<=0;done<=0;end
        else begin
            done<=0;
            if(submit && idle) waiting<=1;
            else if(waiting && idle) begin waiting<=0;done<=1;end
        end
endmodule

// Keep MCU control helpers in this registered compilation unit.
// Camera transaction executor only: no keys, debounce or menu state.
// Hold AE/AG for the entire grouped I2C write; coalesce pending target changes.
module camera_param_apply(
    input wire clk,reset_n,cam_done,ae_done,
    input wire [15:0] target_ae,
    input wire [7:0] target_ag,
    output reg req,
    output reg [15:0] ae,ag
);
    reg issued;
    always @(posedge clk or negedge reset_n)
        if(!reset_n) begin req<=0;issued<=0;ae<=1991;ag<=190;end
        else if(req) req<=0;
        else if(cam_done && ae_done &&
                (!issued || ae!=target_ae || ag!={8'd0,target_ag})) begin
            ae<=target_ae;ag<={8'd0,target_ag};req<=1;issued<=1;
        end
endmodule
