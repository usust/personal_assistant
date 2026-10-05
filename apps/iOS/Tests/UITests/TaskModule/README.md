# 任务模块独立验收

仅使用 Debug `--task-ui-scenario` 的虚构内存样本，不登录、不读取钥匙串、不写真实服务器。项目命名沿用独立 runner 的 LoanSwipeTests；业务应用工程无需测试依赖。

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


## v4 当前验收入口

清单根导航重构后，历史UI测试保留原阶段证据，不支持直接全runner宣称v4通过。使用 only-testing 的 testV4Pages、testV4IconAndMove、testV4DateDraft、testV4SortAndProtection。启动v4虚构场景；六页面标准与紧凑dark-max、草稿及归属见 Documentation/TaskModule/V4。run-move.py编译真实Store与生产排序函数验证整树缓存及hidden-slot；只替换传输与通知，未知移动不推断。


角标专项：only-testing:LoanSwipeTests/LoanSwipeTests/testV4IconBadge，iPhone17e依次设置appearance light/dark、content_size large/accessibility-extra-extra-extra-large。实际selected trait不代替VoiceOver操作验收。
