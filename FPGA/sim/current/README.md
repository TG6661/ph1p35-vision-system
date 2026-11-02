# 当前菜单与模式排查

最新生产修改为menu_control.c和integration_service.c：修复超过50ms采样停顿重复触发按键，并在MCU启动时显式同步FPGA配置。7组Host和固件构建通过；新增24种间隔/方向/模式组合、释放抖动和新按键消抖回归。说明见MENU_MODE_DEBUG.md，最终证据见verification_summary.json的menu_mode_debug。15次runtime切换与新增final_sink最终写入回归均通过；随后板级只读已确认FD工作区仍运行final1旧ELF，STYLE请求GG225/LSC1被拒绝，旧数字ID导航还会选中隐藏行；见MENU_MODE_DEBUG.md最新结论。当前ELF尚未下载，实际正确固件复测待完成。本轮不改RTL，不需要为该按键修复重跑TD。

以下巡航/ASCII段落为各自修改时的验证记录；其中“旧bit”指各次修改当时的文件，不代表当前板上版本。

# 巡航与菜单回归

最新变更为巡航、跟踪参数及透明菜单/完整Logo，入口run_patrol.ps1 -BuildFirmware。
本轮7组Host、8组RTL/生产清单检查及固件构建通过；详细证据见verification_summary.json的patrol_integration。
菜单102组HUD向量/882行；Logo在三模式下独立核对41172个屏幕像素。巡航覆盖端点、目标获取/丢失、数据过期/损坏、重复序号、手动覆盖、命令原子校验。曝光100ms/80ms、204项NACK恢复和STYLE/ASCII控制回归继续通过。
capability为0x70ff，缺bit14拒绝启动（FAIL -16）。新ELF需要匹配本轮新bit；未运行TD或下载。板级巡航机械响应和时序待用户手动验证。

下文保留上一轮ASCII接入的验证范围；本轮未修改ISP像素处理模块。旧23组测试不表示本轮重新执行。

# 当前版本回归

本目录自包含当前工程验证，不依赖历史工程目录。所有脚本只执行Host、ModelSim及可选固件构建，不运行TD或板级工具。

- run_host.ps1：7组Host；菜单导航/102组真实HUD向量、STYLE18种FX/CL组合、启动匹配、204个相机故障恢复用例、曝光、云台、readiness。
- run_validation.ps1：Host之后执行23组ModelSim/生产清单检查，可加-BuildFirmware。
- ascii/ascii_full/ascii_post：10字形/彩色平均、1280×720双帧无帧间复位、FX5和CL/模式切换。ascii_full_before.log是修复队友RAM深度越界前的失败证据。
- gg：3686400像素、4帧，新GG224/576算术参考及非STYLE原模型。
- lsc：兼容测试名；现在验证raw_delay_4px与旧LSC OFF的有效数据/3拍标记等价。无效拍像素不属于契约。
- regs：524288种配置、30000随机周期、读出/冻结提交/generation边界。
- post_contract/runtime：原FX像素与统计、27帧post、22个runtime输出帧和15次配置切换；检查RED STRONG、MOTION/STYLE旁路及ASCII尾部排空。
- replay_neg/replay_ascii：实际2px回放+post，720p两帧，DDR延迟80拍并注入停顿。两帧均完整输出，无未知像素、行/帧标记错误。压力模型中约21.3/21.5ms处理一帧，不是整机60fps证明。
- mode_menu：102组真实C打包向量、882行文字/光标，导出三张菜单HEX/PNG。
- osd_timing：与同一菜单的未流水参考逐像素对照，覆盖Logo、右侧延迟、动态RGB、边界和原有一拍输出。
- target_timing/camera_hud/mcu_candidate/servo：目标桥、AHB/HUD CDC、等待周期、PWM和复位回归。
- actual_manifest：75个生产文件编译；TD工程102个相对文件引用另行静态检查，均存在。

当前7组Host、23组RTL/编译检查和RISC-V构建全部通过。详细日志、哈希、修改边界与未变文件见verification_summary.json的ascii_integration；较早条目仅作既有修复记录。最终Host位于runs/20261031_172347_169，RTL位于runs/validation_20261031_172032_654。

本轮警告已检查：runtime夹具未连接4个未使用的输出，产生5条端口警告；生产清单编译有80条既有加密HDMI警告。其他用例零警告。

当前capability=0x30ff，目录内旧bit不包含ASCII/GG/LSC修改。新ELF需用户手动生成且时序通过的新bit配套。菜单图见MENU.md，接入设计见ASCII_INTEGRATION.md；旧用户报告17837 Slice、setup +0.109ns、hold +0.020ns不是本轮物理签核。

*_reference.v、*_timing_reference.v、before_post_reference.v、old_*.v、ref_*.v以及RAM/FIFO模型仅用于仿真，不加入TD。*_work、WLF、HUD HEX和Host EXE是可再生缓存。曝光Host模拟10Hz也不能替代板级稳定性测量。
