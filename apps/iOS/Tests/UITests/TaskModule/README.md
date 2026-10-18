# 任务模块独立验收

仅使用 Debug `--task-ui-scenario` 的虚构内存样本，不登录、不读取钥匙串、不写真实服务器。项目命名沿用独立 runner 的 LoanSwipeTests；业务应用工程无需测试依赖。

2026-10-07 全局系统键盘验收：应用 Debug Simulator arm64 构建通过，iOS 27 iPhone 17e 上六项 `testKeyboardDismissal…` 测试通过（6 个测试，0 失败）。覆盖普通与多行输入、浮动标签区域内点击、外部点击结束编辑、数字键盘与加减按钮透传、清单面板与颜色选中、系统搜索保留查询、UIKit 卡号格式、URL 与密码输入；取消和完成仍按原流程关闭面板。使用任务内存样本及 `--preview`，没有登录、保存真实数据或调用模型服务；最终结果 `/tmp/pa-keyboard-verified.xcresult`，应用构建日志 `/tmp/pa-keyboard-clean-build.log`。本轮未做真机、iPad 或 VoiceOver 专项验收。

2026-10-07 数量加减验收：`testV4ProgressSteppers` 在 iOS 27 iPhone 17e、浅色常规字号通过（1 个测试，0 失败），应用构建通过。覆盖三个字段各自增减 1、已完成量上下限、每次增加下限、目标总量联动下限及十亿上限、按钮点击不弹键盘、直接输入、保存重进与取消保留原值。截图 `progress-stepper-initial`、`progress-stepper-bounds`、`progress-stepper-saved` 位于临时截图目录及测试附件；最终结果 `/tmp/pa-progress-stepper-aligned-ui.xcresult`。本轮未执行真实服务器或辅助字号专项验收。

同日液态玻璃样式更新：三个数量字段改为原生 `.glass` 圆形按钮，使用 `GlassEffectContainer` 协调操作层，业务卡片维持普通系统背景。更新后的同一测试通过（1 个测试，0 失败），新增按住连续增减验收；可访问树确认六个按钮均为 44 × 44 点，并有独立中文名称和当前值。最终构建通过，结果 `/tmp/pa-progress-glass-final-ui.xcresult`；同名截图已更新为玻璃按钮样式。本轮外观验收仍限定浅色常规字号。

同日起止日期单行展示：共用 `TaskRow` 将开始和截止日期时间并排显示，保留图标、逾期颜色和完整朗读值；无日期时整行不占位。更新现有只读 `testLayoutSnapshot`，实际通过任务首页、工作清单筛选、今日专注三个入口（1 个测试，0 失败），构建通过；截图 `date-single-line-tree`、`date-single-line-list`、`date-single-line-today` 已目视检查，结果 `/tmp/pa-task-dates-single-row-ui.xcresult`。使用 iOS 27 iPhone 17e 浅色常规字号，窄行文字缩放已实现，本轮未另做辅助字号专项验证。

先构建并安装当前 Debug 应用，指定 Xcode：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -project apps/iOS/PersonalAssistant.xcodeproj -scheme PersonalAssistant \
  -sdk iphonesimulator -configuration Debug -derivedDataPath /tmp/pa-ios-build \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 build
xcrun simctl install <UUID> /tmp/pa-ios-build/Build/Products/Debug-iphonesimulator/PersonalAssistant.app
mkdir -p /private/tmp/task-module-after
xcodebuild -project apps/iOS/Tests/UITests/TaskModule/LoanSwipe.xcodeproj \
  -scheme LoanSwipeTests -destination 'platform=iOS Simulator,id=<UUID>' \
  -derivedDataPath /tmp/task-ui-build -resultBundlePath /tmp/task-ui.xcresult \
  -parallel-testing-enabled NO test
```

结果目录须不存在。截图作为 xcresult 附件永久保留，并写入 `/private/tmp/task-module-after`。并行多个设备会覆盖同名临时截图，须逐设备复制归档。

`testDateTimeOrdering` 已于 Iteration6 实际通过：Toggle 子 Switch 节点、Time Picker 滚轮验证同日逆序拒绝、合法保存与关闭日期清空时分。既有跳过记录保留为历史，最新证据见 Documentation/TaskModule/Iteration6。

## 真实 AppStore 读取竞态

```sh
python3 apps/iOS/Tests/UITests/TaskModule/run-race.py
```

使用仓库实际 AppStore、APIClient、Models 与财务核心依赖编译；没有复制状态机。隔离 URLProtocol 控制 GET 的完成顺序；仅 CreditReminders 替身避免通知副作用。`--preview` 使 AppStore 初始化不打开账本、不读取钥匙串；此 harness 没有调用登录、退出或 TokenVault 写接口。

覆盖写前旧 GET 不覆盖成功实体/不解锁、写期间开始读取立即 Cancellation且不发网络请求、写后完整读取才解锁。修复前实际触发进度覆盖断言，修复后通过。此处不证明真实 401、换账号、通知或财务隔离端到端行为。


## 底部日期与时间选择

`testV4DateDraft` 从当前任务首页左滑进入编辑，使用同一个系统底部滚轮选择日期、小时与分钟。覆盖历史全天日期、未设置日期默认全天、已有具体时分保留、完整日期时间确认、同日逆序禁止保存、行内清空后保存、底部无清除按钮、底部取消保留原值及整个表单取消不写入。2026-10-07 在 iOS 27 / iPhone 17e（浅色、默认字号）实际通过，1 项测试、0 失败，应用编译也通过。截图附件包括 `bottom-date-task-form`、`bottom-date-combined-wheel`、`bottom-date-reversed`、`bottom-date-new-selection`、`bottom-date-all-day-default`、`bottom-date-confirmed` 和 `bottom-date-cancel-retained`。只使用 v4 虚构内存样本，不代表真实服务器联调或财务模块端到端验证。

2026-10-07 表单留白复查：同一 iPhone 17e 默认字号截图中，名称／备注行由 84 点收紧到 56 点，已设日期行由 74 点收紧到 52 点；日期入口与清空按钮保留 44 点点击区域。浮动标签保留聚焦／有值状态，并按系统字号缩放标签预留空间；多行内容自然增高。编译及上述日期 UI 流程复查通过，未额外宣称辅助字号或减少动态效果的端到端验收。

## v4 当前验收入口

清单根导航重构后，历史UI测试保留原阶段证据，不支持直接全runner宣称v4通过。使用 only-testing 的 testV4Pages、testV4IconAndMove、testV4DateDraft、testV4SortAndProtection。启动v4虚构场景；六页面标准与紧凑dark-max、草稿及归属见 Documentation/TaskModule/V4。run-move.py编译真实Store与生产排序函数验证整树缓存及hidden-slot；只替换传输与通知，未知移动不推断。


角标专项：only-testing:LoanSwipeTests/LoanSwipeTests/testV4IconBadge，iPhone17e依次设置appearance light/dark、content_size large/accessibility-extra-extra-extra-large。实际selected trait不代替VoiceOver操作验收。


未知图标兼容：only-testing:LoanSwipeTests/LoanSwipeTests/testV4UnknownIconCompatibility。现有legacy unknown样本主动改main再普通名称保存，检查回退Folder未Selected、实际图标选项无Selected；不能仅靠显示glyph宣称rawkey保留。范围见V4-Compatibility/VALIDATION。


真实UI排序：only-testing:LoanSwipeTests/LoanSwipeTests/testV4ActualReorder，以AX Reorder手柄实际frame归一化坐标长按拖动；v4空main移root前并刷新重进确认，证据V4-Reorder。


减少动态效果：testV4ReduceMotionDraft打开真实Settings英语Accessibility/Motion，读开关1后运行任务草稿；testRestoreReduceMotion可独立确保关闭。只验证状态/可读性，不把截图当动画时间序列。
