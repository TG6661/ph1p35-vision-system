# 版本发布模板

下列内容复制到 GitHub Release，逐项填写。未验证项明确写“未验证”，不要提前宣称稳定版本。

## 源码与工具

- 版本标签：
- 源码完整 commit：
- TD 版本：
- FD / RISC-V GCC 版本：
- 器件：PH1P35MDG324-3
- ID / ABI / capability：按实际读取结果填写（当前源码预期 0xA5010006 / 0x00010001 / 0x70ff）

## 附件

- FPGA bit 文件名及 SHA-256：
- MCU ELF 文件名及 SHA-256：
- MAP（可选）：
- 来源说明：这些产物由哪个源码提交生成，是否有未提交修改。

在 PowerShell 使用 `Get-FileHash -Algorithm SHA256 <文件路径>` 计算校验值。散列只能确认文件身份，不能证明 bit 与 ELF 行为兼容。

## 验证状态

- Host / RTL 功能回归：
- TD setup / hold、资源与报告时间：
- RED / MOTION / STYLE 切换及 FX：
- 按键 / 菜单：
- 自动曝光 / AE / AG / NACK 恢复：
- 跟踪 / 巡航：
- 未验证事项和已知问题：

## 使用方法

描述手动加载顺序、如何确认 capability、如何从 MCU 启动处运行，以及如何切换到目标模式。不要引用其他版本固件的变量硬编码地址。
