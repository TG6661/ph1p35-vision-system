# 当前ASCII/GG/LSC整合说明

基底为E:/INTFPGA/final，算法来源为E:/INTFPGA/final_FX5_ASCII_color_20261031_1249。未覆盖队友的MCU/AHB、DDR、统计或工程约束。用户确认GG固定参数和STYLE八项菜单。

## 模块映射

| 修改位置 | 当前行为 |
|---|---|
| final1_post.v | 新增ascii_art_96与FX5选择，保持原有帧输出完成/等待SOF逻辑 |
| green_gain96.v | STYLE固定224/256，纵向576行平台、上下64行渐变；保留3拍延迟及非STYLE增益语义 |
| final1_raw_front.v / final1_runtime.v | 删除LSC控制和计算，用3拍raw_delay_4px保持前端延迟 |
| final1_regs.v / fabric_regs.h | FX允许0..5，LSC位必须0、STYLE GG必须224；capability=0x30ff |
| integration_service.c / menu_control.c / main.c | FX范围、默认配置、8项STYLE导航、命令解析及启动匹配检查 |
| camera_settings_osd.v | STYLE8行、FX显示ASCII，保留预取流水和一拍输出 |
| final1_motion_osd.v | 旧串口page style显示FX/CL，移除遗留LSC标签 |

## ASCII与局部修复

16×16单元平均RGB，以(R+2G+B)/4选取10种字形，字形8×16居中；使用队友彩色前景、亮度压缩、色度增强和1/4背景。位于Gamma0.55之后、CL之前。生产为2像素/拍、1280×720、每行1024拍回放，输出启动约晚16行；采用片上双银行带缓存，不增加完整帧DDR地址区。

队友原META_DEPTH=2*80=160，但地址使用{bank,cell}，bank1从128开始、最后到207，声明深度不足。全宽仿真在x=512、y=16首次出现未知像素。已改为2*(1<<CELL_ADDR_BITS)=256，与银行地址步幅一致；保持算法和帧时序。修复前日志ascii_full_before.log保留，修复后逐像素测试覆盖两帧、45个条带/帧和80列（不在两帧间复位）。

该渲染器适配现有固定节拍/下游ready=1契约，不声明支持任意AXI背压或任意帧几何。输入到输出增加条带延迟，模式提交仍由现有runtime等待完成、清空尾部、切换generation。

## 协议与保留项

AHB地址布局、HUD96位字段、accepted/applied/generation、CDC mailbox及帧首生效规则沿用本工程。FX编码仍为[5:4]低位和bit18高位；6/7拒绝。没有引入队友GG高度/面积寄存器。

0x184新增bit12 ASCII与bit13本工程STYLE v2；bit7保持原HUD v2含义。新固件拒绝旧0xff和队友0x1fff capability，避免同名ABI下静默混用。目录内现有bit不属于本轮改动，需手动TD实现并通过时序，再配套当前ELF。

曝光源码、相机初始化/NACK恢复、云台、线性统计、DDR仲裁/回放、顶层、目标桥时序修复及SDC均经修改前哈希核对。曝光仍100ms决策、80ms稳定、源帧+3；AE2..1991、AG16..239、VTS1000。LSC移除可能改变STYLE的实际线性亮度分布，但不改变曝光统计协议或闭环实现。

RED Gamma0.70、固定白平衡、STRONG空间滤波和TRACK保持。MOTION/STYLE的空间滤波旁路、已有CRT/PIX/HAT/NEG/CL行为保留。三级OSD仍为RED目标→MOTION→菜单/Logo。

## 验证与物理风险

当前证据统一记录在verification_summary.json的ascii_integration。覆盖Host、全宽ASCII、GG、RAW延迟、寄存器枚举、post/运行模式切换、带DDR等待的720p回放、曝光统计、HUD/菜单及生产清单编译。

参考模型仅用于仿真，不加入TD。raw_delay与原LSC OFF比较有效数据和所有标记；无效拍的像素值不属于接口契约。GG参考用定点算术比较新参数，非STYLE仍与原模型比较。菜单图来自真实RTL输出。

没有运行TD或下载。旧物理基线17837 Slice / 95 RAM / 20 DSP、setup +0.109ns、hold +0.020ns仅供后续比较。ASCII增加累加/字符色彩逻辑与RAM；删除LSC、调整GG可能抵消部分开销，但总资源和新关键路径需要用户手动TD确认。功能回放不等于CSI/DDR/HDMI整机60fps或板级曝光稳定性。
