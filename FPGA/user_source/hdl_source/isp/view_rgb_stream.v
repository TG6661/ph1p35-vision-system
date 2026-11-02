// Whole-frame selection and elastic 4-bit-mask -> RGB888 -> 128-bit packing.
// The selected detection tap is backpressured; the fixed-rate ISP never stalls.
// m_start precedes mask payload by 64 clocks for video_in FIFO reset/CDC.
module view_rgb_stream #(parameter WIDTH=1280,HEIGHT=720,ELASTIC_COLOR=0)(
    input wire clk,rst_n,
    input wire [1:0] requested,
    input wire [127:0] color_data,
    input wire color_valid,color_start,
    output wire color_ready,idle,
    input wire [3:0] raw_data,erode_data,clean_data,
    input wire raw_valid,raw_user,erode_valid,erode_user,clean_valid,clean_user,
    output wire raw_ready,erode_ready,clean_ready,
    input wire frame_ready,m_ready,
    output reg [127:0] m_data,
    output reg m_valid,m_start,m_abort,
    output reg [1:0] m_mode
);
    localparam WORDS=WIDTH*HEIGHT*3/16;
    localparam IDLE=0,COLOR=1,LEAD=2,MASK=3,DRAIN=4;
    reg [2:0] state;
    reg [6:0] lead;
    reg [1:0] phase;
    reg [95:0] carry;
    reg [$clog2(WORDS+1)-1:0] words;
    wire [1:0] selected=state==IDLE ? requested : m_mode;
    wire [3:0] bits=selected==1 ? raw_data : selected==2 ? erode_data : clean_data;
    wire valid=selected==1 ? raw_valid : selected==2 ? erode_valid : clean_valid;
    wire user=selected==1 ? raw_user : selected==2 ? erode_user : clean_user;
    wire [95:0] rgb={{24{bits[3]}},{24{bits[2]}},{24{bits[1]}},{24{bits[0]}}};
    wire advance=!m_valid || m_ready;
    assign idle=state==IDLE;
    assign color_ready=state==COLOR ? advance : (state==IDLE ? requested!=0 : m_mode!=0);
    wire accept=(state==IDLE && frame_ready && requested!=0) || (state==MASK && advance);
    // Unselected streams run freely. Hold a selected SOF until the writer is free.
    assign raw_ready=selected!=1 || (state==IDLE ? (!raw_user || accept) : accept);
    assign erode_ready=selected!=2 || (state==IDLE ? (!erode_user || accept) : accept);
    assign clean_ready=selected!=3 || (state==IDLE ? (!clean_user || accept) : accept);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=IDLE;lead<=0;phase<=0;carry<=0;words<=0;
            m_data<=0;m_valid<=0;m_start<=0;m_abort<=0;m_mode<=0;
        end else begin
            m_start<=0;m_abort<=0;
            if(advance) m_valid<=0;
            case(state)
                IDLE: begin
                    if(requested==0 && color_start && frame_ready) begin
                        m_mode<=0;m_start<=1;words<=0;lead<=0;state<=ELASTIC_COLOR ? LEAD : COLOR;
                    end else if(requested!=0 && valid && user && accept) begin
                        m_mode<=requested;m_start<=1;words<=0;carry<=rgb;
                        phase<=1;lead<=0;state<=LEAD;
                    end
                end
                COLOR: begin
                    // Fixed-rate stream: writer detects overflow and discards that frame.
                    if(!ELASTIC_COLOR || advance) begin m_valid<=color_valid;m_data<=color_data;end
                    if(color_start) begin m_valid<=0;m_abort<=1;state<=IDLE;end
                    else if(color_valid && (!ELASTIC_COLOR || color_ready)) begin
                        words<=words+1'b1;
                        if(words==WORDS-1) state<=DRAIN;
                    end
                end
                LEAD: if(lead==63) state<=m_mode==0 ? COLOR : MASK;else lead<=lead+1'b1;
                MASK: if(valid && accept) begin
                    carry<=rgb;phase<=phase+1'b1;
                    case(phase)
                        0: ;
                        1: begin m_data<={carry,rgb[95:64]};m_valid<=1;end
                        2: begin m_data<={carry[63:0],rgb[95:32]};m_valid<=1;end
                        3: begin m_data<={carry[31:0],rgb};m_valid<=1;end
                    endcase
                    if(phase!=0) begin
                        words<=words+1'b1;
                        if(words==WORDS-1) state<=DRAIN;
                    end
                end
                DRAIN: if((m_mode==0 && !ELASTIC_COLOR) || advance) begin m_valid<=0;state<=IDLE;end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
