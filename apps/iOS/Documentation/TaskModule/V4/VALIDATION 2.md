# v4 独立验收

日期2026-10-05；runtime_baseline独立执行，未改业务源码。iPhone18 Pro/iOS27浅色标准字号；iPhone17e/iOS27深色最大辅助字号。Debug --task-ui-scenario v4虚构样本，与真实后端联调区分。

## 实际检查通过

- 根清单、展开树、主详情、主编辑、图标选择、具体详情六页实际截图；push隐藏全局Tab，返回路径有效。默认展开main，历史容器也可进入。
- main6/11、54.5%；leaf5/10页、50%且进度线半宽；空main暂无任务。leaf无新增下级；legacy无新增下级/直接步进，数据可访问。
- 图标目标选择后取消保持原Layers；保存后独立刷新再重开仍Target选中。图标选择只修改草稿。
- root改清单时父置无；保存后树及实际leaf在学习清单可访问。此项HTTP内存mock支持整树移动，只验证页面与协议响应，不能当作真实数据库事务证明。
- push日期开始19:00晚于同日截止18:30，返回编辑保存禁用；关闭开始日期后合法保存；重开日期关闭，重新启用时指定时间仍关。fix2防止子页返回重装草稿得到实际验证。
- 菜单进入/完成排序模式；生产Values.taskOrderPreservingHidden真实函数验证隐藏槽位不变、重复ID拒绝。没有UI拖动发送排序的运行证据。
- refresh-error已确认写后共享lock禁编辑/新建，读取失败继续锁定，后续成功刷新恢复。读取次数根据场景剩余失败数最多两次，未自动重试写。
- 独立真实AppStore move harness：服务器确认根成功后读取503，已知本地所有后代包含归档节点list一致；unknown无成功响应不推断移动。使用实际Store/APIClient/Models，替身仅URLProtocol+CreditReminders。--preview避免真实钥匙串和账本初始化。
- 原真实Store竞态旧读拒绝、busy读无网络、新读解锁通过。
- 最终Release arm64 iphoneos不签名构建通过；Web npm run build通过，既有bundle体积warning保留。
- 紧凑深色最大字号六页与空main实际运行通过；极大字号priority/date换行、图标超固定tile，但未见文字数据丢失。标准字号连续summary无内部横线、导航清单标题居中，工具栏仅…+。

## 修复与定位证据

fix1前额外EditButton拥挤标题、图标保存重开Layers、日期子页丢草稿已发生；相关旧截图不作为最终验收。v4-ui3.log实际失败后交给独立执行者fix2，最终v4-ui4.log三项通过。大字号首次脚本未滚到屏外空main、错误样本任务亦屏外，属定位失败；有界滚动后v4-dark-final.log通过。v4-ui5恢复只点一次而仍剩两次503为测试计数错误，标准v4-sort-final.log通过。

## 未验证

真实账号/后端/AI模型发送、服务部署及真实数据库迁移均未做；后端事务与权限结果另见项目测试报告，不将mock当真实联调。未知图标普通编辑是否不覆写、本轮归档节点整树UI移动、真实VoiceOver、降低动态效果/透明度、iPad、UI实际拖动排序及日期非中文locale未运行。现有源代码回退/保留规则只作静态判断。

## 复跑

参照 Tests/UITests/TaskModule/README.md构建安装；v4当前UI测试仅选择testV4Pages、testV4IconAndMove、testV4DateDraft、testV4SortAndProtection。历史测试定位属于旧任务架构，不能全runner作为v4通过依据。真实Store执行run-move.py/run-race.py；日志本目录。所有截图是实际实现页面，设计原型另在docs/design/task-ios27-prototypes/v4。

结论：以上运行范围通过，未验证项不计为完成；当前无已证实业务阻塞。
