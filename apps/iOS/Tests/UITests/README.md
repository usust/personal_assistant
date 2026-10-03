# 贷款侧滑 UI 回归

独立 XCTest UI runner，不修改主应用工程。先把当前 Debug 版应用安装到 iOS 27 的 iPhone 模拟器，然后运行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project apps/iOS/PersonalAssistant/Tests/UITests/LoanSwipe.xcodeproj \
  -scheme LoanSwipeTests \
  -destination 'platform=iOS Simulator,id=<模拟器 UUID>' \
  -derivedDataPath /tmp/pa-loan-swipe-ui-build \
  -resultBundlePath /tmp/pa-loan-swipe-ui.xcresult \
  -parallel-testing-enabled NO test
```

结果目录必须尚不存在。测试启动 `--preview --tab finance --loan-ui --loan-plan`，只使用本地样本，不登录或保存真实账户。覆盖已还／待还侧滑双按钮、筛选后生效期一致、调息及账单校准字段、三期预览和取消返回。样本试算匹配第 1 期年利率 3%、第 48 期按 5.5% 年利率校准银行账单应还为 1000（第 49、50 期仍为 851.68）；`LoanAdjustmentUIPreview.json` 另含第 359 期 3% 的尾期样本，所有数据由后端计算器导出，不使用客户端财务计算替身。截图同时用于检查期次与日期、本金／利息／年利率的单行排版。

## 游客与一键同步入口

新增 `LoanSwipeTests/testGuestFinanceAndSyncEntry`。只在安装了当前应用的专用空白模拟器运行，验证无登录进入财务、设置同步入口打开认证，以及取消后返回；不创建远程账号或上传数据。运行时追加：

```sh
-only-testing:LoanSwipeTests/LoanSwipeTests/testGuestFinanceAndSyncEntry
```

离线持久化、金额投影、账号隔离和响应丢失重试由 `Tests/FinanceOfflineTests.swift` 覆盖，随 `Tests/run.sh` 执行。

## 截图记账设置

`LoanSwipeTests/testScreenshotBookkeepingSetup` 在隔离空白模拟器验证“财务 → 右上角菜单 → 图片记账”、未同意时不能启用、背面轻点独立教程。测试不登录、不上传截图、不创建流水；真实快捷指令与背面轻点需真机验收。

相册入口回归同时检查“从相册选择图片”存在，未登录及未同意外发时不可用。真实照片选择、iCloud 下载及视觉模型识别需真机验证。
