`timescale 1ns/1ps
module tb_mcu_camera_hud;
    reg test_passed=0,clk=0,ctrl_clk=0,pixel_clk=0,reset_n=0,camera_ready=0;
    always #3.333 clk=~clk;
    always #21 ctrl_clk=~ctrl_clk;
    always #6.5 pixel_clk=~pixel_clk;
    reg [1:0] trans=0;reg write=0;reg [30:0] addr=0;reg [2:0] size=2;
    reg [31:0] wdata=0;wire [31:0] rdata;wire ready;wire [1:0] resp;
    wire svc_write;wire [4:0] svc_ww,svc_rw;wire [31:0] svc_data,svc_rd;
    wire scl,cfg,ae_done,id_ok,error;wire [15:0] id;
    tri1 sda;reg slave_low=0,active=0;assign sda=slave_low?1'b0:1'bz;
    wire [95:0] hud_command;wire hud_submit,hud_ready,hud_done;
    reg de=0,hs=0,vs=0;wire [23:0] rgb_out;wire out_de,out_hs,out_vs;
    ahb_ctrl_regs bus(.I_ahb_clk(clk),.I_ahb_rst_n(reset_n),
        .I_htrans(trans),.I_hwrite(write),.I_haddr(addr),.I_hsize(size),.I_hwdata(wdata),
        .O_hrdata(rdata),.O_hresp(resp),.O_hready(ready),.I_button(4'hf),.I_hw_status(8'd0),
        .I_ctrl_ready(1'b1),.I_ctrl_done(1'b0),.I_completed(25'd0),.I_selected(25'd0),.I_active(25'd0),
        .I_menu_ready(1'b1),.I_menu_done(1'b0),.I_target_rdata(32'd0),.O_submit(),.O_command(),.O_menu_submit(),.O_menu_command(),
        .O_target_write(),.O_target_write_word(),.O_target_read_word(),
        .O_target_wdata(svc_data),.O_service_write(svc_write),.O_service_write_word(svc_ww),
        .O_service_read_word(svc_rw),.I_service_rdata(svc_rd),.I_ext_rdata(32'd0),.O_ext_write(),.O_ext_write_word(),.O_ext_read_word(),.O_servo_pan(),.O_servo_tilt());
    mcu_camera_hud #(.I2C_CLK_DIV(15)) dut(.ahb_clk(clk),.ctrl_clk(ctrl_clk),.reset_n(reset_n),
        .camera_ready(camera_ready),.write(svc_write),.write_word(svc_ww),.wdata(svc_data),
        .read_word(svc_rw),.rdata(svc_rd),.cam_scl(scl),.cam_sda(sda),
        .cfg_done(cfg),.ae_done(ae_done),.id_ok(id_ok),.iic_error(error),.sensor_id(id),
        .hud_command(hud_command),.hud_submit(hud_submit),.hud_ready(hud_ready),.hud_done(hud_done));
    camera_settings_osd osd(.src_clk(clk),.pixel_clk(pixel_clk),.reset_n(reset_n),
        .command(hud_command),.submit(hud_submit),.ready(hud_ready),.done(hud_done),
        .latency_data(89'd0),.cfg_done(cfg),.iic_error(error),.rgb(24'h234567),.de(de),.hs(hs),.vs(vs),
        .out_rgb(rgb_out),.out_de(out_de),.out_hs(out_hs),.out_vs(out_vs));
    task wr(input [30:0] a,input [31:0] d);
        @(negedge clk);trans=2;write=1;addr=a;
        @(negedge clk);trans=0;wdata=d;
        repeat(2) @(negedge clk);
    endtask
    task rd(input [30:0] a,output [31:0] d);
        integer waits;
        @(negedge clk);trans=2;write=0;addr=a;
        @(posedge clk);#0.1;waits=0;
        while(!ready) begin @(posedge clk);#0.1;waits++;end
        d=rdata;
        if(resp!==0) $fatal(1,"AHB response");
        if(a<384 && waits!=(a<128?2:3)) $fatal(1,"read waits %h: %0d",a,waits);
        @(negedge clk);trans=0;
        @(posedge clk);#0.1;
    endtask
    task check_rd(input [30:0] a,input [31:0] d);
        reg [31:0] actual;rd(a,actual);if(actual!==d) $fatal(1,"read %h got %h want %h",a,actual,d);
    endtask
    task reset;
        @(negedge clk);reset_n=0;camera_ready=0;trans=0;slave_low=0;active=0;vs=0;
        repeat(30) @(negedge ctrl_clk);reset_n=1;camera_ready=1;
        repeat(30) @(negedge ctrl_clk);
    endtask
    task wait_camera;
        reg [31:0] status;integer loops;
        loops=0;status=1;
        while(status[0]) begin
            rd('h10c,status);loops++;
            if(loops>10000) $fatal(1,"camera stuck busy");
        end
    endtask
    // Actual SCL/SDA sensor, no hierarchical force of master done/busy signals.
    reg [15:0] model_id=16'hee4b,reg_addr=0;
    reg ack_phase=0,ack_seen=0,tx=0,next_tx=0,nack=0;
    reg [7:0] shift=0,tx_byte=0;
    integer bits=0,byte_index=0,writes=0,nack_write=-1,starts=0;
    reg [23:0] writes_seen[0:1023];
    always @(negedge sda) if(scl===1'b1 && camera_ready) begin
        active=1;bits=0;byte_index=0;shift=0;ack_phase=0;ack_seen=0;tx=0;next_tx=0;starts++;
    end
    always @(posedge sda) if(scl===1'b1) begin active=0;slave_low=0;end
    always @(posedge scl) if(active) begin
        if(ack_phase) ack_seen=1;
        else if(tx) bits++;
        else begin
            shift={shift[6:0],sda};bits++;
            if(bits==8) begin
                next_tx=0;nack=0;
                case(byte_index)
                    0:begin
                        if(shift!=8'h6c && shift!=8'h6d) $fatal(1,"sensor address %h",shift);
                        next_tx=shift[0];tx_byte=reg_addr==16'h3107 ? model_id[15:8]:model_id[7:0];
                    end
                    1:reg_addr[15:8]=shift;
                    2:reg_addr[7:0]=shift;
                    3:begin nack=writes==nack_write;writes_seen[writes]={reg_addr,shift};writes++;end
                endcase
                byte_index++;
            end
        end
    end
    always @(negedge scl) if(active) begin
        if(ack_phase && ack_seen) begin
            slave_low=0;ack_phase=0;ack_seen=0;bits=0;
            if(tx) begin active=0;tx=0;end
            else if(next_tx) begin tx=1;slave_low=!tx_byte[7];end
        end else if(!ack_phase && bits==8) begin ack_phase=1;slave_low=tx?0:!nack;end
        else if(tx && bits<8) slave_low=!tx_byte[7-bits];
    end
    string vectors;integer fd,n,sequence_number,old_writes;
    reg [31:0] c,p,status,expected_state;
    reg [95:0] held;
    initial begin

        reset();check_rd(0,32'ha5010006);
        // Invalid addresses/sizes cannot alias the v5 window or the old scratch.
        wr('h100,'h3456);wr('h300,'hffff);wr('h181,'hffff);wr('h40000100,'hffff);
        size=1;wr('h100,'hffff);size=2;check_rd('h100,'h3456);check_rd('h180,0);check_rd('h300,0);
        wr('h100,'h10000);wr('h108,5);check_rd('h110,0);rd('h10c,status);
        if(!status[1]) $fatal(1,"illegal address shadow not rejected");
        // Consecutive shadow writes + commit use the newest complete values.
        @(negedge clk);trans=2;write=1;addr='h140;
        @(negedge clk);addr='h144;wdata=32'h01901991;
        @(negedge clk);addr='h148;wdata=32'h10003287;
        @(negedge clk);addr='h14c;wdata=32'h9a065065;
        @(negedge clk);trans=0;wdata=5;
        repeat(3) @(negedge clk);
        held={32'h9a065065,32'h10003287,32'h01901991};
        if(hud_command!==held) $fatal(1,"HUD consecutive snapshot");
        // Command stays frozen while busy even if software prepares next shadow.
        wr('h140,32'h12341234);
        wait(!dut.hud_busy);check_rd('h154,1);check_rd('h158,1);
        repeat(5) @(negedge pixel_clk);vs=1;repeat(3) @(negedge pixel_clk);vs=0;
        if(osd.displayed[95:0]!==held) $fatal(1,"atomic HUD displayed");
        wr('h148,32'h8b000000);wr('h14c,5);check_rd('h154,1);
        wr('h148,0);wr('h140,32'h0000000a);wr('h14c,5);check_rd('h154,1);
        // Additional valid tracking OFF, then VS atomically applies it.
        wr('h140,32'h01901991);wr('h148,32'h19065065);wr('h14c,5);
        wait(!dut.hud_busy);check_rd('h154,2);check_rd('h158,2);
        repeat(5) @(negedge pixel_clk);vs=1;repeat(3) @(negedge pixel_clk);vs=0;
        if(osd.displayed[95] || osd.displayed[91:88]!=9) $fatal(1,"TRACK OFF/selection CDC");
        reset();check_rd('h154,0);check_rd('h158,0);
        if(dut.hud_busy || osd.displayed[95]) $fatal(1,"reset TRACK state");
        // Every production C-packed v2 payload must pass real AHB legality/CDC.
        fd=$fopen("current/menu_vectors.txt","r");if(!fd)$fatal(1,"menu vectors missing");
        sequence_number=0;
        while(!$feof(fd))begin
            n=$fscanf(fd,"%h %h %h\n",held[95:64],held[63:32],held[31:0]);
            if(n==3)begin
                wr('h140,held[31:0]);wr('h144,held[63:32]);wr('h148,held[95:64]);wr('h14c,5);
                wait(!dut.hud_busy);sequence_number++;
                check_rd('h154,sequence_number);check_rd('h158,sequence_number);
                repeat(5)@(negedge pixel_clk);vs=1;repeat(3)@(negedge pixel_clk);vs=0;
                if(osd.displayed[95:0]!==held)$fatal(1,"v2 payload corrupt through AHB/CDC");
            end
        end
        $fclose(fd);if(sequence_number!=102)$fatal(1,"v2 vector count");
        wr('h140,held[31:0]|32'h40000000);wr('h14c,5);check_rd('h154,sequence_number);
        wr('h140,held[31:0]);wr('h144,(held[63:32]&32'hfffffff0)|10);wr('h14c,5);check_rd('h154,sequence_number);
        wr('h144,held[63:32]);wr('h148,(held[95:64]&32'hffffff0f)|32'ha0);wr('h14c,5);check_rd('h154,sequence_number);
        test_passed=1;$display("MODE_MENU_AHB_HUD_CDC_PASS: 102 production vectors, waits, frozen payload, bit95, selection9, invalid BCD/status flags, reset");$finish;
    end
    initial begin #100000000;$fatal(1,"service watchdog");end
endmodule

module tb_camera_codes;
    reg test_passed=0;
    reg [15:0] gain,ae;
    wire [23:0] code,ae_word;
    reg [8:0] index;
    wire [8:0] count;
    SC520GainTbl mapping(.I_AG(gain),.O(code));
    uics520regAE exposure(.REG_INDEX(index),.REG_DATA(ae_word),.REG_SIZE(count),.I_AE(ae),.I_AG(code));
    string vectors;integer fd,n,cases;
    reg [23:0] want_gain,want_ae,got_ae;
    initial begin

        fd=$fopen({vectors,"/camera_codes.txt"},"r");if(!fd) $fatal(1,"code vectors");cases=0;
        while(!$feof(fd)) begin
            n=$fscanf(fd,"%h %h %h\n",gain,want_gain,want_ae);
            if(n==3) begin
                ae=gain;index=1;#1;got_ae[23:16]=ae_word[7:0];
                index=2;#1;got_ae[15:8]=ae_word[7:0];index=3;#1;got_ae[7:0]=ae_word[7:0];
                if(code!==want_gain || got_ae!==want_ae) $fatal(1,"C/RTL camera encoding %h",gain);
                cases++;
            end
        end
        if(cases!=65536) $fatal(1,"incomplete codes");
        test_passed=1;$display("MCU_CAMERA_CODES_PASSED: 65536 AE and gain encodings versus retained RTL");$finish;
    end
endmodule
