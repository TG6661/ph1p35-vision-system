# final 当前工程开发规则

## GitHub 仓库整理补充（2026-11-02）

- 当前仓库已完成首次提交 `7e86693` 并设置 GitHub 远程；日常分支协作步骤见 `docs/GITHUB_GUIDE.md`。
- bit、ELF、MAP、TD 实现结果和仿真缓存保留本地，由 `.gitignore` 排除，不代表删除。
- 下文历史哈希清单和日志留作本机证据，不随仓库上传；本次整理验证以 `docs/REPOSITORY_PREPARATION.md` 为准。
- 工具脚本支持 Gcc/FdRoot/Vsim/TdSimDir 参数；默认工具位置可能需要本机配置。
- 克隆后先运行 `tools/prepare-local.ps1` 生成本机 FD 配置；它不执行 TD 或下载。源工程没有 HPF，BSP 再生成需要用户自行导出。
- 本次未修改 RTL、固件算法或已实现 bit/ELF。不要为上传方便删除生产 IP/ROM 或改变 ABI。

本目录以当前工程、当前实现产物和可独立运行的验证环境为开发入口，见 README.md。本目录不包含历史工程和交接目录。

## 操作边界

- 未经用户明确授权，不运行 TD/Read Design、综合、布局布线、bitgen、下载或 OpenOCD，不启动或停止用户的 TD 进程。
- RTL/固件修改单项隔离，先静态/功能验证，再由用户手动在 TD 实现。
- 不改变当前 DDR 地址/仲裁/帧所有权及三级 OSD 顺序：RED目标 → MOTION → 菜单/Logo。
- 寄存器变更必须同步 fabric_regs.h、固件业务、capability 和验证。不能混用队友 ABI1.14 控制器/ELF。
- 保持现有 CDC mailbox、复位释放、帧首锁存、配置 accepted/applied/generation 语义。
- 不在工程根目录新增临时实验脚本。当前验证统一放 FPGA/sim/current，参考模型仅用于仿真，不加入 TD。
- 清理不可按扩展名盲删生产 IP、ROM 初始化文件、约束或 ELF/MAP；保留当前工程和实现结果。

## 当前功能与协议

器件 PH1P35MDG324-3，SC520CS 两通道 CSI RAW10，前端4像素/拍，DDR后处理2像素/拍，HDMI输出。

- RED/MOTION/STYLE三种互斥模式；RED Gamma固定0.70，RED固定STRONG空间滤波，MOTION/STYLE空间滤波旁路。
- STYLE：LSC已删除，前端保留3拍直通；AWB → 固定中心GG224/256（0.875，纵向576行平台、上下各64行渐变，外围1倍）→ Gamma0.55 → FX → CL。
- FX：0 RGB、1 CRT、2 PIX、3 HAT、4 NEG、5 ASCII（彩色字符画，16×16单元，80×45字符）。CRT无彩色高斯，填色/描边已对齐；NEG逐通道255-C，Gamma之后CL之前。
- CL：ALL/CLD/WRM，使用当前RGB判色与选中色增强；不能回退到旧算法。
- 语义ID仍保留11项；按模式导航：RED10项，MOTION9项、STYLE8项，GMR不显示且TRACK仅RED可选；左侧菜单只保留可调行，不显示说明标题/只读算法/CFG/I2C。TRACK仅OFF/PATROL两档（默认OFF），HUD bit95=1显示PATROL，无只跟踪档；有目标跟踪，无合格目标按新检测结果巡航。水平900..2100us、步进16us/新检测；双轴kp35/kd20、最大10us/次、死区20/35px。双轴PWM保留；AUTO EXP默认OFF，目标线性亮度80、约±5死区。
- AUTO EXP最小决策间隔100ms、成功参数组确认后稳定80ms，仍需源帧号超过确认时+3。理论最多10次/秒，板级稳定性待测。保留线性统计样本数/source/generation及快照协议；历史NACK不永久锁死曝光，8项参数整组ACK确认、5ms退避、最多额外重试2次。
- 手动/自动AE=2..1991、AG=16..239；实际MCU初始化表 sc520_regs.h 的VTS=1000。采集/整机实际帧率仍以板级测量为准。
- ID=0xA5010006，0x180扩展ABI=0x00010001，当前RTL 0x184 capability=0x70ff；bit4曝光、bit5当前STYLE、bit6 NEG、bit7原有HUD v2、bit12 ASCII、bit13本工程STYLE v2（GG224/576、无LSC）、bit14巡航菜单外观。新固件缺bit7/12/13/14分别返回FAIL -9/-14/-15/-16；队友0x1fff不能混用。已观察到用户2026-10-31 19:39生成的新bit；板上实际版本仍需确认。最新按键修复仅固件，不要求为此重跑TD。
- 0x188/0x19c：FX低两位[5:4]，高位bit18；允许STYLE FX0..5；FX6/7、非STYLE高位、bit31:19非零拒绝。原LSC位[3:2]必须0，STYLE GG必须224；寄存器地址不变，不引入队友GG高度/面积寄存器。
- DDR FINAL银行0/7000000/14000000/21000000；线性银行3500000/10500000/17500000/24500000，地址单位16位字。

## 当前入口

- TD：FPGA/td_project/camera_to_dsi_display.al；保留当前area_prior/high、map_strategy1/pr_strategy1及SDC/引脚。
- 固件：FDWork/ph1p35_hello；构建 `./FDWork/build.ps1 -FdRoot E:/FD`，输出build/ph1p35_hello.elf。
- 验证：`./FPGA/sim/current/run_validation.ps1`；仅Host可运行 `./FPGA/sim/current/run_host.ps1`。验证入口不会运行TD或下载。
- 菜单外观：透明底，选中行视频亮度减半、青绿色文字；146x94彩色Logo位于(32,600)，同步ROM，保留OSD一拍输出及原先取字符流水。
- 当前源码/固件/实现文件哈希：FPGA/sim/current/project_manifest.json。修改后应按实际验证结果更新，不把旧日志冒充新源码签核。
- 最近已观察到的用户实现报告为2026-10-31 19:39:01：setup +0.107ns、hold +0.020ns；报告只读检查不代表板上版本已确认。保留菜单提前取字符/分级寄存与目标桥tx_armed修复。不要把功能仿真当成物理签核，子链路回放不代表整机60fps。
- 按键采样停顿超过50ms保留已消抖电平，重启候选/长按计时，防止同一次按住重复触发。MCU启动强制完整提交期望配置，不假定FPGA已复位。2026-10-31后续用户明确授权板级检查，已复用现有OpenOCD只读并恢复运行。确认FD工作区E:/FD_CODE应用/BSP仍引用final1，板上46968字节.text与final1旧ELF相同；旧GG225/LSC1的STYLE请求被当前RTL拒绝，旧数字ID菜单会选择隐藏行。专用final_current_0x70ff.launch已准备但未执行；正确ELF下载与上板复测仍待用户操作或另行明确授权。详见FPGA/sim/current/MENU_MODE_DEBUG.md。
