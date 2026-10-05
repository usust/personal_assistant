# 项目调查

> 本文保留2026-10-04调查基线。2026-10-05用户v4设计已覆盖空main100%、任意类型父级与子树换清单限制；现行规则见[V4-PLAN.md](V4-PLAN.md)及仓库docs/task-management.md。

2026-10-04，独立调查代理 project_audit；以下为代码观察，不等同运行验收。

## 模块位置

- `Features/TasksView.swift`：任务列表、详情、新建/编辑、搜索筛选、排序、进度、归档、删除。
- `Features/ListsView.swift`：清单管理、外观目录、浮动标签组件。
- `Core/Models.swift`：TaskList、AssistantTask、TaskProgress、Values.progress 和最小 PATCH。
- `Core/AppStore.swift`：任务和清单整体加载、排序、会话隔离、写后刷新提示。
- `Features/TodayView.swift`：当日及逾期未完成可执行任务，复用 TaskRow/TaskDetailView。
- `Features/ChatView.swift`：AI 执行后刷新任务。
- 仓库 `backend/internal/task/`：model、service、repository、handler、capabilities。任务持久化在服务端；iOS 无离线任务写队列。

## 业务规则

本人数据隔离；不存在与无权限统一 404。任务为 main/subtask，可嵌套；父子同清单，不允许循环。有后代不直接搬清单。任务与清单修改共享 HTTP/AI Service 和事务。

进度与归档独立。未归档叶子 subtask 支持加减步；增加可截断至总量，减少最低零。父节点按子树叶节点汇总，归档后代参与；空顶级 main 为 100%。编辑可调整完成量；没有额外 completed 字段。不自动完成父子节点、不自动归档。

日期为 YYYY-MM-DD、时间 HH:mm；无开始时分按 00:00、无结束时分按 23:59；有时间必须有日期，结束不得早于开始。量化配置最多两位小数、上限十亿；总量与步长正数，步长/完成量不超过总量。标题最多 256 Unicode 字符、备注 10000、单位 20。

新建 POST；编辑 PATCH 只提交变化白名单字段，包括 false/0/空串。排序 PUT 一次最多 1000 个 ID，服务端按本人数据验证；本地保留未移动节点位置。有后代删除必须 cascade；iOS 先确认整棵树。删除清单同时删除内部全部任务。

AI 工具与手动接口共用服务，source=ai 存于事件；iOS 模型没有任务来源字段。没有建议待接受、审批队列或两阶段提交。模型删除约束不是后端审批保障。AI 部分执行失败不回滚已完成工具动作。任务日期不调度通知；现有信用还款本机通知属财务模块。

## 构建与验证

实际工程 `apps/iOS/PersonalAssistant.xcodeproj`，scheme PersonalAssistant；最低 iOS 27.0、Swift 5，无第三方依赖。显式 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，因默认 xcode-select 为 CommandLineTools。

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project apps/iOS/PersonalAssistant.xcodeproj -scheme PersonalAssistant \
  -sdk iphonesimulator -configuration Debug -derivedDataPath /private/tmp/pa-task-build \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build
apps/iOS/Tests/run.sh
```

Debug `--preview --tab tasks` 为已有内存示例，不访问真实服务器/钥匙串，拒绝所有保存。可检验布局及拒绝写入反馈，不能证明业务持久化。原有 UI runner 在 `apps/iOS/Tests/UITests`，任务需补充适当交互验证。历史 VALIDATION 不作本轮通过证据。

## 尚待验证

真实账号写入、真实网络响应丢失、跨设备同步、AI 真模型、真机、VoiceOver 操作与可访问性设置。不得将模拟器预览或源码检查称为这些能力通过。
