# 减少动态效果独立补验

2026-10-05，runtime_baseline；iPhone18Pro/iOS27、浅色默认large。只修改测试/证据，无生产hook。simctl ui未提供Reduce Motion设置，因此使用真实系统Settings→Accessibility→Motion。

实际设置：初始REDUCE_MOTION Switch value0，点击真实子switch开启并读到1，截图motion-enabled。随后启动虚构v4 app，新建任务空名称标签、聚焦空名称标签、输入“减少动态效果草稿”有值标签均截图并目视可读；改main进入图标页选择Target返回，名称值不丢；进入开始日期页开启日期返回，名称与图标草稿仍保持，取消表单。testV4ReduceMotionDraft应用检查实际通过。

恢复：首次跨App activate后恢复子switch点击没有关闭，截图读到1，未误报恢复；Settings重启会回根，修复测试清理导航后独立testRestoreReduceMotion实际通过，最终REDUCE_MOTION value0与motion-restored截图证明关闭。保存的测试包含新导航清理；本轮运行证据为应用检查与最终独立恢复，两者分别日志，未声称首次cleanup通过。

实现静态依据：ListsView.swift TaskFloatingField raised=focused||!text.isEmpty，animation(reduceMotion ? nil : easeInOut)。真实开关开启下运行证明标签状态、可读性与草稿流程可用；未做视频/逐帧时长测量，不能宣称所有系统动画均无动态效果。无假环境注入。

未验大字号/深色矩阵、iPad、真实VoiceOver及其他页面动画，未重复既有业务全套。复跑独立runner仅testV4ReduceMotionDraft，必要testRestoreReduceMotion确保关闭；真实系统Settings英语标签依当前模拟器locale。截图/AX/应用日志与最终恢复日志本目录。

结论：真实Reduce Motion开启下聚焦、有值字段与子页草稿检查通过，系统设置已实际恢复；动画时间序列未测。
