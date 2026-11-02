# MCU 固件

应用：`ph1p35_hello`；SDK/BSP：`MCU_startup`。当前支持 RED / MOTION / STYLE、六种 FX、巡航跟踪、AUTO EXP 和 NACK 整组重试。当前 capability 为 `0x70ff`，不要使用旧 `0xff` 或队友 ELF。

首次克隆后，在仓库根目录运行 `./tools/prepare-local.ps1`，再从当前目录导入两个 FD 项目。检查调试 ELF 位于当前仓库 `FDWork/ph1p35_hello/build/ph1p35_hello.elf`。

构建：`./FDWork/build.ps1 -FdRoot E:/FD`。此命令只构建，不下载。输出 build 目录由 Git 忽略，原有本地产物未删除。

现有 BSP 源码可直接参与构建。源目录没有 HPF；如需重新生成 BSP，先手动从匹配 TD 工程导出 HPF。调试时重新选择本机 JTAG 线缆，不直接沿用其他电脑的 USB 端口。

功能、协议和验证限制以根目录 README 与 AGENTS.md 为准。
