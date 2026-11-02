# 开发环境与工程配置

## 工具

| 工具 | 当前记录 / 验证环境 | 用途 |
| --- | --- | --- |
| Windows + PowerShell | 当前开发平台 | 工程脚本 |
| Python | Python 3，标准库 | 仓库输入检查 |
| TD | 工程记录 6.2.168116 | FPGA 实现及仿真模型 |
| FD | 项目记录 2026 年发行版；RISC-V GCC 13.1.1 | MCU 固件构建与调试 |
| MinGW GCC | 本机 13.1.0 | Host 功能测试 |
| ModelSim | 本机 Intel FPGA Starter Edition 18.1 安装目录 | RTL 功能回归 |

脚本参数支持 `-FdRoot`、`-Gcc`、`-Vsim`、`-TdSimDir`；也可设置环境变量 `FD_ROOT`、`HOST_GCC`、`MODELSIM_VSIM`、`TD_SIM_DIR`。仅构建固件时无需 MinGW 或 ModelSim。

## 首次配置

1. 克隆后执行 `./tools/prepare-local.ps1`。
2. 脚本生成本机应用/BSP `.fd/project.json` 和调试 `.launch`，并更新 TD 工程根路径。
3. FD 使用新工作区，导入本次克隆中的两个项目，确认实际路径。
4. 通过 `./FDWork/build.ps1 -FdRoot <FD安装目录>` 构建，输出位于应用的 `build/`。

`.fd/project.json` 与 `.launch` 由 Git 忽略；TD `.al` 的根 Path 可能显示为本机修改，提交时与设计设置修改分开处理。

现有 BSP 源码可直接构建。仓库未包含 HPF；只有重新生成 BSP 时，才需从匹配的 TD 工程手动导出 HPF。

## 固件与硬件版本

| 项目 | 当前源码值 |
| --- | --- |
| ID | `0xA5010006` |
| 扩展 ABI | `0x00010001` |
| capability | `0x70ff` |
| bit4 / bit12 / bit13 / bit14 | 自动曝光 / ASCII / 本工程 STYLE v2 / 巡航菜单外观 |

板卡加载前检查 bit 与 ELF 对应的源码版本和 capability，使用当前克隆生成的 ELF。旧工程与队友 ABI1.14 的寄存器布局不同，不能混用。调试变量通过当前 ELF 符号定位。

## 曝光与帧时序

- MCU 初始化 SC520CS，VTS=1000。
- 亮度统计来自白平衡/Gamma 之前的线性 RGB。
- 曝光决策间隔至少 100 ms；参数确认后等待 80 ms 稳定期，并检查新的源帧。
- 偏暗先增加 AE 再增加 AG；偏亮先降低 AG 再降低 AE。
- 相机八项参数全部 ACK 后确认 applied；失败后退避约 5 ms，最多额外重试两次。

## 验证范围

GitHub Actions 检查文件引用、脚本语法和 Host 业务逻辑；ModelSim 验证 RTL 功能。TD 资源/时序报告与板级画面检查分别完成。当前记录见 [REPRODUCIBILITY.md](REPRODUCIBILITY.md)。

源码仓库包含完整开发输入；bit、ELF、MAP、实现缓存和日志由 `.gitignore` 排除。
