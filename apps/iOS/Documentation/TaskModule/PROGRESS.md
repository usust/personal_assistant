# iOS 任务模块持续改进

开始日期：2026-10-04。Goal 持续运行；阶段完成不代表整体目标完成。

## 工作约定与基线

- 初始分支 main，工作区干净；改进分支 `codex/ios-task-improvements`。
- 仅一名执行者修改项目代码；调查、评审与验收独立。普通可回滚修改直接推进。
- 遵守根目录 AGENTS.md，保留清单外观与浮动标签既定规范。
- 调查者：project_audit；官方资料与竞品研究：platform_research；运行基线：runtime_baseline。
- 已确认 Xcode 27.0 / iOS 27 SDK，最低 iOS 27.0；需显式设置 DEVELOPER_DIR。基线 Debug 构建及 451 项核心检查通过；iPhone 18 Pro / iOS 27.0 独立 XCTest 进入列表、详情、编辑、新建、清单，五张截图见 Baseline。均为只读样本，真实写入未验证。

## 已确认的问题（待方案与独立评审）

| 优先级 | 问题 | 证据 | 处理状态 |
| --- | --- | --- | --- |
| 高 | 进度/归档写成功但读取失败会误报操作失败，增量可能重复 | TasksView.progress/archive 将写入和 loadTasks 放同一 do | 待设计 |
| 高 | 父级归档后活跃子任务失去进行中列表入口 | visible 仅展示顶层；后端归档仅作用于本节点 | 待设计 |
| 中 | 创建不继承当前清单，删除清单后筛选失效 | TaskEditor.populate 默认首清单；listID 无失效校正 | 待设计 |
| 中 | 首次加载失败同时显示空任务状态 | TasksView.error 与 visible.isEmpty 独立呈现 | 待设计 |
| 中 | 主任务表单展示不可直接控制的进度与冗余说明 | TaskEditor 进度配置常驻 | 待设计 |

## 必须保留的业务边界

- 任务为 main/subtask，量化进度与 archived 独立；归档不级联，不等同完成。
- 现有子树进度包括归档后代；空 main 显示 100%，暂不改变跨端共享语义。
- 手动和 AI 使用同一后端 Service；没有建议待接受状态，不虚构接受/忽略流程。
- 日期是本地日历字段，不触发任务通知；本轮不新增提醒、同步队列或后端审批协议。
- PATCH 仅提交实际变化的白名单字段，保留零值与清除语义。
- 新建/编辑/调整进度/归档由用户主动操作；删除任务树或清单先确认；AI 删除仅限明确请求，现有模型约束不等同后端审批。

## 下一阶段

调查、研究、方案原型、独立评审已完成。采用 DESIGN.md 的方向 A，评审要求全部纳入；task_implementation 已完成首版并停止修改，Debug 构建与既有 451 项检查通过，但新逻辑尚未验收。runtime_baseline 开始独立运行验收并为唯一测试修改者；project_audit 独立只读代码评审。尚未记录本轮完成。真实写入、真机与可访问性未执行时必须明确标注。

独立代码评审首版未通过：旧 GET 可覆盖写后实体并解除保护（P1）；APIClient 会清掉 path 中 cascade query（P1，原有缺陷）；结果未确认的手动刷新再次失败误称已保存（P2）；当天截止时分未进入逾期判断（P2）。集中进入修复轮 1；验收者暂停修改项目测试后由原执行者修复，避免并行编辑。

修复轮 1 执行者报告已修四项并将提交错误移表单顶部，Debug 构建、459 项核心与其他既有测试通过。执行者停止，独立评审复查并恢复运行验收；并发旧读仍需实际证明，不将执行者报告当独立验收。

复核发现写入期间发起的读取在写结束后仍可提交；真实 AppStore 受控并发 harness 对修复轮 1 重现此问题。修复轮 2 在 loadTasks 入口拒绝写中读取；Debug 构建通过，独立静态评审确认阻塞项解决。最终运行复验仍在执行，未完成。两轮修复额度已用，不将失败项记为完成。表单失败提示已在实际截图确认可见，旧精确 AX 测试漏掉“错误：”前缀需修正。

首轮独立运行验收结束：8 项有效业务 UI 测试分批通过，真实 AppStore 竞态通过，Release 构建通过，iPhone 18 Pro/17e、iPad 标准布局已实际检查。范围与未验事项见 VALIDATION.md。标准任务流程及已执行安全检查通过；最大辅助字号元信息可读性未完成，日期开关 UI 验收跳过，真实服务端/401/真机/VoiceOver等未验，不能宣称整体全量通过。下一专项优先任务行辅助字号，设计 project_audit、独立评审 runtime_baseline 认可仅纵向元信息与环顶部对齐，不加新导航、context flags或模型变更。

首轮实现本地提交 a24f26b，证据日志提交 24f8fb2；无推送或部署。辅助字号专项 task_implementation 正在执行，仍为唯一业务代码执行者，独立验收者未修改业务代码。持续 Goal 保持 active。

辅助字号专项独立验收完成：iPhone 17e/iOS 27 标准及最大辅助字号、浅深四组布局实际通过，列表/详情子任务/今日复用已检查；日期完整、百分比独立、环顶部对齐。证据 Iteration2，原问题截图保留。VoiceOver听读与长日期极限仍未验。该明确排版问题已解决，下一轮推进今日专注加载反馈（已设计及独立评审，无关键业务取舍）。

辅助字号提交 585e75e。今日反馈专项 task_implementation 实现，project_audit 静态评审发现取消初读恢复入口缺口，修复一轮后通过；runtime_baseline 独立 4 项业务 UI + 1 项深色大字号通过，慢读2秒加载/6秒成功实际截图，证据 Iteration3。取消注入、跨会话与真实慢网未验证。下一项由审计确认AI任务上下文跨账号残留，先独立评审最小非财务状态清理，不扩大AI功能。

今日提交 2a20879。AI云会话隔离已独立评审裁决采用独立cloudSessionID与认证过渡门槛，避免早换导航标识丢登录sheet；task_implementation 为唯一执行者，实施中。其后仍有已证据空态新建入口保护不一致低成本待办。

AI隔离首版Debug构建与459核心检查通过，执行者停止后独立评审发现认证中/users/me401仍重建导航且将真实错误改成CancellationError。验收者暂停项目写入，进入专项修复轮1：认证中清凭证与云内存但保持当前尝试/导航，真实错误回到表单；正常会话401继续作废请求与导航。独立验收尚未通过，不记完成。

AI隔离修复1独立静态评审通过。独立真实Store运行覆盖登录过渡、users/me401真实错误/导航保留、B成功、旧任务/配置取消、普通401与财务保留，既有任务竞态回归通过；详见Iteration4/VALIDATION.md。真实登录sheet与Chat私有发送收尾、后端/钥匙串未运行，不记录全量AI流程验收。执行者和验收者已停止写入。下一轮仅统一任务空态新建入口共享写保护；独立设计评审认可，无新文案、模型或API变更。

AI隔离提交5363abd。空态入口专项由原执行者单独实施，验收者停止修改；范围与标准见DESIGN Iteration5。

Iteration5 Debug构建通过，独立iPhone18 Pro/iOS27 UI验证正常空清单创建入口、blocked禁用、刷新恢复及无清单管理通过；busy瞬间组合仅静态检查，见Iteration5/VALIDATION.md。最终覆盖独立审计未发现新的证据充分且值得实施的问题，停止分派并等待新证据，Goal保持active，不宣称整个持续目标完成。未验证事项：真实后端/AI/钥匙串、登录表单与Chat旧发送UI、真机网络生命周期、VoiceOver听读/减少透明度、极长文本/极深树/大量任务；这些不是已确认缺陷。后续先补有意义验证，有失败证据才立新修复轮。

Goal续轮：当前工作区核对干净，前轮有实际修改与验收证据。发现日期UI标准仍显式跳过，本轮委派独立验收者补同日时间顺序/关闭日期清空，不更改业务源码或扩Debug功能；无法稳定运行时保留证据，不虚报通过。

Iteration6独立日期UI补验完成：iPhone18 Pro/iOS27同日18:00开始/09:00截止保存禁用、合法范围保存、关闭日期保存后重开确认日期与时分清空。原测试因键盘/原生节点定位跳过，本次使用实际子Switch与Time Picker滚轮已通过，无业务修改。见Iteration6/VALIDATION.md；其他locale、日历选日、真实后端未验。当前无新已证实缺陷，保留外部验证清单，等待新证据，不空转。

用户明确指令“停止”：已停止分派并中断project_audit正在进行的竞品维度补充研究；该补充尚未交付，不记录完成。其他执行/验收代理已终止，无进行中代码修改。最新已保存提交b43e379；日期流程已独立通过，其他未验边界保留。持续Goal按用户指令暂停，等待明确恢复。

2026-10-05恢复：用户改目标为参考v4落地iOS任务UI。已查看两图/文档，v3引用缺失。调查与独立评审完成，裁决见V4-PLAN.md；新设计覆盖旧清单导航否决与空main100%。task_implementation为唯一代码执行者，runtime_baseline只读准备验收。用户参考目录未追踪，保留不修改/提交。归档级联选项已询问，未答先沿用现行单节点行为。

v4共享阶段：执行者报告backend任务测试、Swift462与分类/卡面/卡号、Web vue-tsc及25测试、Debug构建通过；project_audit独立静态评审发现Webleaf添加下级入口兼容问题，执行者已修main/归档守卫。root实际核对构建包TaskIcons.json存在，26个唯一键。UI尚未完成，执行者继续唯一写入；不把共享阶段计为视觉验收。

v4完整首版Debug/共享检查通过，执行者停止后runtime开始页面截图与独立验收，project_audit代码评审未通过：整树move确认后本地只upsert根(P1)、siblings-only排序破坏隐藏顺序、v4表单日期/priority层次未落实、rootempty创建保护遗漏、搜索/allarchive必要路径隐藏。验收者已暂停测试文件写入，进入修复轮1，原执行者集中修五项；首版截图仅BeforeFix不计最终。

v4修复1执行者完成五项并停止：AppStore.upsertTask复用纯Values helper明确成功移动原子合并后代；排序全ID保hidden；紧凑时间draft子页与独立priority；rootempty锁与必要路径。执行者Debug构建/467核心及真实Store受控GET503缓存检查通过，runtime恢复唯一测试执行做独立复跑、页面/深色大字/日期新路径，project_audit只读复核。未将自验报告当最终通过。

v4修复1独立静态通过，runtime六页及真实Store move/race、Release/Web production构建通过；actual UI发现子页返回重跑populate覆盖草稿，Target保存恢复Layers及逆序日期save未禁用(P1)。独立静态确认Form.task生命周期根因，runtime暂停项目写入，进入最后修复轮2：每editor仅首load，子页返回保draft/original；实际树截图工具栏EditButton挤inline标题，收menu排序；详情摘要内分隔隐藏保持字段分隔。两轮额度后若仍失败不记录完成。

v4最终独立验收结束，修复2草稿生命周期与视觉已实跑通过。六页、图标保存取消、逆序日期/清空、整树mock归属、共享保护与恢复、真实Store move/竞态、Release/Web build、iPhone17e深色最大字号通过。详见V4/VALIDATION.md，UI拖动排序/iPad/VoiceOver/真实后端等未验明确保留，不作全量通过。所有执行/验收代理停止修改；参考原型目录未动。当前无新已证实业务阻塞，保存本轮；未明确选择整树归档，现行单节点规则保留。

v4后续独立小轮：Goal续轮核对源码与CompactDarkMax/v4-icon-picker.png，选中角标caption随辅助字号放大为圆盘遮挡主图标。project_audit独立评审确认，只固定非文字角标12pt及frame/角落内缩，文字/点击范围/六列/数据/读屏选中状态不变；task_implementation唯一修改。主任务tile图标风险未有本轮遮挡证据，不扩范围。

图标角标小轮完成：固定非文本12pt，Debug构建通过，独立iPhone17e默认/最大字号浅深四组截图与AX及选择/search/cancel通过，触点56.3×48pt、角标12×12pt，actual VO未验，证据V4-IconBadge。root已目视最大字号Layers完整可见，执行者/验收者停止修改。

Goal续轮补未知icon兼容：独立iPhone17e/UI用现有legacy unknown样本显式改main保存刷新，普通改名称保存刷新后仍无已知选项Selected，未覆写Folder；单项通过。V4-Compatibility记录rawkey逐字HTTP未捕获，不虚报网络逐字保留；源码最小patch仅静态依据。无生产修改、无新hook/场景，验收者已停止。

Goal续轮iPad新版布局补验：独立iPad Pro11(M5)/iOS27默认浅色竖屏834×1210pt六页及空main运行通过，主体无遮断/不可达；原生顶部Tab在push隐藏，系统sidebar开关保留、编辑居中sheet、底toolbar宽屏分布。V4-iPad证据；横屏/分屏/sidebar展开/dark-max未验。无生产或测试修改，验收者停止，用户原型目录保留。
