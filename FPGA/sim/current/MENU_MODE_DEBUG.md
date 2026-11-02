# 2026-10-31 菜单跳行与 STYLE 排查

## 最新板级结论：FD工作区仍引用final1

2026-10-31 20:27—20:30，经用户明确授权复用现有OpenOCD连接，只读检查后均恢复MCU运行，没有下载、复位或运行TD。

- FD工作区 E:/FD_CODE 的应用和BSP `.location` 分别指向 E:/INTFPGA/final1/FDWork/ph1p35_hello 和 E:/INTFPGA/final1/FDWork/MCU_startup。活跃ph1p35_hello.launch使用相对路径build/ph1p35_hello.elf，因此解析到旧工程。
- 从板子读回的XIP代码`.text`共46968字节，与final1旧ELF全部一致；其初始化只读数据/data共2328字节也全部一致。初始化段另有4字节差异，未据此声称整ELF逐字节相同。当前final菜单顺序表在板上Flash/DLM均不存在。
- 用户切到菜单STYLE后，HUD模式=2，但硬件active config=0x00020000（RED）。请求config=0x0001c306，解码为STYLE、GG225、LSC1；status=0x2，即rejected=1、busy=0，accepted=applied=8。当前RTL要求GG224、LSC0，拒绝旧协议。
- 同一时段采集帧号增加18、后处理完成数增加8，说明抓到的时段并非后处理状态机停住。旧HUD显示期望STYLE/FX，不能证明STYLE已应用；用户感知的冻结/遮罩应在正确固件上复测。
- 旧菜单按语义ID0..10依次遍历，顺序与当前可见行不一致，并选到隐藏GMR、STYLE下的P3/LSC和TRACK。这解释跳行及短暂无高亮。

根因已经有板级证据，不再归类为未知RTL缺陷。前一轮两处固件健壮性修复保留，但它们不是此次固件错配的根因。

证据目录：runs/board_20261031_202740，含寄存器、Flash/DLM读回、ELF逐段比较、FD工作区路径和解码结论。没有使用旧变量硬编码地址解释当前结构。

已生成专用配置 FDWork/ph1p35_hello/final_current_0x70ff.launch，程序、下载镜像、符号均明确使用当前final ELF；禁用自动构建，防止同名旧工程参与；保留FPGA下载关闭。该配置仅准备、未执行，当前板上仍是旧程序。

FD中可用 File → Import → Run/Debug → Launch Configurations 导入此文件，然后在Debug Configurations中手动运行final_current_0x70ff。长期应将旧应用/BSP从工作区移除（不删除磁盘文件），重新导入final/FDWork中的应用和BSP。仅修改磁盘上的.fd/project.json不会更新FD工作区已经保存的.location。

当前待加载ELF SHA256：6792dbbc0c989365172f0e529d01c16a7c56419f1c1dfa2bdedc6152d46e2ce6。现有bit capability=0x70ff，匹配当前ELF；无需重跑TD。正确ELF加载后仍需确认菜单顺序和STYLE六种FX的实际画面。

## 以下为本次板级检查之前的离线排查记录

本轮工作目录 E:/INTFPGA/final。生产代码只修改 menu_control.c 和 integration_service.c；未修改RTL、寄存器、曝光控制算法、图像流水线或DDR地址。没有运行TD、下载、复位或OpenOCD。

## 用户确认的板上现象

已加载本目录ELF并从启动运行。MODE显示STYLE，下方有FX/CL；FX名称会变化，但背景摄像头画面冻结。上下导航每行都能到达，但存在顺序异常和短暂无高亮，再按几次又显示。用户确认下载文件为 FPGA/td_project/camera_to_dsi_display_Runs/best_result/camera_to_dsi_display.bit。

用户选择暂不连接板子，继续代码与仿真检查。board_mode_readonly.cfg只是已准备的诊断脚本，未执行；当前授权不包括连接板子。

## 两处已复现并修正的固件缺陷

1. 按键持续按住，已消抖后主循环停顿60ms。旧代码把stable重置为15，恢复采样20ms后将同一次按住当作第二次按下，光标从AUTO EXP再跳到AE。修改前断言失败：runs/20261031_195008_851/mode_menu.log。现在保留已消抖电平，仅重新开始候选电平和长按计时。
2. MCU重新启动不会重置FPGA的当前模式、正在执行的配置或最后的HUD。旧integration_init把软件默认值当成已提交配置，可能不再提交启动配置，导致readiness长期不成立、旧HUD不刷新。回归复现：HUD为STYLE，MOTION请求已接受时重启MCU，旧请求完成后无法回到软件默认RED。修改前断言失败：runs/20261031_200623_858/mode_menu.log。现在启动时将提交缓存标为未知，待旧请求排空后完整提交当前期望配置；原accepted/applied/generation及HUD、AE、TRACK就绪检查继续生效。

这两处是已证明的代码缺陷，不能据此宣称已经完整解释用户板上的所有异常，尤其第二处不能解释FX名称持续变化时的背景冻结。菜单语义ID和按屏幕顺序导航表一致，未交换物理按键或重新排列菜单。

## 当前验证

- 7组Host全部通过：runs/20261031_201014_121。包括三模式双方向24种采样停顿、释放抖动、新按键消抖、三种当前模式下MCU重启、切换途中重启、重启后STYLE/FX调节、204项NACK恢复、曝光100ms/80ms与云台就绪。
- RISC-V构建通过：同目录firmware.log。曝光夹具改为先完成真实启动配置握手，并模拟主循环在同一毫秒多次轮询，未修改生产曝光代码。
- runtime_mode_debug.log：15次配置切换、32个输出帧通过，新增像素域mode/running与非MOTION时框无效断言。该测试运行后，夹具又增加了可选最终帧写入实例；生产RTL未改变。
- final_sink.log：连接真实video_in最终帧写入RTL，5次切换、12个输出帧通过；检查MOTION→STYLE RGB→NEG→ASCII→MOTION每次均能发布新generation与正确mode。
- 两组RTL均0错误、5条已有未连接共享RGB输出的夹具警告。模型使用1280×32缩小帧和行为RAM/FIFO；最终写入模型为持续DDR就绪，不等同真实DDR PHY/仲裁背压或板级HDMI验证。

这些测试未复现持续冻结，不应标记STYLE板级问题已修复。已核对巡航整合前基线，顶层、runtime、post、video_in、video_out、menu_display.c未改变；integration_service.c在本次排查中新加了启动同步修复。

## 后续定位入口

现有diag提供0x194 accepted、0x198 applied、0x19c active config、0x1c0源帧、0x1c4采集generation、0x1c8后处理源帧、0x1cc后处理generation、0x1d0后处理完成数；两次快照可区分采集/后处理是否推进。0x48、0x60可比较请求/已应用的语义选择ID，HUD影子字0x148高半字可核对其选择ID和模式。读取这些数值需要后续板级授权，不能用旧ELF调试变量地址推断。

用户19:39生成的现有报告为setup +0.107ns、hold +0.020ns。本轮只有固件修改，不要求重跑TD；最新ELF已生成，由用户手动加载。上述板级症状仍需复测确认。
