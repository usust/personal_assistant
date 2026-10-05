# 平台与竞品参考

研究日期：2026-10-04。独立研究代理 platform_research 浏览官方来源；未实际操作竞品 App。以下产品行为为官方描述，适配意见为设计推断，不视作运行观察。

## Apple 平台依据

- [Design Resources](https://developer.apple.com/design/resources/)：当前列出 iOS 27 / iPadOS 27 Figma、Sketch UI Kit。
- [iOS What's New](https://developer.apple.com/ios/whats-new/) 与 [WWDC26 Design Guide](https://developer.apple.com/wwdc26/guides/design/)：平台更新与设计资料。
- [HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)：Liquid Glass 用于导航与控件层，业务内容保持清晰。
- [HIG Layout](https://developer.apple.com/design/human-interface-guidelines/layout)：按重要性组织、对齐与渐进展示。
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)：优先复用原生组件获得系统外观。

本项目最低 iOS 27.0，采用已有 NavigationStack、List、Form、Sheet、TabView、系统工具栏；内容用语义背景、系统字体、SF Symbols。不增加自定义玻璃层或提高最低版本。

## 选择的四款产品

| 产品与选择理由 | 官方资料 | 可借鉴 | 本轮不采用 |
| --- | --- | --- | --- |
| Apple Reminders：原生生活任务基准 | [组织清单](https://support.apple.com/en-gb/119953)、[编辑与组织](https://support.apple.com/en-gb/guide/iphone/iph82596cb20/26/ios/26) | 清单图标颜色、标题优先、详情承接字段、子任务层级 | 父项完成级联子项不适合现有量化模型；共享/标签/模板扩大范围 |
| Things：轻量个人任务与精致交互 | [功能](https://culturedcode.com/things/features/)、[日期](https://culturedcode.com/things/support/articles/2803579/) | 核心输入优先，日期与进度按需展开，区分开始与结束 | 不新增 Today/Someday/Areas 或独立 deadline 概念 |
| Todoist：跨端个人任务组织 | [任务](https://www.todoist.com/help/todoist/features/introduction-to-tasks-080OAXric)、[术语](https://www.todoist.com/help/todoist/get-started/todoist-glossary-cA60laWMH)、[过滤](https://www.todoist.com/help/todoist/features/introduction-to-filters-V98wIH) | 易发现创建、详情导航、筛选保留上下文 | 不引入四级优先级、查询语言、标签、团队、看板 |
| Microsoft To Do：个人工作生活与日常建议 | [任务与提醒](https://support.microsoft.com/en-us/office/use-microsoft-to-do-for-tasks-and-reminders-in-outlook-on-the-web-dadc98aa-d854-4ecf-8433-e8dd5d55df6c)、[My Day](https://support.microsoft.com/en-us/outlook/create-and-manage-task-lists-with-my-day-in-outlook) | 关注视图与清单分离，建议由用户选择，列表精简 | 不复制每日重置、邮件标记、Planner 集成 |

## 本轮取舍

保留清单 → 任务列表 → 详情的原生结构，先解决实际数据入口、保存反馈与上下文问题。竞争产品作为交互参考，不能覆盖本项目任务类型、量化进度与归档规则。AI 当前直接执行共享 Service，没有待接受任务模型；任务日期不触发通知，不增加虚构提醒开关。

## 维度补充核验（2026-10-05）

本节补齐研究维度，不修改既定 v4 方案。**官方**指下列已浏览的产品帮助或功能页；**推断**只指本项目取舍；**未知**表示资料不足。未登录、安装或实际操作任何竞品，也未测量其视觉、动画、触觉、错误恢复或可访问性。跨端资料标注适用平台，不把 Web 操作推断为 iOS 操作。

补充来源：

- R1：[Reminders 使用与详情](https://support.apple.com/en-gb/102484)；R2：[清单组织](https://support.apple.com/en-gb/119953)；R3：[iPhone 清单编辑](https://support.apple.com/en-gb/guide/iphone/iph82596cb20/26/ios/26)。R3 为官方 iOS 26 指南，仅作已描述行为参考，不能声称已观察 iOS 27 界面。
- T1：[Things 功能页](https://culturedcode.com/things/features/)；T2：[日期安排](https://culturedcode.com/things/support/articles/2803579/)；T3：[Shortcuts 状态与 Logbook](https://culturedcode.com/things/support/articles/9596775/)。T1 为官方功能介绍，包含历史设计叙述，不当作当前版本像素规范。
- D1：[Todoist 任务操作](https://www.todoist.com/help/todoist/features/introduction-to-tasks-080OAXric)；D2：[术语与视图](https://www.todoist.com/help/todoist/get-started/todoist-glossary-cA60laWMH)；D3：[过滤](https://www.todoist.com/help/todoist/features/introduction-to-filters-V98wIH)。D1 包含分别标注的平台步骤。
- M1：[Microsoft My Day 与任务清单](https://support.microsoft.com/en-us/outlook/create-and-manage-task-lists-with-my-day-in-outlook)（Outlook）；M2：[To Do 清单的屏幕阅读器操作](https://support.microsoft.com/en-us/accessibility/todo/use-a-screen-reader-to-work-with-lists-in-to-do)（含 iOS 分节）。既有“任务与提醒”旧链接本次直接打开报错，故补充结论使用 M1/M2，不以打不开页面补充证据。

表内除明确写“未知”外均为官方描述；编号对应上述链接。

| 维度 | Apple Reminders | Things | Todoist | Microsoft To Do |
| --- | --- | --- | --- | --- |
| 信息层次与组织 | 清单、分组、子任务、分区；智能清单跨清单聚合（R2/R3） | Area 下组织项目，项目内标题分组，任务内 checklist（T1） | 项目、分区、子任务；Inbox 暂存，标签跨项目组织（D2） | 用户清单与 My Day、Important、Planned、All、Completed 智能视图（M1） |
| 新建与编辑 | 新建输入标题；详情补备注、优先级、日期等；清单可改名称颜色图标（R1/R2） | 点击或拖动 Plus 新建；展开任务按需补标签、checklist、日期（T1） | iOS Dynamic Add 打开创建器；点任务进入详情，修改后 Save（D1） | iOS 在清单中 Add a task 输入文字、Return 添加；更多菜单改清单名；当前 iOS 任务详情编辑布局未知（M2） |
| 状态表达 | 完成父任务同时完成子项；有已完成及最近删除恢复能力（R1/R3） | Open、Completed、Canceled 状态与 Logbook；项目进度饼图（T1/T3） | 完成移出活动列表，可显示并恢复已完成任务；恢复子项会恢复父项（D1/D2） | 重要标记独立于完成；All 为未完成，Completed 为已完成，Planned 排除已完成（M1） |
| 日期 | 日期与时间、时间/地点提醒；日期不是唯一提醒条件（R1） | 开始日期表示计划开始工作，deadline 表示最晚完成；提醒另设时分（T2） | Date 表示安排时间，Deadline 为最晚完成；另有 duration、重复与提醒（D2） | 到期日和提醒使未完成任务进入 Planned；My Day 每日重新选择（M1） |
| 筛选与排序 | 智能清单/标签筛选；手动拖动，或按到期日、创建日、优先级、标题排序（R2/R3） | Quick Find 搜任务/项目/标签，拖动重排，Today/Upcoming 提供时间视图；任意字段排序菜单未核实（T1） | 查询式过滤；Display 中排序/分组，按名称、日期、优先级等（D2/D3） | 智能清单聚合；iOS 清单菜单可排序/移除排序，当前资料未列具体排序字段（M1/M2） |
| 导航 | 先选择清单，再查看任务与详情；更多菜单承接清单操作（R1/R2/R3） | Quick Find 搜索兼导航，Today/Upcoming、Area/项目；iPad 可折叠侧栏，不能推断 iPhone 同布局（T1） | iOS Browse 到项目/视图，任务进入 task view；顶部 Display 控制展示（D1） | iOS 从清单页打开目标清单，更多菜单管理；My Day 为聚合入口（M1/M2） |
| 反馈 | 完成勾选与最近删除恢复是已描述结果；保存失败、重试、触觉反馈未知（R1） | 进度饼图与动画为官方功能/宣传描述；保存失败、重试、触觉反馈未知（T1） | 完成声音可关闭；重复任务完成后的短暂 Undo 提示有文档；网络写入失败恢复未知（D1） | iOS 排序选择后菜单关闭、焦点回清单；写入失败、撤销、触觉反馈未知（M2） |
| 视觉规范 | 清单颜色/图标/emoji 帮助识别；产品字号、间距、玻璃参数未核实（R2） | 官方强调任务展开为清楚的纸面、细节按需出现及项目进度图；不是可直接复制的当前数值规范（T1） | D1 描述红色创建按钮和圆形完成/勾选控件；完整字体、间距、材质规范未知 | iOS 清单主题可选背景颜色/图片；具体字体、密度、材质规范未知（M2） |

### 对本项目的适配判断（推断）

- **层次与导航**：采用可理解的清单 → 任务 → 详情结构及搜索子项入口，避免套入 Area、标签、看板等新概念。沿用 v4 清单根导航、清单内任务树及跨清单归档入口，不因竞品增加导航层级。
- **输入与日期**：核心字段优先，聚合任务不展示无作用的进度输入；保留既有字段与 PATCH 语义。用明确的开始/截止及可选时分，不把 endDate 改成新的 deadline 模型，也不从日期推断已设置通知。
- **状态与反馈**：本项目量化完成与归档分别表达；不照搬父项完成或恢复级联。操作结果以真实响应为准，保存后刷新失败与写入结果不明确分别提示并避免重复提交；竞品资料未证实相同失败策略，这属于针对项目代码问题的方案。
- **筛选与排序**：筛选保留上下文、排序维持树关系，优先沿用已有范围与手动排序；不引入查询语言、每日重置或复杂智能清单。
- **视觉**：从竞品借鉴标题优先、渐进展示和身份识别；字体、语义颜色、SF Symbols、系统组件及 Liquid Glass 边界以 Apple 官方 HIG 与实际 SDK 为准。未知的动画、触觉与错误体验不写成竞品优势或验收依据。
