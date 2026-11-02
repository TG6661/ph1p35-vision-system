// Read-only replay of complete captured RGB frames. No temporal blend or history.
// frame_tag is retained as reserved metadata for capture interface compatibility.
module rgb_frame_replay #(
    parameter WIDTH=1280,HEIGHT=720,BLOCK=16,
    parameter [24:0] CAP_BASE=28000000
)(
    input wire clk,rst_n,
    input wire frame_valid,start_ready,
    input wire [31:0] frame_sequence,
    input wire [1:0] frame_bank,
    input wire [50:0] frame_tag,
    input wire [91:0] frame_diagnostics,
    output reg [1:0] locked_bank,
    output reg frame_start,
    output reg [91:0] active_diagnostics,
    output wire [127:0] m_data,
    output wire m_valid,
    input wire m_ready,
    output wire rd_en,wr_en,
    output wire [24:0] address,
    output wire [127:0] wr_data,
    input wire bus_ready,rd_valid,
    input wire [127:0] rd_data,
    output reg error,
    output reg [31:0] completed,output wire idle,output reg [50:0] active_tag
);
    localparam WORDS=WIDTH*HEIGHT*3/16,SPAN=WORDS*8;
    localparam IDLE=0,CUR_REQ=1,CUR_WAIT=2,LOAD=3,STREAM=4;
    reg [2:0] state;
    reg [127:0] block_data[0:BLOCK-1]; // synthesis ram_style=dram
    reg [$clog2(BLOCK+1)-1:0] issued,returned,index;
    reg [$clog2(WORDS+1)-1:0] offset;
    reg [24:0] current_base;
    reg [31:0] last_sequence;
    reg [127:0] block_q;
    assign idle=state==IDLE;
    assign rd_en=state==CUR_REQ && bus_ready;
    assign wr_en=1'b0; // No history writes. Kept for the shared DDR client interface.
    assign wr_data=128'd0;
    assign address=current_base+((offset+issued)<<3);
    assign m_data=block_q;
    assign m_valid=state==STREAM;
    always @(posedge clk) begin
        block_q<=block_data[index[$clog2(BLOCK)-1:0]];
        if(rst_n && rd_valid && (state==CUR_REQ || state==CUR_WAIT) && returned<BLOCK)
            block_data[returned[$clog2(BLOCK)-1:0]]<=rd_data;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;issued<=0;returned<=0;index<=0;offset<=0;
            current_base<=0;last_sequence<=0;
            locked_bank<=0;frame_start<=0;active_tag<=0;active_diagnostics<=0;error<=0;completed<=0;
        end else begin
            frame_start<=0;
            if(rd_valid) begin
                if((state==CUR_REQ || state==CUR_WAIT) && returned<BLOCK) returned<=returned+1'b1;
                else error<=1;
            end
            case(state)
                IDLE:if(frame_valid && frame_sequence!=last_sequence && start_ready) begin
                    last_sequence<=frame_sequence;locked_bank<=frame_bank;
                    case(frame_bank)
                        0:current_base<=CAP_BASE;1:current_base<=CAP_BASE+SPAN;
                        2:current_base<=CAP_BASE+2*SPAN;3:current_base<=CAP_BASE+3*SPAN;
                    endcase
                    active_diagnostics<=frame_diagnostics;active_tag<=frame_tag;
                    offset<=0;issued<=0;returned<=0;index<=0;frame_start<=1;state<=CUR_REQ;
                end
                CUR_REQ:if(rd_en) begin
                    issued<=issued+1'b1;if(issued==BLOCK-1) state<=CUR_WAIT;
                end
                CUR_WAIT:if(returned==BLOCK) begin issued<=0;returned<=0;index<=0;state<=LOAD;end
                LOAD:state<=STREAM;
                STREAM:if(m_ready) begin
                    if(index==BLOCK-1) begin
                        index<=0;issued<=0;returned<=0;
                        if(offset==WORDS-BLOCK) begin completed<=completed+1'b1;state<=IDLE;end
                        else begin offset<=offset+BLOCK;state<=CUR_REQ;end
                    end else begin index<=index+1'b1;state<=LOAD;end
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule

// Three packed 128-bit words become four ordered RGB96 beats. No AXI marker
// is inferred from clock gaps: SOF/EOL are derived from accepted pixel counts.
module rgb_unpack96 #(parameter WIDTH=1280,HEIGHT=720)(
    input wire clk,rst_n,
    input wire [127:0] s_data,input wire s_valid,output wire s_ready,
    output wire [95:0] m_data,output wire m_valid,m_user,m_last
);
    // Each input word is written once into a fixed bank. Output selection
    // replaces the former 384-bit, two-direction-size shifting datapath.
    // All three banks are overwritten before outputting becomes true.
    reg [127:0] word0,word1,word2;
    reg [1:0] received,lane;
    reg outputting;
    reg [$clog2(WIDTH/4)-1:0] x;
    reg [$clog2(HEIGHT)-1:0] y;
    assign s_ready=!outputting;
    assign m_valid=outputting;
    wire [95:0] selected_word=(lane==0)?word0[127:32]:
        (lane==1)?{word0[31:0],word1[127:64]}:
        (lane==2)?{word1[63:0],word2[127:96]}:word2[95:0];
    // The old shifter is zero in every non-output cycle, including partial
    // groups. Preserve that behavior without resetting the payload banks.
    assign m_data=outputting?selected_word:96'd0;
    assign m_user=outputting && x==0 && y==0;
    assign m_last=outputting && x==WIDTH/4-1;
    always @(posedge clk) begin
        if(rst_n && s_valid && s_ready) begin
            case(received)
                0:word0<=s_data;
                1:word1<=s_data;
                2:word2<=s_data;
            endcase
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin received<=0;lane<=0;outputting<=0;x<=0;y<=0;end
        else begin
            if(s_valid && s_ready) begin
                if(received==2) begin received<=0;lane<=0;outputting<=1;end
                else received<=received+1'b1;
            end
            if(outputting) begin
                lane<=lane+1'b1;
                if(lane==3) outputting<=0;
                if(x==WIDTH/4-1) begin x<=0;y<=y==HEIGHT-1 ? 0 : y+1'b1;end
                else x<=x+1'b1;
            end
        end
    end
endmodule
