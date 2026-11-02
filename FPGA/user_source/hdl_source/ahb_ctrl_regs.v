// MCU interface v5: menu/SEG plus a registered target-processing window.
// PH1P35 exposes the lower 31 address bits of the 0x80000000 Fabric window.
// Only aligned 32-bit transfers are supported. Unsupported accesses complete
// with OKAY, read zero and never modify registers. No address aliases.
// Supported reads: 2 waits for 0x00..0x7c, 3 waits for 0x80..0x17c.
// Writes: zero waits, captured at data completion and executed next AHB edge.
module ahb_ctrl_regs(
    input wire I_ahb_clk, I_ahb_rst_n,
    input wire [1:0] I_htrans,
    input wire I_hwrite,
    input wire [30:0] I_haddr,
    input wire [2:0] I_hsize,
    input wire [31:0] I_hwdata,
    output wire [31:0] O_hrdata,
    output wire [1:0] O_hresp,
    output wire O_hready,
    input wire [3:0] I_button,
    // Independent status bits, not a coherent video-frame snapshot.
    input wire [7:0] I_hw_status,
    input wire I_ctrl_ready,I_ctrl_done,
    input wire [24:0] I_completed,I_selected,
    input wire [24:0] I_active,
    output reg O_submit,
    output reg [24:0] O_command,
    input wire I_menu_ready,I_menu_done,
    output reg O_menu_submit,
    output reg [42:0] O_menu_command,
    // Target window 0x80..0xfc. Writes are staged before entering the peripheral;
    // All reads return a register directly: legacy 2 waits, target 3 waits.
    // Target read bank staging consumes the extra wait; writes remain zero-wait.
    output reg O_target_write,
    output reg [4:0] O_target_write_word,
    output reg [31:0] O_target_wdata,
    output wire [4:0] O_target_read_word,
    output reg O_service_write,
    output reg [4:0] O_service_write_word,
    output wire [4:0] O_service_read_word,
    input wire [31:0] I_service_rdata,
    input wire [31:0] I_target_rdata,
    output reg O_ext_write,output reg [8:0] O_ext_write_word,
    output wire [8:0] O_ext_read_word,input wire [31:0] I_ext_rdata,
    output wire O_servo_pan,O_servo_tilt
);
    localparam [31:0] IDENT = 32'hA5010006;
    localparam [42:0] MENU_DEFAULTS={4'd0,4'd6,1'b1,8'd32,2'd3,8'd190,16'd1991};
    reg [31:0] menu_camera,menu_ui;
    reg menu_busy,menu_rejected,menu_valid;
    reg [31:0] menu_accepted_seq,menu_applied_seq;
    reg [42:0] menu_completed;
    // The MCU hard-IP outputs have a core->AHB half-cycle timing budget.
    // Register small predicates independently; combine only on the Fabric side.
    reg [8:0] camera_checks;
    reg [3:0] ui_checks;
    wire menu_camera_legal = (&camera_checks[8:4]) &&
        (camera_checks[0] || camera_checks[1] || (camera_checks[2] && camera_checks[3]));
    wire menu_ui_legal = &ui_checks;
    wire menu_legal=menu_camera_legal && menu_ui_legal;
    localparam [23:0] DEFAULTS={8'd100,8'd65,8'd65};
    reg [23:0] shadow;
    reg busy,rejected,completed_valid;
    reg [31:0] accepted_seq,applied_seq;
    reg [24:0] completed_value;
    (* ASYNC_REG="TRUE" *) reg [3:0] button_meta, button_sync;
    (* ASYNC_REG="TRUE" *) reg [7:0] status_meta, status_sync;
    reg [4:0] phase_checks;
    wire phase_valid = &phase_checks;
    reg phase_write;
    reg phase_target,phase_service,phase_ext;
    reg [8:0] ext_word;
    assign O_ext_read_word=ext_word;
    reg [4:0] phase_word;
    reg [1:0] target_wait;
    reg [31:0] target_read_hold;
    reg [31:0] read_mux;
    reg write_pending;
    reg [4:0] write_word;
    reg [31:0] scratch0, scratch1, cycles;
    assign O_hready = !(phase_valid && !phase_write && target_wait!=0);
    // No address decode/data mux between this response register and MCU HRDATA.
    assign O_hrdata=target_read_hold;
    assign O_hresp = 2'b00;
    assign O_target_read_word=phase_word;
    assign O_service_read_word=phase_word;

    wire [31:0] servo_rdata;
    final1_servo_pwm u_servo(.clk(I_ahb_clk),.reset_n(I_ahb_rst_n),
        .write(write_pending),.write_word(write_word),.wdata(O_target_wdata),
        .read_word(phase_word),.rdata(servo_rdata),
        .pan_pwm(O_servo_pan),.tilt_pwm(O_servo_tilt));

    always @(posedge I_ahb_clk or negedge I_ahb_rst_n) begin
        if (!I_ahb_rst_n) begin
            button_meta<=4'hf; button_sync<=4'hf;
            status_meta<=0; status_sync<=0;
            phase_checks<=0; phase_write<=0; phase_word<=0;phase_target<=0;phase_service<=0;
            target_wait<=0;target_read_hold<=0;phase_ext<=0;ext_word<=0;O_ext_write<=0;O_ext_write_word<=0;
            O_service_write<=0;O_service_write_word<=0;
            O_target_write<=0;O_target_write_word<=0;O_target_wdata<=0;
            write_pending<=0;write_word<=0;
            scratch0<=0; scratch1<=0; cycles<=0;
            shadow<=DEFAULTS;busy<=0;rejected<=0;completed_valid<=0;
            accepted_seq<=0;applied_seq<=0;completed_value<={1'b0,DEFAULTS};
            O_submit<=0;O_command<={1'b0,DEFAULTS};
            menu_camera<={8'd0,MENU_DEFAULTS[23:0]};menu_ui<={13'd0,MENU_DEFAULTS[42:24]};
            menu_busy<=0;menu_rejected<=0;menu_valid<=0;
            camera_checks<=9'b111111001;ui_checks<=4'b1111;
            menu_accepted_seq<=0;menu_applied_seq<=0;menu_completed<=MENU_DEFAULTS;
            O_menu_submit<=0;O_menu_command<=MENU_DEFAULTS;
        end else begin
            button_meta<=I_button; button_sync<=button_meta;
            status_meta<=I_hw_status; status_sync<=status_meta;
            cycles<=cycles+1'b1;
            O_submit<=0;
            O_menu_submit<=0;
            // MCU HWDATA only drives this capture bank. Decode/check/commit logic
            // consumes it one cycle later, using a full AHB-clock budget.
            // Unconditional capture avoids a wide high-fanout clock enable.
            O_target_wdata<=I_hwdata;
            O_target_write<=phase_valid && phase_target && !phase_service && !phase_ext && phase_write;
            O_ext_write<=phase_valid && phase_ext && phase_write;O_ext_write_word<=ext_word;
            O_service_write<=phase_valid && phase_service && !phase_ext && phase_write;
            O_service_write_word<=phase_word;
            O_target_write_word<=phase_word;
            write_pending<=phase_valid && !phase_target && !phase_service && !phase_ext && phase_write;
            write_word<=phase_word;
            if(!O_hready) begin
                target_wait<=target_wait-1'b1;
                if(target_wait==1) target_read_hold<=read_mux;
            end
            // Stage the shadow while idle, then freeze throughout the transfer.
            // Bit0 commit no longer drives the 43-bit payload register enables.
            // On the commit edge this captures the latest completed shadow writes,
            // including back-to-back AHB transfers; the CDC sees submit next edge.
            if(!menu_busy) O_menu_command<={menu_ui[18:0],menu_camera[23:0]};
            if(menu_busy && I_menu_done) begin
                menu_busy<=0;menu_applied_seq<=menu_accepted_seq;
                menu_completed<=O_menu_command;menu_valid<=1;
            end
            if(busy && I_ctrl_done) begin
                busy<=0;applied_seq<=accepted_seq;
                completed_value<=I_completed;completed_valid<=1;
            end
            // Address/control sampled now belong to the NEXT data phase.
            if(O_hready) begin
                phase_checks[0]<=I_htrans[1] && I_hsize==3'd2 && I_haddr[1:0]==0;
                phase_checks[1]<=I_haddr[12:11]==0;
                phase_checks[2]<=I_haddr[18:13]==0;
                phase_checks[3]<=I_haddr[24:19]==0;
                phase_checks[4]<=I_haddr[30:25]==0;
                phase_write<=I_hwrite;
                phase_ext<=I_haddr[10:7]>=3;ext_word<=I_haddr[10:2];
                phase_word<=I_haddr[6:2];phase_target<=I_haddr[7];phase_service<=I_haddr[8];
                target_wait<=(|I_haddr[10:7]) ? 3 : 2;
                // Invalid/read-only writes and idle phases return zero.
                target_read_hold<=0;
            end
            // Execute the captured write in order, including consecutive transfers.
            if (write_pending) begin
                case (write_word)
                    3'd1: scratch0<=O_target_wdata;
                    3'd2: scratch1<=O_target_wdata;
                    5'd8: shadow<=O_target_wdata[23:0];
                    5'd9: begin
                        if(O_target_wdata[2]) rejected<=0;
                        if(O_target_wdata[0]) begin
                            if(!busy && I_ctrl_ready) begin
                                O_command<={O_target_wdata[1],shadow};O_submit<=1;
                                busy<=1;accepted_seq<=accepted_seq+1'b1;
                            end else rejected<=1;
                        end
                    end
                    5'd17: begin
                        menu_camera<=O_target_wdata;
                        // AE 2..3982 (0x0f8e), AG 16..239 (0x10..0xef).
                        camera_checks[0]<=O_target_wdata[11:8]!=4'hf;
                        camera_checks[1]<=O_target_wdata[7:4]<4'h8;
                        camera_checks[2]<=O_target_wdata[7:4]==4'h8;
                        camera_checks[3]<=O_target_wdata[3:0]!=4'hf;
                        camera_checks[4]<=O_target_wdata[11:1]!=0;
                        camera_checks[5]<=O_target_wdata[15:12]==0;
                        camera_checks[6]<=O_target_wdata[23:20]!=0 && O_target_wdata[23:20]!=4'hf;
                        camera_checks[7]<=O_target_wdata[27:24]==0;
                        camera_checks[8]<=O_target_wdata[31:28]==0;
                    end
                    5'd18: begin
                        menu_ui<={O_target_wdata[31:2],2'd3}; // SF is fixed STRONG; legacy field reads 3.
                        ui_checks[0]<=O_target_wdata[25:19]==0;
                        ui_checks[1]<=O_target_wdata[31:26]==0;
                        ui_checks[2]<=O_target_wdata[18:15]<=4'd10;
                        ui_checks[3]<=O_target_wdata[14:11]<=4'd11;
                    end
                    5'd19: begin
                        if(O_target_wdata[2]) menu_rejected<=0;
                        if(O_target_wdata[0]) begin
                            if(!menu_busy && I_menu_ready && menu_legal) begin
                                O_menu_submit<=1;menu_busy<=1;
                                menu_accepted_seq<=menu_accepted_seq+1'b1;
                            end else menu_rejected<=1;
                        end
                    end
                    default: begin end
                endcase
            end
        end
    end
    always @* begin
        read_mux=32'd0;
        if (I_ahb_rst_n && phase_valid && !phase_write) begin
            if(phase_ext) read_mux=I_ext_rdata;
            else if(phase_service) read_mux=I_service_rdata;
            else if(phase_target) read_mux=I_target_rdata;
            else case (phase_word)
                3'd0: read_mux=IDENT;
                3'd1: read_mux=scratch0;
                3'd2: read_mux=scratch1;
                3'd3: read_mux={28'd0,button_sync};
                3'd4: read_mux={24'd0,status_sync};
                3'd5: read_mux=cycles;
                5'd8: read_mux={8'd0,shadow};
                5'd10: read_mux={28'd0,completed_valid,rejected,I_selected[24],busy};
                5'd11: read_mux={7'd0,O_command};
                5'd12: read_mux=accepted_seq;
                5'd13: read_mux=applied_seq;
                5'd14: read_mux={7'd0,completed_value};
                5'd15: read_mux={7'd0,I_selected};
                5'd16: read_mux={7'd0,I_active};
                5'd17: read_mux=menu_camera;
                5'd18: read_mux=menu_ui;
                5'd20: read_mux={28'd0,I_menu_ready,menu_valid,menu_rejected,menu_busy};
                5'd21: read_mux=menu_accepted_seq;
                5'd22: read_mux=menu_applied_seq;
                5'd23: read_mux={8'd0,menu_completed[23:0]};
                5'd24: read_mux={13'd0,menu_completed[42:24]};
                5'd25,5'd26,5'd27,5'd28,5'd29: read_mux=servo_rdata;
                default: read_mux=32'd0;
            endcase
        end
    end
endmodule

// Same AHB clock as staged local writes: no generated clock or new CDC.
// 0x64/68 shadow widths; 0x6c command/status; 0x70 ABI; 0x74 active pair.
// Command: bit0 commit, bit1 cancel, bit2 clear reject. Commit+cancel invalid.
// One pending pair freezes on commit and applies only at the 20ms boundary.
// Busy commits reject without replacement (even on the apply edge). Cancel wins
// over boundary apply. Shadow edits while busy cannot alter the pending pair.
module final1_servo_pwm #(parameter CLOCKS_PER_US=150)(
    input wire clk,reset_n,write,input wire [4:0] write_word,
    input wire [31:0] wdata,input wire [4:0] read_word,
    output reg [31:0] rdata,output reg pan_pwm,tilt_pwm
);
    localparam DIV_W=$clog2(CLOCKS_PER_US+1);
    reg [DIV_W-1:0] divider;
    reg [14:0] period_us;
    reg [11:0] shadow_pan,shadow_tilt,pending_pan,pending_tilt,active_pan,active_tilt;
    reg busy,rejected;
    wire tick=divider==CLOCKS_PER_US-1;
    wire boundary=tick && period_us==15'd19999;
    wire control=write && write_word==5'd27;
    wire legal=wdata[31:3]==0 && !(wdata[0] && wdata[1]);
    wire cancel=control && legal && wdata[1];
    function [11:0] clamp_width;
        input [31:0] value;
        begin
            if(value==0) clamp_width=12'd1500;
            else if(value<500) clamp_width=12'd500;
            else if(value>2500) clamp_width=12'd2500;
            else clamp_width=value[11:0];
        end
    endfunction
    always @(posedge clk or negedge reset_n) begin
        if(!reset_n) begin
            divider<=0;period_us<=0;pan_pwm<=0;tilt_pwm<=0;
            shadow_pan<=1500;shadow_tilt<=1500;pending_pan<=1500;pending_tilt<=1500;
            active_pan<=1500;active_tilt<=1500;busy<=0;rejected<=0;
        end else begin
            // Output flops change only on microsecond ticks. The first pulse
            // after reset starts at the first full period boundary.
            if(tick) begin
                divider<=0;
                if(boundary) begin
                    period_us<=0;pan_pwm<=1;tilt_pwm<=1;
                    if(busy && !cancel) begin
                        active_pan<=pending_pan;active_tilt<=pending_tilt;busy<=0;
                    end
                end else begin
                    period_us<=period_us+1'b1;
                    if(period_us+1'b1==active_pan) pan_pwm<=0;
                    if(period_us+1'b1==active_tilt) tilt_pwm<=0;
                end
            end else divider<=divider+1'b1;
            if(write && write_word==5'd25) shadow_pan<=clamp_width(wdata);
            if(write && write_word==5'd26) shadow_tilt<=clamp_width(wdata);
            if(control) begin
                if(legal) begin
                    if(wdata[2]) rejected<=0;
                    if(wdata[1]) busy<=0;
                    if(wdata[0]) begin
                        if(busy) rejected<=1;
                        else begin pending_pan<=shadow_pan;pending_tilt<=shadow_tilt;busy<=1;end
                    end
                end else rejected<=1;
            end
        end
    end
    always @* begin
        case(read_word)
            5'd25:rdata={20'd0,shadow_pan};
            5'd26:rdata={20'd0,shadow_tilt};
            5'd27:rdata={30'd0,rejected,busy};
            5'd28:rdata=32'h53560101; // SV, ABI v1, atomic pair + cancel capable.
            5'd29:rdata={8'd0,active_tilt,active_pan};
            default:rdata=0;
        endcase
    end
endmodule
