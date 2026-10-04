# Iteration6 日期流程独立验收

2026-10-04，runtime_baseline；仅修改测试与证据。iPhone18 Pro，iOS27.0，浅色标准字号，Debug 虚构内存样本。真实后端未联调。

实际通过：编辑既有任务，开启指定开始时间，用原生 Time Picker 小时滚轮设为18:00；同日截止09:00时保存 disabled，截图与AX确认两日期2026-10-04及18:00/09:00。关闭指定开始时间后合法范围可保存，返回任务详情成功。再编辑关闭开始/截止日期并保存，重开编辑两日期开关value0；重新开启日期，两个指定时间开关仍value0，证明保存清空日期及旧时分，而不是仅隐藏控件。

定位原因与有界尝试：首轮新建表单键盘遮挡，整体swipe把开关滚到导航外；改编辑既有任务避免键盘。原生Toggle外层包含实际Switch子节点，直接点击子节点成功。第二轮“开始时间”不是按钮标签；实际AX DatePicker按钮是 Time Picker，第三轮采得09 o’clock/00 minutes滚轮。最终第四轮完整单项 TEST SUCCEEDED，无业务代码修改。滑动只为将实际元素frame置入可见范围，滚轮使用真实节点adjust值，无猜测像素坐标。

截图、AX和四次日志保存在本目录。最终测试为 Tests/UITests/TaskModule/LoanSwipeTests.swift 的 testDateTimeOrdering；不再skip。复跑命令沿用runner README，only-testing:LoanSwipeTests/LoanSwipeTests/testDateTimeOrdering。

未验：真实后端跨端持久化、其他locale时间滚轮、其他尺寸及日期picker日历选日；本次只验证同日时分及日期关闭清空，未变布局不重复矩阵。

结论：本轮请求的日期流程实际通过。
