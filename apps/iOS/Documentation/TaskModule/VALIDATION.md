# 首轮独立验收

2026-10-04；验收 runtime_baseline，与实现 task_implementation 独立。验收者未改业务源码。Xcode 27.0（27A266a）；iOS/Simulator SDK 27.0；最低 iOS 27.0。普通可回滚修改，未部署或操作真实账号。

## 实际执行并通过

- Debug 模拟器构建成功。原核心451项通过；执行者修复后459项通过（独立读取日志，未无必要重复运行）。Release iPhoneOS arm64 无签名独立构建通过，日志 [After/release-build.log](After/release-build.log)。原 CardArtwork actor isolation warning 未属于本轮新回归。
- iPhone18 Pro / iOS27.0 / 1206×2622：真实 XCTest 进入任务列表、详情、新建、编辑、清单；主任务编辑不展示无效进度配置，新建叶任务保留量化字段。
- 主任务归档后活跃子任务作为有效根可达；恢复父任务后子任务不重复占根列表；实际主任务确认删除会级联移除并返回列表。
- 在非首“工作计划”筛选中新建，表单继承工作计划，保存后出现在该筛选；实际删除工作计划清单后任务消失，筛选恢复全部清单。
- 首次加载错误不混同空态；无清单状态提供清单入口。
- 明确400业务拒绝保留输入、保存可重试、不锁新建。错误提示在表单顶部可见；AX标签带“错误：”前缀。
- 写成功后连续两次读取失败：本地进度为3/10，详情加减禁用；返回列表新建禁用、清单新建禁用、重开详情仍禁用；完整读取成功后解锁。
- 创建落入内存但响应丢失：原表单禁止重复保存；取消后两次刷新失败仍提示结果未确认，不冒称已保存；第三次成功读取仅有一条创建样本并解锁。未自动重发POST。
- 真实 AppStore 独立竞态 harness：延迟写前旧读取不覆盖新进度、不解锁；写期间开始读取立即取消且不发GET；写后新读取成功解除保护。修复前确实失败，修复后通过。[After/race.log](After/race.log)，源码与复现位于 Tests/UITests/TaskModule。
- iPhone17e / iOS27.0 / 1170×2532与iPad Pro11(M5) / iOS27.0 / 1668×2420：列表、详情、编辑实际截图检查，标准字号无可见重叠。
- iPhone18 Pro深色及最大辅助字号：实际进入列表、详情、编辑，深色内容可辨；详情正常纵向换行。最大字号列表元信息存在排版不足，单列待办，未记录其验收完成。

本轮8个有效UI测试分批实际通过；布局测试另在三个设置/设备执行。日期测试显式跳过，不能计入通过数。早期测试定位失败记录保留：Tab与分段“任务”同名、InlineError的AX前缀、LabeledContent合并标签和屏外节点；这些不是业务失败。修正定位后对应流程通过。最终异常日志 [After/abnormal-ui.log](After/abnormal-ui.log)，清单日志 [After/lists-ui.log](After/lists-ui.log)。原xcresult在 `/private/tmp/task-module-after`；可从测试README复现。

## 截图与前后边界

[Baseline](Baseline) 为改版前 iPhone18 Pro/iOS27只读示例；[After](After) 为真实实现与Debug内存协议截图，不是静态原型，也不等同真实服务器联调。

- 标准：iphone-tasks-list/detail/new/edit、iphone-task-lists。
- 异常：iphone-write-rejected、iphone-create-response-lost、iphone-create-confirmed-on-read、iphone-saved-refresh-failed、iphone-shared-write-protection、iphone-retry-read-recovered。
- 边界：iphone-parent-archived-child-visible、iphone-deleted-selected-list、iphone-cascade-deleted。
- 尺寸：iphone17e-list/detail/edit、ipad-list/detail/edit。
- 辅助字号深色：iphone-large-dark-list/detail/edit。

## 未验证与未完成

- 同日开始/截止时分逆序、关闭日期清空时分的UI端到端验收：XCTest原生开关外层可访问节点出现定位/误点，未完成；不以静态代码检查宣称通过，测试显式跳过。
- 真实账号、验证码、服务器写入/同步、真实401及换账号后的财务空间保留、真机、VoiceOver听读、减少动态效果/透明度交互、完整拖动排序手势、长文本极限输入、慢网加载动画未逐项执行。
- 最大辅助字号 TaskRow 的元信息 HStack使优先级/日期/百分比横向压挤，日期出现多段换行。未发现数据丢失，但不够易读；保留证据并列下一独立改进，不作为已完成可访问性验收。

结论：上述已执行的业务与安全检查通过；整体不能宣称全量端到端或全可访问性通过。暂无已证实的数据安全阻塞，已知排版不足与外部未验边界继续保留。


## Iteration4 云身份隔离

真实 Store 隔离登录/401、跨代数旧任务与配置、财务保留和既有任务竞态通过。完整范围与未验项目见 [Iteration4/VALIDATION.md](Iteration4/VALIDATION.md)。真实登录表单与 Chat 私有发送未运行，不记录为全流程通过。
