# GitHub 上传与日常协作

当前仓库已完成首次发布：`TG6661/ph1p35-vision-system`，首次提交为 `7e86693`。已发布后不必重复执行第 3、4 节；后续使用分支和 Pull Request。

## 1. 准备账号与 GitHub Desktop

1. 打开 https://desktop.github.com/ 安装 GitHub Desktop。
2. 在 Desktop 选择 Sign in to GitHub.com，登录自己的账号并完成浏览器授权。
3. 如果询问 Git name / email，填写自己的提交身份。希望隐藏真实邮箱，可在 GitHub 网页 Settings → Emails 中开启 Keep my email addresses private，复制页面提供的 noreply 邮箱用于 Git 提交。

## 2. 添加已经准备好的本地仓库

本项目已经在 `E:\INTFPGA\final` 初始化本地 Git 仓库，主分支为 main，已经关联 GitHub 远程。

1. Desktop → File → Add local repository。
2. Local path 选择 `E:\INTFPGA\final`。
3. 点击 Add repository。不要使用 New repository，不要选上一级目录，也不要创建 final/final 嵌套目录。
4. Changes 中查看准备提交的文件。应包含 README、.gitignore、FDWork、FPGA、tools、docs；不应包含 TD 的 `_Runs`、固件 build 或仿真 `_work`。
5. 点击文件可看差异。不要使用 Discard all changes 或 git clean，这些命令与上传无关。

## 3. 第一次提交（新仓库参考，当前仓库已完成）

1. 左下角 Summary 填写：`Initial import of PH1P35 vision system`。
2. Description 可留空。
3. 点击 Commit to main。某些版本按钮显示 Commit N files to main，含义相同。
4. 如果 Git 提示配置姓名与邮箱，在 Desktop → File → Options → Git 中配置，再重试。Commit 只保存在本机，还没有上传。

## 4. 发布到 GitHub（当前仓库已完成）

1. 点击上方 Publish repository。
2. Name 建议 `ph1p35-vision-system`，也可保留 `final`。远程仓库名与本地文件夹名可以不同。
3. Description：`PH1P35 FPGA + RISC-V multimode vision and tracking system`。
4. 勾选 Keep this code private，确认发布到自己的个人账号。
5. 点击 Publish repository，等待上传完成。
6. Repository → View on GitHub。确认网页首页显示 README，文件树有 FDWork、FPGA、tools 和 docs。

走 Desktop 发布流程时，不需要提前在网页创建同名仓库。如果网页已经创建了同名仓库，先不要再 Publish 到相同名称；可以换一个未使用的名称，避免远程初始化内容冲突。

## 邀请队友

1. 打开仓库 `TG6661/ph1p35-vision-system`，点击上方 **Settings**。
2. 左侧 **Access → Collaborators**（界面也可能显示 Collaborators and teams）。
3. 如果 GitHub 要求验证身份，由账号本人完成。
4. 点击 **Add people**，输入队友 GitHub 用户名，选中正确账号并发送邀请。
5. 队友登录自己的账号，在通知或邮件中点击 **Accept invitation**。
6. 在 Collaborators 列表确认队友已接受。个人账号仓库的 collaborator 通常拥有写入权限；组织仓库如果提供角色选项，协作开发选择 Write。
7. 队友克隆仓库，按 README 配置环境，再建立自己的功能分支进行开发。

队友在 Desktop → File → Clone repository → 选中仓库 → 选择本地目录 → Clone。克隆后在根目录执行 `./tools/prepare-local.ps1`，设置自己的开发工具路径，再导入 TD/FD 工程。不要沿用你电脑上的旧 FD 工作区。

## 6. 每次修改后的操作

1. 开始工作前 Fetch origin；出现 Pull origin 时先拉取。多人同时改同一文件时使用各自分支更安全。
2. 修改工程，完成静态/功能验证。
3. Desktop → Changes 检查本次改动。
4. 在 Current branch → New branch 建立功能分支，填写提交说明 → Commit → Publish branch / Push origin → Create Pull Request。自动检查通过且队友审阅后合并 main。
5. 浏览器确认新提交已出现。只 Commit 没有 Push，队友看不到修改。

现有本地 bit、ELF、MAP、缓存和日志保留在原处，但由 .gitignore 排除。它们不会因为 Push 一起上传。即使你看到整个目录仍较大，也不代表上传体积相同。

## 7. 分享可运行版本

板级确认 bit 与 ELF 匹配后，在网页 Releases → Draft a new release：

1. 选择对应源码提交，创建版本标签（例如 v0.1.0）。
2. 写明 capability 0x70ff、工具版本、已验证功能与未验证事项。
3. 附上匹配的 bit、ELF、必要 MAP 及 SHA-256 校验文件。
4. 检查附件后再发布。不要把仅因名字相同的 bit/ELF 当成匹配版本。

普通 Git 不接受超过 100 MiB 的单文件。当前准备上传的文件均低于此限制，不需要为这次上传设置 Git LFS。

## 8. 克隆后的已知限制

- `.fd/project.json` 与 `.launch` 是本机生成文件，不随 Git 上传；执行准备脚本恢复。
- 准备脚本可能让 `.al` 的根路径显示为本地修改；核对差异只有 Path 后，可保留本地，不要误将别人的机器路径当作功能改动。
- 源工程本来不包含 HPF。现有 BSP 可构建；重新生成 BSP 需用户手动导出 HPF。
- ModelSim、TD 与 FD 安装包/许可证不在仓库中。RTL 功能验证需要对应工具和 TD 仿真库。
