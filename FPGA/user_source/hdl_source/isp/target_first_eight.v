// Consume all CCL records, forward only the first eight before classification.
module target_first_eight(
    input wire clk,rst_n,
    input wire s_valid,
    output wire s_ready,
    input wire [69:0] s_data,
    input wire s_done_valid,
    output wire s_done_ready,
    input wire [3:0] s_error,
    output wire m_valid,
    input wire m_ready,
    output wire [69:0] m_data,
    output wire m_done_valid,
    input wire m_done_ready,
    output wire [15:0] m_count,
    output wire [3:0] m_error
);
    reg [3:0] selected;
    assign s_ready=rst_n && (selected==8 || m_ready);
    assign m_valid=rst_n && s_valid && selected<8;
    assign m_data=s_data;
    assign m_count={12'b0,selected};
    assign m_error=s_error;
    assign m_done_valid=rst_n && s_done_valid && !s_valid;
    assign s_done_ready=rst_n && m_done_ready && !s_valid;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) selected<=0;
        else if(s_done_valid && s_done_ready) selected<=0;
        else if(s_valid && s_ready && selected<8) selected<=selected+1'b1;
    end
endmodule
