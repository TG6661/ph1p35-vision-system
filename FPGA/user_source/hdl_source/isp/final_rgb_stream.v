// FINAL-only specialization of view_rgb_stream with ELASTIC_COLOR=1.
// Preserve the 64-clock FIFO-reset lead, whole-frame count and backpressure.
module final_rgb_stream #(parameter WIDTH=1280,HEIGHT=720)(
    input wire clk,rst_n,
    input wire [127:0] color_data,
    input wire color_valid,color_start,
    output wire color_ready,idle,
    input wire frame_ready,m_ready,
    output reg [127:0] m_data,
    output reg m_valid,m_start,m_abort
);
    localparam WORDS=WIDTH*HEIGHT*3/16;
    localparam IDLE=0,COLOR=1,LEAD=2,DRAIN=3;
    reg [1:0] state;
    reg [6:0] lead;
    reg [$clog2(WORDS+1)-1:0] words;
    wire advance=!m_valid || m_ready;
    assign idle=state==IDLE;
    assign color_ready=state==COLOR && advance;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;lead<=0;words<=0;
            m_data<=0;m_valid<=0;m_start<=0;m_abort<=0;
        end else begin
            m_start<=0;m_abort<=0;
            if(advance) m_valid<=0;
            case(state)
                IDLE: if(color_start && frame_ready) begin
                    m_start<=1;words<=0;lead<=0;state<=LEAD;
                end
                COLOR: begin
                    if(advance) begin m_valid<=color_valid;m_data<=color_data;end
                    if(color_start) begin m_valid<=0;m_abort<=1;state<=IDLE;end
                    else if(color_valid && color_ready) begin
                        words<=words+1'b1;
                        if(words==WORDS-1) state<=DRAIN;
                    end
                end
                LEAD: if(lead==63) state<=COLOR;else lead<=lead+1'b1;
                DRAIN: if(advance) begin m_valid<=0;state<=IDLE;end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
