# 任务管理与 AI 能力

## 补充后的实施提示词

基于当前 personal-assistant 的 Go/Gin/GORM 后端、Vue 前端及 Capability 执行框架，实现可实际使用的个人任务管理。先调查成熟产品，再沿用原任务页面的契约和交互，完成任务清单、嵌套任务、优先级、起止时间、归档、量化进度、排序及删除。每个用户只能访问自己的数据，所有入口共用授权、字段校验和事务；PATCH 仅用经过白名单校验的 map 更新实际提交字段，区分省略、零值和解除父级的 null。

AI 必须从底层接入同一业务服务，通过有描述和 JSON Schema 的工具查询、创建、更新、拆分和删除任务。可信操作者来自认证上下文，模型不得指定数据归属。变更记录来源，工具错误可解释，数据库内部错误不暴露。恢复原任务页面，提供接口说明、隔离及回滚测试和模拟模型端到端验证。保留工作区原有未提交修改，不改动另一个基础框架仓库。

## 参考与取舍

- [Todoist 任务介绍](https://www.todoist.com/help/todoist/features/introduction-to-tasks-080OAXric)：参考任务、子任务、日期和优先级的组织方式，沿用本项目已有清单及三级优先级。
- [Linear 父子任务](https://linear.app/docs/parent-and-sub-issues)：参考把大任务拆成可执行下级任务的方式，支持嵌套和重新指定父级，并校验循环与清单一致性。
- [Anthropic：Building effective agents](https://www.anthropic.com/engineering/building-effective-agents?hsLang=en)：参考清晰工具描述和共享业务边界，复用现有工具循环，不额外引入 Agent 框架。

这是结合当前框架的设计取舍，不是上述产品功能的完整复刻。任务依赖、重复规则、提醒调度、独立截止日期、批量拆分原子提交及持久化对话不在本轮范围。

## 已实现

`internal/task/` 按 model、validation、service、handler、capabilities 分文件。应用组装时创建一个 Service，HTTP 与 AI 共用实例；只有 `app.Initialize` 执行迁移。任务和清单使用 `tasks_v2`、`task_lists_v2` 新表，操作记录为 `task_events`。历史任务不自动导入，也不推断旧数据归属。

登录用户，包括管理员，只能访问自己拥有的任务和清单。不存在和无权访问统一返回 404。任务变更在数据库事务内锁定操作者用户行，使同一用户的任务树写操作串行化；失败同时回滚数据和事件。该方案适合个人助手，未来高吞吐协作场景需细化锁粒度。测试数据库为 SQLite，实际 MySQL 行锁行为尚未实测。

PATCH 拒绝未知字段、空对象和不允许的 null；允许 `remark:""`、`archived:false`、`progressCompleted:"0"`，`parentId:null` 表示解除父级。`listId` 更新在同一用户锁事务内迁移当前节点和全部后代（含归档节点）。换清单同时提交 `parentId:null` 或有效新父，验证后才执行白名单 map 更新，失败整树与事件回滚。所有父级必须归属本人且与当前任务同清单，不能指向自身或后代。新增任务或实质改变父关系只能选择 main；历史 subtask 容器的未变父关系 PATCH 保持兼容，不自动迁移类型，有下级 main 禁止改为 subtask。

日期为 `YYYY-MM-DD`，时间为 `HH:mm`。时间不能脱离日期；未提供时分时按开始日 00:00、结束日 23:59 校验。日期目前是本地日历值，不执行时区转换或触发提醒。

进度接受数字或十进制字符串，最多两位小数，最大十亿。总量、步长须大于零，完成量不得超过总量。仅未归档的叶子 `subtask` 可步进；减少时最低为零，增加溢出默认 409，`allowExceedTotal:true` 表示截断至总量。前端加一步操作使用该选项，保证最后不足一步时仍能完成。父级汇总继续由现有前端完成，后端返回原始配置，归档后代仍参与前端汇总。v4 前端仅汇总实际具体叶数量，空 main 为 0/0 并显示“暂无任务”，嵌套空 main 不贡献原配置；5/10+1/1=6/11，混单位不标为某一种单位。归档/恢复暂保持单节点，不改变后代状态。

## HTTP 契约

所有路径前缀 `/api`，必须带 Bearer Token。成功返回 `{ "data": ... }`，错误返回 `{ "error": "..." }`。当前成功操作统一 200；无效参数 400，未登录 401，归属不可见 404，状态冲突 409。

| 方法 | 路径 | 请求/响应 |
| --- | --- | --- |
| GET | /task-lists | 自己的清单数组 |
| GET | /task-lists/:id | 清单 |
| POST | /task-lists | name 必填；remark、color、icon 可选；返回清单 |
| PATCH | /task-lists/:id | 实际提交的允许字段；返回清单 |
| DELETE | /task-lists/:id | 删除清单及其中全部任务 |
| GET | /tasks | 自己的全部任务，含归档，按 sortOrder、id 排序 |
| POST | /tasks | title、listId 必填，其余见下方；返回任务 |
| PATCH | /tasks/:id | 允许字段的局部更新；返回任务 |
| PATCH | /tasks/:id/progress | operation=increment/decrement，allowExceedTotal 可选；返回任务 |
| PUT | /tasks/reorder | taskIds：1–1000 个无重复且归属本人的 ID；只修改排序 |
| DELETE | /tasks/:id | 有下级时必须 query cascade=true；返回 deletedIds、affectedParent=null |
| GET | /tasks/events | 最近 100 条本人操作记录 |

任务允许字段：icon、title、remark、listId、parentId、taskType（main/subtask）、priority（high/medium/low）、startDate、startTime、endDate、endTime、archived、progressTotal、progressCompleted、progressStep、progressUnit。icon 默认为 Folder（最多64字节稳定键），未知已保存键允许保留；新增数据库列由既有启动 AutoMigrate 补充，本次未部署或迁移真实数据。iOS 可选解码兼容旧JSON缺 icon，旧客户端省略 icon 不覆盖；新版图标持久化需配套后端。目录为 `apps/iOS/PersonalAssistant/Resources/TaskIcons.json`，Web 引用同一资源，iOS 提供完整同序内置回退。默认类型 main，优先级 medium，总量 100、步长 1、完成量 0。顶级任务 parentId 为 null。时间与归档字段与现有 `TaskRecord` 兼容。

列表暂不分页或按条件过滤，以兼容前端对整棵任务树的汇总。事件只保留操作名、记录 ID、来源与时间，不保存描述正文、前后值或可撤销快照。删除响应保留旧前端需要的 affectedParent 键，但当前调用方会重新加载列表，不返回父级计算结果。

## AI 使用

已注册 12 项能力：`task_list.list/get/create/update/delete`、`task.list/create/update/delete/progress/reorder/events`。所有工具使用同一 Service；`source=ai` 由工具适配器指定。创建与更新工具的字段放入 `changes`，HTTP 直接提交字段对象。

配置可用模型后，在已有 AI 对话页可输入：

- “创建一个叫学习计划的清单。”
- “查询学习计划的任务，并把其中的阅读任务拆成三个子任务。”
- “把阅读第一章的进度增加一步。”

模型需先查真实清单和任务 ID，缺少必要信息时询问。删除仅在用户明确要求时执行，但这属于模型行为约束，当前没有后端二阶段审批协议。一次对话仍受原有 6 轮、12 次工具调用限制；多个工具调用分别提交，后续模型失败不会回滚已完成动作。不要把任务备注当作可执行指令。

## 验证

- 后端单元测试：字段类型、零值、精度、用户隔离、父子循环、排序回滚、级联删除、事件来源。
- 应用集成测试：真实 JWT、原前端 HTTP 契约、跨用户访问、进度补齐、归档恢复。
- 模拟模型集成测试：真实 `/api/ai/chat` 编码、工具目录、工具执行、结果回传和 HTTP 读取同一持久化数据。
- 未调用真实模型或连接真实 MySQL，未迁移生产数据库或部署。
