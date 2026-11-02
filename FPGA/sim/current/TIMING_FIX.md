> 本文保留先前时序修复的原因与验证记录。最近已观察到的用户实现为2026-10-30 19:28:39，17837 Slice、setup +0.109ns、hold +0.020ns。当前新增ASCII/GG/LSC及菜单改动尚未实现，现状以ASCII_INTEGRATION.md和verification_summary.json的ascii_integration为准。

# 当前时序修复与菜单精简

依据：FPGA/td_project/camera_to_dsi_display_Runs/phy_1/final_timing.rpt（2026-10-30 18:40:16，Routed）。该报告是修复前的用户实现结果，本轮只读取，未运行TD/bitgen/下载。

| 时钟域 | setup最差余量 | 失败端点 | 原因 |
|---|---:|---:|---|
| HDMI 75.002 MHz | -1.713 ns | 23 | S_y_2d→行选择→文字/字符选择→字模→out_rgb，20级，数据路径14.678 ns |
| AHB 150.015 MHz | -1.415 ns | 169 | u_result_cdc/sr→idle→tx_busy→提交/写入控制，最差7.852 ns，布线6.392 ns |
| DDR 66.667 MHz | +0.254 ns | 0 | 当前通过 |
| MIPI 103.520 MHz | +0.108 ns | 0 | 当前通过 |

整体setup TNS=-154.007 ns，hold最差+0.020 ns；17920 Slice、95 RAM、20 DSP。不是AE加速导致：AE改动仅在固件，违例落在上述RTL路径。

## 修改

1. camera_settings_osd.v：按用户要求左侧只保留可调项，删除说明/只读/CFG-I2C行；RED10行，MOTION/STYLE9行。将行文字、字符和字模拆成寄存级，提前两像素取字符。像素进框前完成预取，RGB/DE/HS/VS输出拍数不变。Logo、独立右侧延迟面板、三级OSD顺序不变。
2. mcu_bringup.v的mcu_target_bridge：用tx_armed寄存启动就绪，tx_busy由tx_inflight/tx_submit/tx_armed本地状态决定。tx_inflight在接受提交同拍置位，仅在原CDC已同步确认idle后清除；因此缓冲区从接受到完整确认一直不可写。复位后的启动可用时间保守延后一个AHB周期。CDC模块、payload保持、校验、ACK和寄存器ABI不变。

没有修改SDC、时钟频率、false-path/multicycle、DDR或固件，也没有回退图像处理功能。

## 验证

- 7组Host，包括曝光100ms/80ms、NACK恢复、菜单导航和云台。
- mode_menu：126组C打包向量，独立验证精简后的文字/光标/VS原子更新，生成三张真实像素截图。
- osd_timing：与同一精简菜单未流水参考逐像素比较；变化的输入RGB、字符边界、完整面板、行间隙、模式/FX、Logo、右侧延迟、握手及输出时序。
- target_timing：与冻结目标桥逐周期对照，并独立检查记录数据/帧号；75次交付、0..8目标、连续末字写入→提交、接收端背压期间非法写、错误元数据/几何/序号、传输中复位和超时失活。
- camera_hud、servo、mcu_candidate、actual_manifest：真实AHB/HUD CDC、PWM、AHB等待周期和75文件生产清单编译。

具体日志、PASS数量和SHA-256在verification_summary.json。此处描述功能验证，不能据此承诺资源下降或setup转正。

## 用户下一步

手动在TD对当前源码重新综合、布局布线并查看final_timing.rpt。重点检查HDMI/AHB两组路径，最终须全局setup/hold均通过。当前磁盘bit来自修复前失败实现，不是本轮交付bit；本轮未改ELF与capability，但仍需新bit才能应用修复。
