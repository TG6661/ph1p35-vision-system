# 仓库复现验证

## 当前主分支：516a995

2026-11-02，对合并 PR #1 后的 `516a9954aa3a1b7169c8be26cabf92aaa4fb4020` 完成干净克隆验证。

**结果：文件依赖检查、七组 Host 回归、24 项 RTL/集成检查及 RISC-V 固件构建全部通过。**

| 验证项 | 结果 |
| --- | --- |
| TD 工程输入 | 102 项引用齐全且由 Git 跟踪 |
| 必要数据 | DDR ROM、Logo fixture、Makefile、BSP 与链接脚本齐全 |
| PowerShell | 6 个脚本语法解析通过 |
| 工程迁移 | 应用/BSP/调试 ELF 配置均指向克隆目录 |
| Host 业务回归 | 7 组通过，包含 204 个相机故障恢复用例 |
| 图像算法与链路 | LSC旁路、GG、ASCII、CRT、CL、NEG、寄存器、DDR后处理契约、模式切换、最终帧提交、NEG/ASCII回放通过 |
| 统计与交互 | 亮度统计、模式菜单、OSD、目标接口、相机HUD、MCU候选接口、舵机及生产清单编译通过 |
| 固件 | 从空 build 目录生成 ELF / BIN / MAP |

### 验证方式

使用 `git clone --no-local --branch main --single-branch` 创建独立副本，只包含提交中的文件。GitHub 命令行当前缺少私有仓库凭据，因此克隆源使用已经同步的本地 main；该副本不携带原工程旧缓存、旧 ELF 或本机 FD 配置。

验证目录：`E:/INTFPGA/github_verify/main-516a995-20261102`。

```powershell
./tools/prepare-local.ps1
python tools/check-repository.py
./tools/check-powershell.ps1
./FPGA/sim/current/run_validation.ps1 `
  -Gcc D:/QT/Tools/mingw1310_64/bin/gcc.exe `
  -Vsim D:/intelFPGA_lite/18.1/modelsim_ase/win32aloem/vsim.exe `
  -TdSimDir E:/TD/sim_release/ph1p `
  -BuildFirmware -FdRoot E:/FD
```

使用本机 MinGW GCC 13.1.0、FD RISC-V GCC 13.1.1、ModelSim Intel FPGA Starter Edition 18.1 安装中的仿真器及 TD ph1p 仿真库。

### 结果文件

- Host / 固件日志：验证目录 `FPGA/sim/current/runs/20261102_182051_419/`。
- RTL 日志：验证目录 `FPGA/sim/current/runs/validation_20261102_182051_411/`。
- [机器可读验证摘要](verification-20261102.json)记录提交号、各项结果、日志 SHA-256 及仿真器错误/警告计数。
- ELF 段大小：text=51676、data=248、bss=9604 字节。
- ELF SHA-256：`7ca94937dfe562d7cd631c5b517f04a6fa7aa55e26f7329d4d9294e7a21423a4`。

生成的固件留在验证目录，原工程的生产输入和已有 bit / ELF 保持不变。

### 云端与板级状态

用户提供的 PR #1 页面显示两项 GitHub 检查通过，该 PR 已合并到 main。此次本机验证补充了完整 RTL 回归和厂商固件构建。

本轮验证范围为源码构建与功能仿真；未运行 TD 实现或板级测试，未创建 Release。HPF 再生成要求和 bit/ELF 对应关系见 [环境与配置](SETUP.md)。

## 前次分支验证

2026-11-02，repo-improvements 的干净副本已通过输入检查、七组 Host 与固件构建。缺失 DDR ROM 和 50 MiB 误提交文件的检查器测试也通过。此次 main 完整验证覆盖了上述构建与回归入口，并增加了 24 项 RTL/集成检查。
