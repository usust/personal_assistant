# 第二轮：任务行辅助字号独立验收

2026-10-04。执行 task_implementation，独立验收 runtime_baseline；验收者仅修改 XCTest 与验收文档，没有业务代码修改。

范围为 TaskRow：辅助字号元信息纵向左对齐，普通字号保持横向；28点进度环顶部对齐；日期、优先级和百分比共用同一 @ViewBuilder。未改模型、进度、接口、筛选和任务写保护。

## 实际执行

- 最新 Debug 构建日志 `/tmp/task-accessibility-build.log` 成功；安装到 iPhone17e / iOS27.0 / 1170×2532。
- 独立 XCTest `testAccessibleMetadataLayout` 在标准字号浅色、标准字号深色、最大辅助字号浅色、最大辅助字号深色四组配置均通过。每组真实进入列表、详情及今日，检查任务行AX仍含高优先级、完整年份日期与40%进度。
- 实际截图检查：标准字号元信息保留原横向层次；最大字号日期“Oct 4, 2026”完整单行，百分比独立行，消除了原日期被横挤为三段的问题。标题可按正常文字换行，任务行及页面支持纵向滚动；滚动经过系统导航栏的部分由系统玻璃遮盖，未误认作行内遮挡。
- 进度环在大字号标题顶部；详情子任务与今日专注复用同一布局，截图无元信息横向挤压或重叠。
- 源码独立核对：没有缩小字号或截断日期；普通/辅助布局复用 metadata；`git diff --check` 通过。

证据为本目录 `compact-standard-light-*`、`compact-standard-dark-*`、`compact-max-light-*`、`compact-max-dark-*`截图及四份UI日志；最大字号列表AX另保存 `compact-max-dark-list.txt`。原问题证据仍位于 ../After/iphone-large-dark-list.png，未覆盖。

结论：本专项已执行的布局与复用验收通过。未重复未变业务的459项核心、读取竞态或Release构建。此次没有验证VoiceOver实际听读、其他语言的长日期/带时分极限字符串、全部设备、真机、降低透明度或减少动态效果；不宣称全量可访问性通过。

复现：沿用 `apps/iOS/Tests/UITests/TaskModule/README.md`，仅运行 `-only-testing:LoanSwipeTests/LoanSwipeTests/testAccessibleMetadataLayout`；先使用 `simctl ui <UUID> appearance light|dark` 和 `content_size large|accessibility-extra-extra-extra-large`。检查后已恢复该专用模拟器为浅色标准字号。
