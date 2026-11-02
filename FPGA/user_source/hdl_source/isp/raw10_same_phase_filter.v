// Same-phase Bayer filter adapted from the local reference example.
(* dsp_style="no" *) module raw10_same_phase_filter #(
    parameter WIDTH=1280,
    parameter FRAME_BYPASS=0 // Opt in to frame-latched STRONG/bypass; legacy default is STRONG.
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire [39:0] I_tdata,
    input  wire        I_tvalid,
    input  wire        I_tuser,
    input  wire        I_tlast,
    input  wire [1:0]  I_mode, // FRAME_BYPASS=1: 3=STRONG, otherwise aligned bypass; sample at valid SOF.
    output reg  [39:0] O_tdata,
    output reg         O_tvalid,
    output reg         O_tuser,
    output reg         O_tlast
);
    localparam integer BEATS_PER_LINE = WIDTH/4; // 1280 RAW pixels / 4
    // Simple dual-port 512x40 RAM: read the old row now, overwrite it one
    // clock later using the existing s_* pipeline. This permits one 20K ERAM
    // per parity bank instead of a 40-bit true-dual-port READBEFOREWRITE RAM.
    localparam LINE_ADDR_BITS=(BEATS_PER_LINE>1)?$clog2(BEATS_PER_LINE):1;
    reg [8:0] column;
    reg [9:0] row;
    wire [8:0] column_now = I_tuser ? 9'd0 : column;
    wire [9:0] row_now = I_tuser ? 10'd0 : row;
    reg frame_strong,s_strong;
    wire strong_now = !FRAME_BYPASS || (I_tuser ? I_mode==2'd3 : frame_strong);

    // Synchronous line-memory read and write. Validity prevents the first
    // two rows from consuming stale RAM contents at a new frame boundary.
    reg [39:0] s_data;
    reg [8:0] s_col;
    reg s_valid, s_user, s_last, s_upper_valid;
    wire [39:0] even_q,odd_q;
    reg s_row_odd;
    wire [39:0] s_upper=s_row_odd ? odd_q : even_q;
    // Isolate the ERAM write port from the same-edge s_* launch registers.
    // The routed rising->rising data paths failed hold (fast-corner -123ps).
    // Copy the complete write bundle on the intervening falling edge: at
    // the next rising edge it is identical to the old s_* write transaction.
    // Read clocks, read-before-overwrite order and output latency are unchanged.
    // These are real half-cycle paths; keep setup AND hold analysis enabled.
    reg [39:0] ram_write_data;
    reg [LINE_ADDR_BITS-1:0] ram_write_col;
    reg ram_write_valid,ram_write_odd;
    always @(negedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n) begin
            ram_write_data<=40'd0;
            ram_write_col<={LINE_ADDR_BITS{1'b0}};
            ram_write_valid<=1'b0;
            ram_write_odd<=1'b0;
        end else begin
            ram_write_data<=s_data;
            ram_write_col<=s_col[LINE_ADDR_BITS-1:0];
            ram_write_valid<=s_valid;
            ram_write_odd<=s_row_odd;
        end
    end
    isp_line_ram #(.DATA_WIDTH_A(40),.DATA_WIDTH_B(40),
        .ADDR_WIDTH_A(LINE_ADDR_BITS),.ADDR_WIDTH_B(LINE_ADDR_BITS),
        .DATA_DEPTH_A(1<<LINE_ADDR_BITS),.DATA_DEPTH_B(1<<LINE_ADDR_BITS),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.RAM_MODE("PDPW"),.CLK_MODE("SYNC")) u_even_eram(
        .clka(I_clk),.wea(I_rst_n && ram_write_valid && !ram_write_odd),.addra(ram_write_col),.dia(ram_write_data),.doa(),
        .clkb(I_clk),.web(1'b0),.addrb(column_now[LINE_ADDR_BITS-1:0]),.dib(40'd0),.dob(even_q));
    isp_line_ram #(.DATA_WIDTH_A(40),.DATA_WIDTH_B(40),
        .ADDR_WIDTH_A(LINE_ADDR_BITS),.ADDR_WIDTH_B(LINE_ADDR_BITS),
        .DATA_DEPTH_A(1<<LINE_ADDR_BITS),.DATA_DEPTH_B(1<<LINE_ADDR_BITS),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.RAM_MODE("PDPW"),.CLK_MODE("SYNC")) u_odd_eram(
        .clka(I_clk),.wea(I_rst_n && ram_write_valid && ram_write_odd),.addra(ram_write_col),.dia(ram_write_data),.doa(),
        .clkb(I_clk),.web(1'b0),.addrb(column_now[LINE_ADDR_BITS-1:0]),.dib(40'd0),.dob(odd_q));
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            column <= 9'd0;
            row <= 10'd0;
            s_data <= 40'd0;
            s_row_odd <= 1'b0;
            s_col <= 9'd0;
            s_valid <= 1'b0;
            s_user <= 1'b0;
            s_last <= 1'b0;
            s_upper_valid <= 1'b0;
            frame_strong <= 1'b0;
            s_strong <= 1'b0;
        end else begin
            s_valid <= I_tvalid;
            if (I_tvalid) begin
                if (I_tuser) frame_strong <= I_mode==2'd3;
                s_strong <= strong_now;
                s_data <= I_tdata;
                s_col <= column_now;
                s_user <= I_tuser;
                s_last <= I_tlast;
                s_upper_valid <= (row_now >= 10'd2);
                s_row_odd<=row_now[0];
                column <= I_tlast ? 9'd0 : column_now + 1'b1;
                if (I_tlast) row <= row_now + 1'b1;
                else if (I_tuser) row <= 10'd0;
            end
        end
    end

    // STRONG only: (2C+2U+L+R+UL+UR)/8, U is y-2 of the same Bayer phase.
    // No WEAK/MED arithmetic. Optional bypass shares all data/flag scheduling.
    function [9:0] filtered_pixel;
        input [9:0] c, l, r, u, ul, ur;
        reg [12:0] center_term,upper_term,diagonal,sum;
        begin
            // Fixed STRONG: exact original mode-3 weights and truncation.
            center_term=({3'd0,c}<<1);
            upper_term=({3'd0,u}<<1);
            diagonal={3'd0,ul}+{3'd0,ur};
            sum=(center_term+upper_term)+({3'd0,l}+{3'd0,r})+diagonal;
            filtered_pixel=sum[12:3];
        end
    endfunction

    // Shared A(x)=C(x)+U(x), STRONG=(2*A(x)+A(x-2)+A(x+2))>>3.
    // Keep all 11-bit vertical sums; never round before the final 13-bit sum.
    function [43:0] vertical_sum;
        input [39:0] pixels,upper;
        integer lane;
        begin
            for(lane=0;lane<4;lane=lane+1)
                vertical_sum[lane*11+:11]={1'b0,pixels[lane*10+:10]}+
                                        {1'b0,upper[lane*10+:10]};
        end
    endfunction
    function [9:0] sum_pixel;
        input [10:0] c,l,r;
        reg [12:0] sum;
        begin
            sum={1'b0,c,1'b0}+({2'b0,l}+{2'b0,r});
            sum_pixel=sum[12:3];
        end
    endfunction
    function [39:0] filtered_sums;
        input [43:0] p,c,n;
        input first_beat,last_beat;
        begin
            filtered_sums={
                sum_pixel(c[43:33],c[21:11],last_beat?c[43:33]:n[21:11]),
                sum_pixel(c[32:22],c[10:0],last_beat?c[32:22]:n[10:0]),
                sum_pixel(c[21:11],first_beat?c[21:11]:p[43:33],c[43:33]),
                sum_pixel(c[10:0],first_beat?c[10:0]:p[32:22],c[32:22])};
        end
    endfunction

    reg [39:0] prev_data, center_data, prev_upper, center_upper;
    reg [8:0] center_col;
    reg center_valid, center_user, center_last;
    reg center_strong;
    wire flush_last=center_last && (!s_valid || s_col==0);
    wire [39:0] right_data=flush_last?center_data:s_data;
    wire [39:0] right_upper=flush_last?center_upper:(s_upper_valid?s_upper:s_data);
    wire [43:0] pair_prev=vertical_sum(prev_data,prev_upper);
    wire [43:0] pair_center=vertical_sum(center_data,center_upper);
    wire [43:0] pair_right=vertical_sum(right_data,right_upper);
    wire [39:0] filtered_output=filtered_sums(pair_prev,pair_center,pair_right,
                                             center_col==0,flush_last);
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            prev_data <= 40'd0;
            center_data <= 40'd0;
            prev_upper <= 40'd0;
            center_upper <= 40'd0;
            center_col <= 9'd0;
            center_valid <= 1'b0;
            center_user <= 1'b0;
            center_last <= 1'b0;
            center_strong <= 1'b0;
            O_tdata <= 40'd0;
            O_tvalid <= 1'b0;
            O_tuser <= 1'b0;
            O_tlast <= 1'b0;
        end else begin
            O_tvalid <= 1'b0;
            O_tuser <= 1'b0;
            O_tlast <= 1'b0;
            if (s_valid) begin
                if (s_col == 9'd0) begin
                    // A row without blanking can start on the flush cycle.
                    if (center_valid && center_last) begin
                        O_tdata <= (!FRAME_BYPASS || center_strong) ? filtered_output : center_data;
                        O_tvalid <= 1'b1;
                        O_tuser <= center_user;
                        O_tlast <= 1'b1;
                    end
                    center_data <= s_data;
                    center_upper <= s_upper_valid ? s_upper : s_data;
                    prev_data <= s_data;
                    prev_upper <= s_upper_valid ? s_upper : s_data;
                    center_col <= s_col;
                    center_user <= s_user;
                    center_last <= s_last;
                    center_valid <= 1'b1;
                    center_strong <= s_strong;
                end else begin
                    if (center_valid) begin
                        O_tdata <= (!FRAME_BYPASS || center_strong) ? filtered_output : center_data;
                        O_tvalid <= 1'b1;
                        O_tuser <= center_user;
                        O_tlast <= center_last;
                    end
                    prev_data <= center_data;
                    prev_upper <= center_upper;
                    center_data <= s_data;
                    center_upper <= s_upper_valid ? s_upper : s_data;
                    center_col <= s_col;
                    center_user <= s_user;
                    center_last <= s_last;
                    center_valid <= 1'b1;
                    center_strong <= s_strong;
                end
            end else if (center_valid && center_last) begin
                O_tdata <= (!FRAME_BYPASS || center_strong) ? filtered_output : center_data;
                O_tvalid <= 1'b1;
                O_tuser <= center_user;
                O_tlast <= 1'b1;
                center_valid <= 1'b0;
            end
        end
    end
endmodule
