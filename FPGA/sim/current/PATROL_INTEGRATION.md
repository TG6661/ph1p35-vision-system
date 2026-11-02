# 当前巡航、跟踪参数和菜单外观整合

基底：E:/INTFPGA/final（ASCII/GG224/无LSC版本）。来源：E:/INTFPGA/duiyou/final。只迁移云台业务、Logo内容和OSD外观；保留本工程8项STYLE菜单、ASCII缓存修复、曝光与已有硬件架构。

## 行为

TRACK菜单只有OFF/PATROL，默认OFF，无“只跟踪”档。开启后选择最大合格目标，默认红色圆形，可用原track mode any命令选择其他红色形状。有目标执行PD跟踪，无合格目标水平往返扫描，俯仰逐步回1500μs中心。

巡航默认范围900..2100μs，步进16μs/新检测结果。到端点夹紧并反向，不按主循环频率移动；没有固定20ms巡航定时器。双轴参数均为Kp35/Kd20、最大步长10μs/次、死区20/35像素。

串口命令：
- track patrol：开启巡航/跟踪。
- track patrol MIN MAX [STEP]：范围单位μs，步长1..100μs/新结果。
- track off：停止并保持当前角度。
- track on：patrol的兼容别名，不是独立只跟踪模式。
- servo/pan/tilt：仍先关闭自动功能再执行手动移动。

RED未就绪、检测数据超过500ms或数据损坏时停止移动；重复序号不产生新步进。保留队友巡航算法，修正其两个边界问题：错误快照不当作“没有目标”来巡航，非法巡航命令必须完整校验后才修改参数。巡航状态在停止、失效、跟踪切换时同步清除。

## 菜单与Logo

RED10、MOTION9、STYLE8行。只显示可调项；RED最后一行为TRACK:OFF或TRACK:PATROL。使用既有HUD bit95，无新增HUD字段，不使用队友冲突的bit30。菜单选择顺序及等待松键逻辑保持。

透明菜单底、普通文字e2e8f0、选中字体00ffcc、选中行背景视频逐通道减半。右侧延迟面板背景也透明。146×94彩色Anlogic Logo位于(32,600)，2位调色板（透明/深蓝/红/白）、858×32位同步ROM。激活已有TD文件条目，保持当前机器工程路径。

保留原先提前取字符流水，RGB/DE/HS/VS仍一拍输出，三级OSD仍为RED目标→MOTION→菜单/Logo。

## 匹配与验证

capability从0x30ff扩展到0x70ff，bit14标识PATROL菜单语义。新ELF缺bit14返回FAIL -16，其余ASCII/STYLE/HUD匹配要求保留。AHB地址、云台PWM寄存器和HUD payload布局不变，不能用队友旧ELF。

本轮验证入口run_patrol.ps1 -BuildFirmware：7组Host与8组RTL/生产清单编译。Host覆盖巡航反向、PD参数、目标获取/丢失、重复/超时/损坏数据、手动覆盖、完整命令校验、三模式导航、曝光和204项相机NACK恢复。RTL覆盖寄存器枚举、102组菜单HUD向量、Logo独立屏幕坐标/调色板逐像素检查、动态RGB下的OSD流水等价、HUD/CDC、目标桥、AHB与PWM。实际执行结果及日志哈希见verification_summary.json的patrol_integration。

既有ASCII/GG/LSC完整回归记录仍在ascii_integration；本轮未修改这些像素处理模块，不把既有日志冒充重新执行。

未运行TD/综合/布局布线/bitgen/下载。完整Logo预计增加片上RAM；实际资源、时序及巡航机械响应需用户手动实现和板测。现有旧bit不包含本轮菜单外观，须新bit配套当前ELF。
