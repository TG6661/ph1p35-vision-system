# 协作流程

1. 从最新 main 建立单一目的的分支，例如 `fix/menu-navigation`、`feature/style-effect`。
2. 修改前阅读 AGENTS.md；生产 RTL/固件修改单项隔离，不能混入无关功能回退。
3. 首次克隆先执行 `tools/prepare-local.ps1`，核对 FD 实际项目路径。
4. 修改后运行 `python tools/check-repository.py`、`./tools/check-powershell.ps1` 和 Host 回归。新增文件应先 `git add`，输入检查才能看到新增文件。
5. 涉及 RTL 时补充相关功能仿真。GitHub 的基础 CI 不能代替 ModelSim、TD STA 或板级验证。
6. 提交并 Push 分支，创建 Pull Request，填写模板，等自动检查完成后由队友审阅。
7. 合并前检查 bit / ELF / ABI 影响。使用 Squash and merge 或普通合并均可；不要强推覆盖队友提交。

GitHub Desktop 操作：Current branch → New branch → 修改 → Commit → Publish branch/Push origin → Create Pull Request。

## 自动检查范围

GitHub Actions 使用 Windows、Python、PowerShell 和 MinGW GCC，检查生产输入引用、必要 ROM、文件大小、脚本语法以及七组 Host 回归。允许手动运行 workflow_dispatch。

不启动 TD、FD、ModelSim、OpenOCD 或板卡；不含厂商安装包和授权文件。私有仓库的 Actions 使用量按账号配额计费，首次开启后可在 GitHub Billing / Actions 查看用量。

项目准备脚本产生的 `.fd` / `.launch` 配置由 Git 忽略；`.al` 根 Path 的本机变化不作为功能修改提交。保留其其他设计设置。

## Release

只有板级确认匹配的 bit / ELF 才标记为可运行版本。发布格式参见 [版本发布模板](docs/RELEASE_TEMPLATE.md)。自动检查不自动创建标签、不发布 Release、不合并 Pull Request。
