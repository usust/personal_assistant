# Iteration4 独立验收：云身份隔离

执行日期：2026-10-04。验收者 runtime_baseline；未修改业务源码。真实 AppStore、APIClient、模型和 FinanceLocalStore 编译执行；URLProtocol 手动控制响应。CreditReminders 仅替换通知权限与排程。`--preview` 避免真实初始化账本、联网与 TokenVault 读写；账本使用 /private/tmp 随机文件。不是后端联调或真实登录。

## 已实际通过

- 登录开始清除 AI 历史、sending、config选择和旧 warning，云代数改变；导航代数与原财务空间数据保持。认证中云入口不可用。
- token B 已返回、users/me 未完成时仍禁用云入口。
- users/me 401 返回 APIError，保留导航代数；认证状态收尾、凭证清空、财务数据不变。未将错误改成 CancellationError。
- B 成功后导航代数更新，profile B 与可用云身份建立，A 历史为空。成功登录财务身份切换沿用既有行为，并未要求保留 A 账户空间。
- A 延迟任务和配置响应在 B 登录后返回，被真实 Store 拒绝为 CancellationError。
- 正常 B 会话 401 清云状态并推进导航/云代数，保留财务空间。
- 单独临时关闭 isPreview，仅读取 canUseCloud：profile有值但token无值为 false，token有值为 true。该步骤不执行 TokenVault 方法。
- 原 task race harness 补入虚构 profile 后通过：旧读不覆盖、busy读不发请求、新读解除保护。没有通过放宽生产鉴权使测试通过。

## 未验证与范围

- 未运行真实后端、真实账号、钥匙串、登录 sheet 输入保留/错误呈现的 UI 路径；导航 UUID 保留仅证明 Store 层不重建根视图。
- ChatView 私有 send 的旧响应与 defer 未运行；仅源码检查 cloudSessionID 与 canUseCloud guard，不能宣称完整 AI 发送流程已验收。
- 本次无布局变化，没有新截图；沿用已有界面证据。
- 首次旧版快照采集已包含修复，未保留或宣称旧版运行失败证据。

## 复跑

在项目根目录执行 `python3 apps/iOS/Tests/UITests/TaskModule/run-cloud-identity.py` 与 `python3 apps/iOS/Tests/UITests/TaskModule/run-race.py`。需要 Xcode Swift 编译器/宏可运行权限；脚本设置 Xcode DEVELOPER_DIR，依赖来自现有 Tests/run.sh。退出非零表示断言或编译失败。日志见本目录。

结论：以上隔离 Store 检查通过；外部集成和 Chat UI 发送未验证。
