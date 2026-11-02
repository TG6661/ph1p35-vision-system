// DLFPGA: 3x3 erosion followed by an effective 5x5 square dilation.
// Two cascaded 3x3 dilations implement the 5x5 neighborhood exactly.
// The legacy module name is retained; unequal kernels are not a formal opening.
// Debug erosion tap is an atomic fanout; the final output is the second dilation.
module binary_open_bram_4 #(parameter WIDTH=1280, HEIGHT=720)(
    input wire clk, rst_n,
    input wire [3:0] s_tdata,
    input wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    output wire [3:0] m_tdata,
    output wire m_tvalid, m_tuser, m_tlast,
    input wire m_tready,
    output wire [3:0] debug_erode_data,
    output wire debug_erode_valid,debug_erode_user,
    input wire debug_erode_ready
);
    wire [3:0] erode_data;
    wire erode_valid, erode_ready, erode_user, erode_last, dilate_ready;
    wire [3:0] dilate3_data;
    wire dilate3_valid, dilate3_user, dilate3_last, dilate3_ready;
    assign erode_ready=dilate_ready && debug_erode_ready;
    assign debug_erode_data=erode_data;
    assign debug_erode_valid=erode_valid && dilate_ready;
    assign debug_erode_user=erode_user;
    binary_morph_bram_4 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.DILATE(0)) u_erode(
        .clk(clk),.rst_n(rst_n),.s_tdata(s_tdata),.s_tvalid(s_tvalid),
        .s_tuser(s_tuser),.s_tlast(s_tlast),.s_tready(s_tready),
        .m_tdata(erode_data),.m_tvalid(erode_valid),.m_tuser(erode_user),
        .m_tlast(erode_last),.m_tready(erode_ready));
    binary_morph_bram_4 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.DILATE(1)) u_dilate(
        .clk(clk),.rst_n(rst_n),.s_tdata(erode_data),.s_tvalid(erode_valid && debug_erode_ready),
        .s_tuser(erode_user),.s_tlast(erode_last),.s_tready(dilate_ready),
        .m_tdata(dilate3_data),.m_tvalid(dilate3_valid),.m_tuser(dilate3_user),
        .m_tlast(dilate3_last),.m_tready(dilate3_ready));
    binary_morph_bram_4 #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.DILATE(1)) u_dilate_second(
        .clk(clk),.rst_n(rst_n),.s_tdata(dilate3_data),.s_tvalid(dilate3_valid),
        .s_tuser(dilate3_user),.s_tlast(dilate3_last),.s_tready(dilate3_ready),
        .m_tdata(m_tdata),.m_tvalid(m_tvalid),.m_tuser(m_tuser),
        .m_tlast(m_tlast),.m_tready(m_tready));
endmodule
