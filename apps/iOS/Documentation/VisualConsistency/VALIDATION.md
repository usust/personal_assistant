# iOS 统一视觉改造验收

日期：2026-10-08。仅修改 iOS；保留开始前的未提交修改。应用 Core 与本轮首次源码基线逐文件比较一致，未修改 Web、后端、数据模型或接口。没有安装依赖、升级 SDK、提交、推送或部署。

## 设计实现

| 项目 | 实现 |
| --- | --- |
| 导航与保存 | 普通页面 inline 标题；保存采用原生玻璃与工具栏高优先级；共享 TabRootNavigation 消除 More 外层重复导航，保留一级 More 返回与二级系统返回 |
| 内容卡片 | ContentCard / cardSurface 统一系统实色背景、24 点连续圆角与 20 点标准内边距；保留银行卡等特殊展示 |
| 金额字型 | AmountText 按主金额／普通／辅助三层使用系统动态圆角字体和等宽数字；财务分页根据内容自然高度调整 |
| 交易颜色 | 支出、收入、转账集中使用系统动态红／青绿／橙，保持跨今日、财务首页、流水和记账入口一致；不改用户分类颜色 |
| 任务图标 | SymbolTile 共用字重和容器比例，普通入口与紧凑行保留尺寸变体；清单图标选择统一字重与圆角 |
| 浮动输入 | 任务与模型配置共用 FloatingFieldContainer，聚焦／有值抬升，动态字号预留标签空间，减少动态效果时取消动画 |
| 金额键盘 | AmountKeyStyle 共用实色底、圆角和按下反馈；记账、优惠按键高度随字号增长；优惠黄色完成键仍跨两行 |
| 健康指标 | MetricRow 分开名称、数值、单位；保留五项指标、缺失占位、日期和时区，窄屏可以纵向排列 |
| 聊天材质 | 装饰图标使用普通实色容器，消息／输入复用内容尺度；操作保留原生玻璃，减少透明度时用户消息与图标采用系统实底 |
| 模型服务 | 名称主文字色，提供方／模型次文字色；服务列表普通系统背景，长条新增入口使用原生玻璃 |

设置首页及模型服务列表继续无顶部标题；模型服务页保留“模型服务”“模型配置”内容分组。清单无预览卡，颜色仍为 17 个色块加最后一格系统颜色盘、六列三行。记账分类仍复用原有圆形分类网格与下级面板。日期、任务进度、输入焦点、保存校验与所有业务回调保留原行为。

## 修改文件

应用文件共 17 个，均位于 `PersonalAssistant/`：

- `ContentView.swift`
- `Design/AppVisualStyle.swift`（新增）
- `Design/TabRootNavigation.swift`（新增）
- `Design/Components.swift`
- `Design/LoanCard.swift`
- `Design/AmountKeyboard.swift`
- `Design/PreviewData.swift`
- `Features/TodayView.swift`
- `Features/TasksView.swift`
- `Features/ListsView.swift`
- `Features/FinanceView.swift`
- `Features/FinanceDashboardHeader.swift`
- `Features/TransactionsView.swift`
- `Features/DiscountEntryPanel.swift`
- `Features/HealthView.swift`
- `Features/ChatView.swift`
- `Features/SettingsView.swift`

另在 `Tests/UITests/TaskModule/LoanSwipeTests.swift` 增加一项 More 导航集成回归，原有测试保留。Debug 预览补充虚构健康样本和 AI 配置必填字段；所有请求继续由内存 URLProtocol 接管，写入仍拒绝，Release 不包含预览协议。

## 构建与测试证据

环境：Xcode 27.0（27A266a），iOS 27.0 SDK，工程最低 iOS 27.0；仅通过本次命令的 `DEVELOPER_DIR` 选择 Xcode，没有改全局 Command Line Tools 配置。使用目标 SDK 已公开的 `.glass`、`.glassProminent` 和 `visibilityPriority`。

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| 最终 Debug Simulator arm64 构建 | 通过 | `/tmp/pa-ios-visual-debug.log` |
| 最终 Release Simulator arm64 构建 | 通过 | `/tmp/pa-ios-visual-release.log` |
| 原有核心测试 | 467 项通过；分类目录、卡面、卡号格式套件也通过 | `/tmp/pa-ios-visual-core-tests.log` |
| 最终 UI 集中回归 | 5 项、0 失败；iOS 27 / iPhone 17e | `/tmp/pa-ios-visual-final-ui.xcresult`、`/tmp/pa-ios-visual-final-ui-tests.log` |
| 差异空白检查 | `git diff --check` 通过 | 本地工作区 |

最终五项 UI 测试：`testKeyboardDismissalOutsideAndFieldSwitching`、`testKeyboardDismissalNumberPadAndButton`、`testKeyboardDismissalSecureAndURLFields`、`testLayoutSnapshot`、`testVisualMoreNavigation`。覆盖普通／多行字段、标签区焦点、数字键盘、加减按钮、密码／URL 输入、任务日期布局，以及助手 → More → 设置 → 模型服务 → 设置 → More 的实际返回路径和单层导航。

最初沙箱阻止 Swift 宏插件及模拟器服务，改用经过批准的有界沙箱外命令完成验证。More 回归曾发现二级返回后一级按钮未恢复，修正后上述最终五项均通过。未出现无期限等待；所有构建与测试有总超时，UI 测试另设置单项超时。曾有既有 `CardArtwork.swift` 的 actor 隔离警告，本轮没有修改该文件。

## 完成截图与边界

截图只来自 `--preview` 虚构样本。设备为 iPhone 17e，浅／深色常规字号，另覆盖深色最大辅助字号的今日、财务、助手页面；截图前等待完整系统转场。临时外观及字号恢复为原先的 light / large。

- [今日](today-light.png)
- [财务浅色](finance-light.png)
- [财务深色最大辅助字号](finance-dark-accessibility.png)
- [助手与单层导航](chat-light.png)
- [记账键盘](transaction-light.png)

本轮没有执行真机、iPad、横屏、VoiceOver 操作或真实服务器联调。减少动态效果与减少透明度的处理已接入代码和系统原生样式，未对两项系统开关开展专项运行验证；截图不能证明动画时间行为。健康指标区、优惠面板及聊天非空消息没有完整的独立交互验收。

参考：[Apple Liquid Glass 采用指南](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)、[WWDC26 SwiftUI 更新](https://developer.apple.com/videos/play/wwdc2026/269/)。
