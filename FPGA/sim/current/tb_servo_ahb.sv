`timescale 1ns/1ps
module tb_mcu_ahb;
    reg clk=0, async_reset_n=0;
    always #3.333 clk=~clk;
    wire rst_n;
    mcu_reset_sync u_reset(.clk(clk),.async_reset_n(async_reset_n),.reset_n(rst_n));
    reg [1:0] trans=0;
    reg write=0;
    reg [30:0] addr=0;
    reg [2:0] size=2;
    reg [31:0] wdata=0;
    wire [31:0] rdata;
    wire [1:0] resp;
    wire ready;
    reg [3:0] buttons=15;
    reg [7:0] status=0;
    reg test_passed=0,menu_done=0;
    ahb_ctrl_regs dut(.I_ahb_clk(clk),.I_ahb_rst_n(rst_n),
        .I_htrans(trans),.I_hwrite(write),.I_haddr(addr),.I_hsize(size),
        .I_hwdata(wdata),.O_hrdata(rdata),.O_hresp(resp),.O_hready(ready),
        .I_button(buttons),.I_hw_status(status),.I_ctrl_ready(1'b1),.I_ctrl_done(1'b0),
        .I_completed(25'd0),.I_selected(25'd0),.I_active(25'd0),.O_submit(),.O_command(),.I_menu_ready(1'b1),.I_menu_done(menu_done),.O_menu_submit(),.O_menu_command(),.O_target_write(),.O_target_write_word(),.O_target_wdata(),.O_target_read_word(),.O_service_write(),.O_service_write_word(),.O_service_read_word(),.I_service_rdata(32'd0),.I_target_rdata(32'd0),.O_ext_write(),.O_ext_write_word(),.O_ext_read_word(),.I_ext_rdata(32'd0),.O_servo_pan(),.O_servo_tilt());
    task check(input bit ok,input string message);
        if (!ok) $fatal(1,"%s",message);
    endtask
    task release_reset;
        begin
            @(negedge clk); async_reset_n=1;
            repeat(15) begin @(posedge clk); #0.1; check(!rst_n,"reset released too early"); end
            @(posedge clk); #0.1; check(rst_n,"reset did not release on clock 16");
        end
    endtask
    task rd(input [30:0] a, input [31:0] expected);
        begin
            @(negedge clk); trans=2; write=0; addr=a; size=2;
            @(posedge clk); #0.1;
            while(!ready)begin @(posedge clk);#0.1;end
            check(rdata===expected,$sformatf("read %h got %h expected %h",a,rdata,expected));
            @(negedge clk); trans=0;
            @(posedge clk); #0.1;
        end
    endtask
    task wr(input [30:0] a,input [2:0] sz,input [31:0] data);
        begin
            @(negedge clk); trans=2; write=1; addr=a; size=sz; wdata=32'hbad0bad0;
            @(negedge clk); trans=0; wdata=data;
            repeat(2) @(posedge clk); #0.1;
        end
    endtask
    // Independent bus scoreboard for arbitrary address/data phase overlap.
    reg pending=0,pwrite=0,delayed_write=0;
    reg [30:0] delayed_addr;reg [31:0] delayed_data;
    integer waits=0;reg pre_ready;reg [31:0] model_response=0;
    reg [30:0] paddr;
    reg [31:0] model0=0,model1=0,expected;
    integer i,choice;
    reg [31:0] seed=32'h19751016;
    function [31:0] next_random(input [31:0] x);
        reg [31:0] y;
        begin y=x^(x<<13); y=y^(y>>17); next_random=y^(y<<5); end
    endfunction
    initial begin
        #1; release_reset();
        rd(0,32'hA5010006); rd(4,0); rd(8,0);
        rd('h70,32'h53560101);rd('h64,1500);rd('h68,1500);rd('h74,(1500<<12)|1500);
        wr('h64,2,400);rd('h64,500);wr('h68,2,9999);rd('h68,2500);
        wr('h64,0,1700);wr('h65,2,1800);wr(31'h40000064,2,1900);rd('h64,500);
        wr('h6c,2,1);rd('h6c,1);wr('h64,2,1800);wr('h6c,2,1);rd('h6c,3);
        wr('h6c,2,6);rd('h6c,0);rd('h74,(1500<<12)|1500);
        wr('h70,2,0);rd('h70,32'h53560101);rd('h78,0);rd('h7c,0);
        // Genuine back-to-back address/data pipelining for both widths+commit.
        @(negedge clk);trans=2;write=1;addr='h64;
        @(negedge clk);addr='h68;wdata=1234;
        @(negedge clk);addr='h6c;wdata=2345;
        @(negedge clk);trans=0;wdata=5;
        repeat(3)@(negedge clk);
        rd('h64,1234);rd('h68,2345);rd('h6c,1);
        check(dut.u_servo.pending_pan==1234 && dut.u_servo.pending_tilt==2345,"consecutive atomic pair");
        wr('h6c,2,6);rd('h6c,0);
        wr('h48,2,(10<<15)|(6<<11)|(1<<10)|(32<<2)|3);wr('h4c,2,5);rd('h54,1);
        @(negedge clk);menu_done=1;@(negedge clk);menu_done=0;rd('h58,1);
        wr('h48,2,(11<<15)|(6<<11)|(1<<10)|(32<<2)|3);wr('h4c,2,5);rd('h54,1);
        wr(4,2,32'h12345678); wr(8,2,32'h89abcdef);
        rd(4,32'h12345678); rd(8,32'h89abcdef);
        // Read-only, misaligned, byte/halfword, upper aliases and reserved extended writes.
        wr(0,2,0); wr(12,2,0); wr(16,2,0); wr(20,2,0);
        wr(4,0,0); wr(4,1,0); wr(4,3,0); wr(5,2,0);
        wr(31'h204,2,0); wr(31'h40000004,2,0); wr(24,2,0);
        rd(0,32'hA5010006); rd(4,32'h12345678); rd(8,32'h89abcdef);
        rd(24,0); rd(31'h204,0); rd(31'h40000004,0); rd(5,0);
        // Service/extended addresses read tied-zero data; upper aliases remain invalid.
        for(i=8;i<31;i=i+1) begin
            wr((31'd1<<i)|31'd4,2,0);
            rd((31'd1<<i)|31'd4,0);
            rd(4,32'h12345678);
        end
        // Every physical key bit plus both transitions on all status bits.
        for(i=0;i<4;i=i+1) begin
            @(negedge clk); buttons=15^(1<<i);
            repeat(3) @(posedge clk);
            rd(12,{28'd0,buttons});
        end
        for(i=0;i<8;i=i+1) begin
            @(negedge clk); status=1<<i;
            repeat(3) @(posedge clk); rd(16,{24'd0,status});
        end
        @(negedge clk); status=0; buttons=15;
        repeat(3) @(posedge clk); rd(16,0); rd(12,15);
        // Alternating writes/reads and SEQ/NONSEQ/IDLE/BUSY with unrelated HWDATA.
        model0=32'h12345678; model1=32'h89abcdef;
        for(i=0;i<2000;i=i+1) begin
            @(negedge clk);
            if(ready) begin
                seed=next_random(seed);trans=seed[1:0];write=seed[2];size=seed[5]?2:seed[8:6];
                choice=seed[12:9];
                case(choice)
                    0:addr=0;1,2,3:addr=4;4,5,6:addr=8;
                    7:addr=12;8:addr=16;9:addr=24;10:addr=31'h80;11:addr=31'hfc;
                    12:addr=31'h204;13:addr=5;14:addr=31'h40000004;default:addr=28;
                endcase
                seed=next_random(seed);wdata=seed;
            end
            // Predict from bus transactions only, including address freeze during
            // waits and the one-cycle write execution stage. No DUT internals.
            @(posedge clk);
            pre_ready=!(pending && !pwrite && waits!=0);
            if(!pre_ready) begin
                if(waits==1) begin
                    model_response=0;
                    case(paddr)
                        0:model_response=32'hA5010006;4:model_response=model0;8:model_response=model1;
                        12:model_response=15;16:model_response=0;default:model_response=0;
                    endcase
                end
                waits=waits-1;
            end else model_response=0;
            if(delayed_write) begin
                if(delayed_addr==4)model0=delayed_data;
                if(delayed_addr==8)model1=delayed_data;
            end
            delayed_write=pending && pwrite;delayed_addr=paddr;delayed_data=wdata;
            if(pre_ready)begin
                pending=trans[1] && size==2 && addr[1:0]==0 && addr<2048;
                pwrite=write;paddr=addr;waits=(|addr[10:7])?3:2;
            end
            #0.1; // Compare after sequential assignments have settled.
            expected=model_response;
            check(ready===!(pending && !pwrite && waits!=0) && resp===2'b00,"AHB wait/response mismatch");
            check(rdata===expected,$sformatf("pipelined cycle %0d got %h expected %h",i,rdata,expected));
        end
        // Drain the last stalled transaction before starting a reset scenario.
        while(!ready)@(negedge clk);
        trans=0;repeat(4)@(negedge clk);
        // Reset between address and data phases must cancel the pending write.
        @(negedge clk); trans=2; write=1; addr=4; size=2;
        @(posedge clk); #0.2; async_reset_n=0; #0.1;
        check(!rst_n,"reset assertion was not asynchronous");
        trans=0; wdata=32'hffffffff;
        release_reset(); rd(4,0); rd(8,0); rd(0,32'hA5010006);
        // Reset after HWDATA capture but before the delayed register write.
        @(negedge clk);trans=2;write=1;addr=4;size=2;
        @(negedge clk);trans=0;wdata=32'hbadcaffe;
        @(posedge clk);#0.2;async_reset_n=0;
        release_reset();rd(4,0);
        // A reset during a read wait cancels both its stall and response.
        @(negedge clk);trans=2;write=0;addr=0;size=2;
        @(posedge clk);#0.2;check(!ready,"read did not wait");async_reset_n=0;#0.1;
        check(ready && rdata==0,"reset left stale read/stall");trans=0;
        release_reset();rd(0,32'hA5010006);
        // Counter reads are snapshots; registered response holds within a beat.
        @(negedge clk);trans=2;write=0;addr=20;size=2;
        @(posedge clk);#0.1;while(!ready)begin @(posedge clk);#0.1;end
        expected=rdata;
        @(negedge clk);check(rdata==expected,"counter response changed before acceptance");
        // Keep a second read address on the bus: consecutive read with waits.
        @(posedge clk);#0.1;while(!ready)begin @(posedge clk);#0.1;end
        check(rdata==expected+3,"AHB counter snapshot did not advance by transaction interval");
        @(negedge clk);trans=0;
        test_passed=1;
        $display("MCU_AHB_TEST_PASSED: 2000-cycle stalled bus scoreboard, decode, staged writes, read snapshots, reset in read/write stages, counter");
        $finish;
    end
    initial begin #200000; $fatal(1,"test timeout"); end
endmodule
