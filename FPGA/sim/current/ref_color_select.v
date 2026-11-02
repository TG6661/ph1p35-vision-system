// 冷暖选色：每拍并行处理4个RGB888像素，固定两拍延迟。
// CLD/WRM命中像素先增强约12.5%饱和度，再提亮1.125倍；未命中仍为原加权灰度。
// ALL逐位透传；主通路冷色固定CS0/T=16、蓝/绿相对红色判定；暖色沿用亮度相关门限。
// 模块内部模式：0=冷色（蓝/青），1=暖色（红/黄），3=全彩，2也按原色透传。
// 上层界面的0=ALL、1=CLD、2=WRM，由isp_top先转换成这里的模式编号。
// 第1拍判色/灰度/饱和度，第2拍亮度增益/输出，帧首锁存和两拍接口不变。

module ref_color_select_96 #(
    // 兼容旧实例的参数接口；本版RGB判据不引用这些HSV/软过渡参数。
    // SOFT_TRANSITION即使设为1也不会启用软过渡；删除未使用参数不会节省硬件。
    parameter integer COLOR0_H_CENTER_X2 = 240,
    parameter integer COLOR1_H_CENTER_X2 = 480,
    parameter integer COLOR2_H_CENTER_X2 = 720,
    parameter integer H_WIDTH_X2         = 180,
    parameter integer S_MIN_X2           = 24,
    parameter integer V_MIN_X2           = 24,
    parameter integer SOFT_TRANSITION    = 1,
    parameter integer SOFT_H_STEP_X2     = 6,
    parameter integer SOFT_S_STEP_X2     = 4,
    parameter integer SOFT_V_STEP_X2     = 4,
    parameter integer FIXED_COLD_WARM_OPT = 1,
    parameter integer ENHANCE_SELECTED = 1,
    parameter integer COLD_SENSITIVITY_ENABLE = 0, // production ISP enables the fixed strict cold rule
    // 编译期选色门限：T=clamp(Y>>3,6,14)；降低暗部漏选，最低6限制小色差噪声。
    // 亮度用增强前已计算的Y，不添加亮度下限，不计算HSV或自适应统计。
    parameter integer LUMA_DIFF_ENABLE = 1, // 0仅用于历史固定14/8位回绕回归
    parameter integer COLOR_DIFF_MIN = 6,
    parameter integer COLOR_DIFF_MAX = 14,
    parameter integer COLOR_DIFF_LUMA_SHIFT = 3
) (
    input  wire        I_clk,
    input  wire        I_rst_n,
    input  wire        I_tlast,
    input  wire        I_tuser,
    input  wire [95:0] I_tdata, // 从高到低为像素0~3，每个像素依次为R、G、B
    input  wire        I_tvalid,
    input  wire        I_tready,
    input wire [3:0] I_cold_sensitivity,
    input  wire [1:0]  I_color_sel, // 3=全彩，0=冷色，1=暖色；一帧内固定

    output reg         O_tlast,
    output reg         O_tuser,
    output reg  [95:0] O_tdata,
    output reg         O_tvalid,
    output wire        O_tready
);

    // ready仅透传；内部寄存器每拍推进，不支持通过ready暂停流水线。
    // 当前上层将I_tready固定为1；若接入可反压链路，需要同时改数据/控制推进规则。
    assign O_tready = I_tready;

    // Csat=clip(C+floor((C-Y)/8))。先显式扩展为有符号数，避免负差变成大正数。
    // 10位足以表示保守范围-32..286，之后钳位到8位；移位为常量，不推导通用乘法器。
    function [7:0] saturate_channel(input [7:0] channel,input [7:0] gray_value);
        reg signed [8:0] difference;
        reg signed [9:0] adjusted;
        begin
            difference=$signed({1'b0,channel})-$signed({1'b0,gray_value});
            adjusted=$signed({2'b0,channel})+($signed({difference[8],difference}) >>> 3);
            saturate_channel=adjusted[9]?8'd0:(adjusted[8]?8'd255:adjusted[7:0]);
        end
    endfunction
    // Cbright=clip(Csat+floor(Csat/8))。9位防溢出；超过255时饱和而非回绕。
    function [7:0] brighten_channel(input [7:0] channel);
        reg [8:0] boosted;
        begin
            boosted={1'b0,channel}+{4'd0,channel[7:3]};
            brighten_channel=boosted[8]?8'd255:boosted[7:0];
        end
    endfunction

    reg [1:0] color_active;
    reg       sof_pending;
        // 帧首可早于有效数据到来：先记住tuser，等首个有效像素组再应用新选色模式。
    // 首组直接使用I_color_sel，避免color_active的非阻塞赋值造成首组仍用旧模式。
    wire      sof = I_tvalid && (I_tuser || sof_pending);
    wire [4:0] cold_threshold=5'd16; // fixed CS0; compatibility input is ignored
    wire [1:0] current_sel = sof ? I_color_sel : color_active;

    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            color_active <= 2'd3;
            sof_pending  <= 1'b0;
        end else begin
            if (sof) begin
                color_active <= I_color_sel;
                sof_pending  <= 1'b0;
            end else if (I_tuser) begin
                sof_pending  <= 1'b1;
            end
        end
    end

    // 第1拍：复用已有灰度，完成判色和饱和度；仅增加每像素一个增强标志。
    // 数据、valid、帧首user、行末last必须保持同拍对应；空拍仍会经过寄存器。
    reg [95:0] s1_data;
    reg        s1_valid, s1_user, s1_last;
    reg [3:0] s1_enhance;

    integer p;
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            s1_valid   <= 1'b0;
            s1_user    <= 1'b0;
            s1_last    <= 1'b0;
            s1_data    <= 96'd0;
            s1_enhance <= 4'd0;
        end else begin
            s1_valid <= I_tvalid;
            s1_user  <= I_tuser;
            s1_last  <= I_tlast;

            for (p = 0; p < 4; p = p + 1) begin
                begin : calc_metric
                    reg [7:0] pr, pg, pb;
                    reg [7:0] gray, luma_scaled, color_diff;
                    reg is_warm, is_cold, keep_color;
                    pr = I_tdata[95 - 24*p -: 8];
                    pg = I_tdata[87 - 24*p -: 8];
                    pb = I_tdata[79 - 24*p -: 8];

                    // 灰度=floor(R/4)+floor(G/2)+floor(B/4)，只需移位和加法。
                    // 各通道先截断，和floor((R+2G+B)/4)并不完全相同；白色结果为253。
                    gray = {2'b00, pr[7:2]} + {1'b0, pg[7:1]} + {2'b00, pb[7:2]};

                    // T随亮度变化，复用本像素的Y；默认Y<=55时T=6，Y>=112时T=14。
                    // 编译期参数范围：0<=MIN<=MAX<=255，0<=SHIFT<=7。
                    luma_scaled=gray >> COLOR_DIFF_LUMA_SHIFT;
                    color_diff=(luma_scaled<COLOR_DIFF_MIN)?COLOR_DIFF_MIN:
                               ((luma_scaled>COLOR_DIFF_MAX)?COLOR_DIFF_MAX:luma_scaled);
                    if(LUMA_DIFF_ENABLE)begin
                        // +T先扩到9位，禁止高亮回绕；暖色第二条件保持原式。
                        is_warm=({1'b0,pr}>{1'b0,pb}+{1'b0,color_diff}) &&
                                ({1'b0,pr}+{1'b0,pg}>{pb,1'b0});
                        // 以下冷色公式仅供COLD_SENSITIVITY_ENABLE=0历史回归；主通路在后面覆盖。
                        // B+16>R的青色辅助条件不变，不另加亮度/饱和度下限。
                        is_cold=({1'b0,pb}>{1'b0,pr}+{1'b0,color_diff}) ||
                                (({1'b0,pg}>{1'b0,pr}+{1'b0,color_diff}) &&
                                 ({1'b0,pb}+9'd16>{1'b0,pr}));
                    end else begin
                        // 历史回归专用：固定14并保留原8位加法回绕。
                        is_warm=(pr>(pb+8'd14))&&({1'b0,pr}+{1'b0,pg}>{pb,1'b0});
                        is_cold=(pb>(pr+8'd14))||((pg>(pr+8'd14))&&({1'b0,pb}+9'd16>{1'b0,pr}));
                    end
                    if(COLD_SENSITIVITY_ENABLE)begin
                        // Single threshold for blue/green; strict > excludes all neutral grays.
                        is_cold=({1'b0,pb}>{1'b0,pr}+{4'd0,cold_threshold}) ||
                                ({1'b0,pg}>{1'b0,pr}+{4'd0,cold_threshold});
                    end
                    keep_color = (current_sel == 2'd0) ? is_cold :
                                 (current_sel == 2'd1) ? is_warm : 1'b1;
                    s1_enhance[p] <= ENHANCE_SELECTED && current_sel<2 && keep_color;
                    if(ENHANCE_SELECTED && current_sel<2 && keep_color)
                        s1_data[95 - 24*p -: 24] <= {saturate_channel(pr,gray),
                            saturate_channel(pg,gray),saturate_channel(pb,gray)};
                    else s1_data[95 - 24*p -: 24] <= keep_color ? {pr,pg,pb} : {gray,gray,gray};
                end
            end
        end
    end

    // 第2拍：只为上拍命中像素做1.125倍增益，ALL和未命中灰度不增强。
    // ALL也经过这两拍，保证切换模式时的延迟和帧标记一致。
    always @(posedge I_clk or negedge I_rst_n) begin
        if (!I_rst_n) begin
            O_tvalid <= 1'b0;
            O_tuser  <= 1'b0;
            O_tlast  <= 1'b0;
            O_tdata  <= 96'd0;
        end else begin
            O_tvalid <= s1_valid;
            O_tuser  <= s1_user;
            O_tlast  <= s1_last;

            for(integer q=0;q<4;q=q+1) begin
                if(s1_enhance[q])
                    O_tdata[95-24*q-:24] <= {brighten_channel(s1_data[95-24*q-:8]),
                        brighten_channel(s1_data[87-24*q-:8]),brighten_channel(s1_data[79-24*q-:8])};
                else O_tdata[95-24*q-:24] <= s1_data[95-24*q-:24];
            end
        end
    end

endmodule
