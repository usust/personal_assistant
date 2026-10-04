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
