# 仓库复现验证

## 已验证源码：516a995

2026-11-02，对源码提交 `516a9954aa3a1b7169c8be26cabf92aaa4fb4020` 完成干净克隆验证。

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

从已同步至上述提交的本地 main，使用 `git clone --no-local --branch main --single-branch` 创建独立副本。副本仅包含已提交文件，构建与测试从空缓存开始。

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

### 验证范围

本记录覆盖源码构建与功能仿真，未执行 TD 综合、布局布线、静态时序分析或板级测试。HPF 再生成要求和 bit / ELF 对应关系见 [环境与配置](SETUP.md)。
