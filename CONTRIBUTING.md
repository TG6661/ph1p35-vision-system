# 开发与验证要求

## 工程修改

- 修改前阅读 [AGENTS.md](AGENTS.md)，每次修改围绕一个功能或问题展开。
- 保持 DDR 地址、仲裁与帧所有权、三级 OSD 顺序及 CDC / 复位语义。
- 寄存器变更同步更新 RTL、`fabric_regs.h`、固件、capability 和相关测试。
- 本机 `.fd` / `.launch` 配置由 `tools/prepare-local.ps1` 生成；TD `.al` 根 Path 的本机变化与设计设置修改分开处理。

## 验证要求

- 运行 `python tools/check-repository.py`、`./tools/check-powershell.ps1` 和受影响的 Host 回归；输入检查使用 Git 跟踪清单，新增输入须先纳入跟踪。
- RTL 修改补充对应功能仿真；工具路径和回归命令见 [README](README.md#功能验证) 与 [环境与配置](docs/SETUP.md)。
- 评审材料说明触发条件、修改后的行为、验证命令与结果，以及 ABI、CDC、DDR 和 bit / ELF 的影响。
- TD 实现与板卡加载由开发者手动执行，资源、时序和板级结果分别记录。

## 自动检查

GitHub Actions 使用 Windows、Python、PowerShell 和 MinGW GCC，检查生产输入引用、必要 ROM、文件大小、脚本语法及七组 Host 回归。

RTL 功能仿真使用 ModelSim；资源与时序检查使用 TD；整机功能通过板级测试验证。
