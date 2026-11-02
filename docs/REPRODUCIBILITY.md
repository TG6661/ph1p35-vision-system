# 干净克隆复现验证

日期：2026-11-02。对象：repo-improvements 分支的生产输入与构建脚本。

## 方法

GitHub 网络连接失败，因此本次使用 `git clone --no-local --branch repo-improvements` 从本地已提交仓库创建独立副本。它仅包含 Git 跟踪内容，不携带原目录的忽略缓存、旧 ELF、FD 本机配置或实现数据库；这不等同于已完成 GitHub 网络克隆。

验证目录：`E:/INTFPGA/github_verify/repo-improvements-20261102`。

## 结果

| 检查 | 结果 |
| --- | --- |
| TD 清单输入 | 102 项引用全部存在且被 Git 跟踪 |
| 必要输入 | DDR ROM、Logo fixture、BSP 许可、Makefile、链接脚本齐全 |
| PowerShell | 6 个脚本语法解析通过 |
| prepare-local | 实际生成的应用/BSP/ELF 路径指向新克隆位置 |
| Host 回归 | 7 组全部通过，含 204 个相机恢复用例 |
| 固件构建 | 使用本机 FD 工具链从无 build 目录状态生成 ELF / BIN / MAP |
| 检查器失败路径 | 缺失 DDR ROM、提交 50 MiB 文件均按预期拒绝；恢复后通过 |

使用的命令：

```powershell
./tools/prepare-local.ps1
python tools/check-repository.py
./tools/check-powershell.ps1
./FPGA/sim/current/run_host.ps1 -Gcc D:/QT/Tools/mingw1310_64/bin/gcc.exe -BuildFirmware -FdRoot E:/FD
```

本次固件编译汇总：text=51680，data=248，bss=9604 字节。这些是 MCU ELF 段大小，不是 FPGA Slice 使用量。

验证目录生成 ELF 的 SHA-256：

```text
423b222e429266be1bc937a23b998e64afc7ea8636436ebb6ea239c0b2e054dc
```

Host 与固件日志留在验证目录 `FPGA/sim/current/runs/20261102_175301_936/`。校验值仅标识此次构建文件；不同编译路径/工具版本可能改变 ELF，不能据此推断板级兼容性。

## 边界

- 本次没有改动生产 RTL、固件算法、原工程 bit / ELF。
- 没有启动 TD、ModelSim、布局布线、bitgen、OpenOCD 或下载。
- CI 工作流已加入，GitHub 云端首轮运行尚待推送后确认。本机 GCC 通过不代表云端 GCC 已经通过。
- 本机 FD 构建证明当前 Git 跟踪输入可构建，不证明其他 FD 版本兼容，也不等于时序或板级签核。
- 当前仓库没有 HPF；已有 BSP 可构建，重新生成 BSP 仍需用户手动导出匹配 HPF。
- 未创建可运行版本标签或 Release，避免把未经上板验证的新构建当成已验证发布。
