# 未知主任务图标兼容独立验收

2026-10-05，runtime_baseline；iPhone17e/iOS27.0、浅色默认large。只新增testV4UnknownIconCompatibility及证据，未改生产/mock接口。

现有v4样本legacy6.icon=unknown-preserved-key。实际UI主动将历史subtask容器改main并保存，等刷新后重新编辑图标。File Folder回退仍显示，但Picker“文件夹”isSelected=false且所有当前可点击选项的Selected总数为0。未选任何图标，返回普通修改名称并保存，再刷新重开，仍Folder未选中、当前可点击选项Selected总数0。单项TEST SUCCEEDED。

该证据利用生产TaskEditor/TaskIconPicker真实状态与响应刷新，不复制私有fields状态机；缺失icon会在populate变Folder、Known Folder会被选择，因此与“只是glyph一致”不同。证明本流程未将未知值覆写为Folder或任何已知选项。原始unknown-preserved-key逐字JSON未在UI公开，未记录请求或响应rawkey，因此不能宣称直接捕获HTTP原始键逐字一致；原键完整保留另有源码 fields/icon初始化与最小patch规则的静态依据。此边界明确保留，不加测试hook。

未验真实服务器、数据库、日期普通修改及跨端客户。HTTP为现有内存mock，实际UI验证不代替后端联调；AX Selected属性不是实际VoiceOver操作。

复跑：独立runner only-testing:LoanSwipeTests/LoanSwipeTests/testV4UnknownIconCompatibility；使用现有 --task-ui-scenario v4，不需要生产新增场景。保存两阶段截图、AX与日志本目录。

结论：已运行的主动转main和普通名称保存，不覆写为已知图标兼容检查通过；rawkey逐字网络证据未获取。
