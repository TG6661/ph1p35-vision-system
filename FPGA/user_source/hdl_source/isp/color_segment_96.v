// Four RGB888 pixels, MSB first; mask[3] is pixel 0.
// Three registered stages freeze together under downstream backpressure.
// Thresholds commit on accepted SOF; its first beat uses the new thresholds.
module color_segment_96(
    input wire clk,rst_n,
    input wire [7:0] cfg_rmin,cfg_rgap,cfg_bgap,
    input wire [95:0] s_tdata,
    input wire s_tvalid,
    output wire s_tready,
    input wire s_tuser,s_tlast,
    output reg [3:0] m_tdata,
    output reg m_tvalid,
    input wire m_tready,
    output reg m_tuser,m_tlast
);
    reg [7:0] active_rmin,active_rgap,active_bgap;
    wire [7:0] use_rmin=s_tuser ? cfg_rmin : active_rmin;
    wire [7:0] use_rgap=s_tuser ? cfg_rgap : active_rgap;
    wire [7:0] use_bgap=s_tuser ? cfg_bgap : active_bgap;
    wire advance=!m_tvalid || m_tready;
    assign s_tready=rst_n && advance;
    reg v1,v2,u1,u2,l1,l2;
    reg [3:0] eligible1,eligible2;
    wire [7:0] r[0:3],g[0:3],b[0:3];
    genvar n;
    generate for(n=0;n<4;n=n+1) begin:g_rgb
        assign r[n]=s_tdata[95-24*n -:8];
        assign g[n]=s_tdata[87-24*n -:8];
        assign b[n]=s_tdata[79-24*n -:8];
    end endgenerate
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            active_rmin<=100;active_rgap<=65;active_bgap<=65;
            v1<=0;v2<=0;u1<=0;u2<=0;l1<=0;l2<=0;
            eligible1<=0;eligible2<=0;
            m_tdata<=0;m_tvalid<=0;m_tuser<=0;m_tlast<=0;
        end else if(advance) begin
            if(s_tvalid && s_tuser) begin
                active_rmin<=cfg_rmin;active_rgap<=cfg_rgap;active_bgap<=cfg_bgap;
            end
            v1<=s_tvalid;u1<=s_tvalid && s_tuser;l1<=s_tvalid && s_tlast;
            v2<=v1;u2<=u1;l2<=l1;
            m_tvalid<=v2;m_tuser<=u2;m_tlast<=l2;
            for(i=0;i<4;i=i+1) begin
                // Extend operands before adding: sums may exceed 255.
                eligible1[3-i]<=r[i]>use_rmin &&
                    {1'b0,r[i]}>({1'b0,g[i]}+{1'b0,use_rgap}) &&
                    {1'b0,r[i]}>({1'b0,b[i]}+{1'b0,use_bgap});
                eligible2[3-i]<=eligible1[3-i];
                m_tdata[3-i]<=v2 && eligible2[3-i];
            end
        end
    end
endmodule
