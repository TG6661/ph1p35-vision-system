// One MCU command outstanding. AHB acknowledges completion only after the
// 24-bit bundled-data transfer is accepted at a real segmentation SOF.
module mcu_threshold_ctrl(
    input wire ahb_clk,ctrl_clk,seg_clk,reset_n,
    input wire submit,
    input wire [24:0] command,
    output wire ready,
    output reg done,
    output reg [24:0] completed,
    input wire [23:0] menu_value,
    input wire seg_sof,
    output reg owner,
    output wire [23:0] selected,
    output wire [23:0] seg_config,
    output wire [24:0] selected_readback,
    output wire [24:0] active_readback
);
    localparam [23:0] DEFAULTS={8'd100,8'd65,8'd65};
    wire cmd_idle,arn,crn,cmd_pending;
    reg cmd_accept,waiting;
    reg [24:0] response;
    target_result_cdc #(.SYNC_RELEASE(1)) u_command(.src_clk(ahb_clk),.dst_clk(ctrl_clk),.reset_n(reset_n),
        .src_submit(submit),.src_idle(cmd_idle),.src_reset_n(arn),.dst_reset_n(crn),
        .dst_pending(cmd_pending),.dst_accept(cmd_accept));
    assign ready=cmd_idle && !waiting && !submit;
    always @(posedge ahb_clk or negedge arn)
        if(!arn) begin waiting<=0;done<=0;completed<={1'b0,DEFAULTS};end
        else begin
            done<=0;
            if(submit && cmd_idle) waiting<=1;
            else if(waiting && cmd_idle) begin
                waiting<=0;done<=1;completed<=response;
            end
        end
    reg [23:0] mcu_value,published,last_sent;
    reg frame_submit,is_command;
    reg [1:0] state;
    wire frame_idle,frn,srn,frame_pending;
    reg [23:0] active,staged;
    reg staged_valid,active_valid;
    assign selected=owner ? mcu_value : menu_value;
    target_result_cdc #(.SYNC_RELEASE(1)) u_frame(.src_clk(ctrl_clk),.dst_clk(seg_clk),.reset_n(reset_n),
        .src_submit(frame_submit),.src_idle(frame_idle),.src_reset_n(frn),.dst_reset_n(srn),
        .dst_pending(frame_pending),.dst_accept(staged_valid && seg_sof));
    // At SOF the first pixel and active register use this SAME held payload.
    assign seg_config=staged_valid ? staged : active;
    always @(posedge seg_clk or negedge srn)
        if(!srn) begin active<=DEFAULTS;staged<=DEFAULTS;staged_valid<=0;active_valid<=0;end
        else begin
            if(seg_sof) active_valid<=1;
            if(frame_pending && !staged_valid) begin
                staged<=published;staged_valid<=1;
            end
            if(staged_valid && seg_sof) begin active<=staged;staged_valid<=0;end
        end
    always @(posedge ctrl_clk or negedge crn)
        if(!crn) begin
            owner<=0;mcu_value<=DEFAULTS;published<=DEFAULTS;last_sent<=DEFAULTS;
            frame_submit<=0;cmd_accept<=0;state<=0;is_command<=0;response<={1'b0,DEFAULTS};
        end else begin
            frame_submit<=0;cmd_accept<=0;
            case(state)
                0: if(frame_idle) begin
                    if(cmd_pending) begin
                        owner<=command[24];mcu_value<=command[23:0];
                        published<=command[24] ? command[23:0] : menu_value;
                        response<={command[24],command[24] ? command[23:0] : menu_value};
                        last_sent<=command[24] ? command[23:0] : menu_value;
                        frame_submit<=1;is_command<=1;state<=1;
                    end else if(selected!=last_sent) begin
                        published<=selected;last_sent<=selected;
                        frame_submit<=1;is_command<=0;state<=1;
                    end
                end
                1: if(!frame_idle) state<=2;
                2: if(frame_idle) begin
                    if(is_command) begin cmd_accept<=1;state<=3;end
                    else state<=0;
                end
                3: if(!cmd_pending) state<=0;
            endcase
        end
    // Coherent eventual snapshots; completed is the exact command response.
    view_mode_cdc #(.BITS(25),.RESET_VALUE({1'b0,DEFAULTS}),.SYNC_RELEASE(1)) u_selected_status(
        .src_clk(ctrl_clk),.dst_clk(ahb_clk),.reset_n(reset_n),
        .value({owner,selected}),.received(selected_readback));
    // Invalid after control-only reset until the segmenter accepts another SOF.
    view_mode_cdc #(.BITS(25),.RESET_VALUE({1'b0,DEFAULTS}),.SYNC_RELEASE(1)) u_active_status(
        .src_clk(seg_clk),.dst_clk(ahb_clk),.reset_n(reset_n),
        .value({active_valid,active}),.received(active_readback));
endmodule
