# 选中角标辅助字号独立验收

2026-10-05，runtime_baseline，只改UI测试和证据。iPhone17e/iOS27.0，Debug v4内存场景；默认large及最大accessibility-extra-extra-extra-large，两者浅/深四组均testV4IconBadge通过。

目视四组Layers选中截图，固定角标在右上角，与主glyph分开，不再遮盖主图标；六列排列完整。AX在最大字号显示选项Button56.3×48pt、角标Image12×12pt，满足保留原按钮触点而不是把角标变成操作目标。主图标、key、布局未变。

实际交互各组均检查Layers.isSelected为true，点Target后Target为true/Layers为false；搜索“发布”可找到并选择，isSelected为true；退出系统搜索、完成选择，再取消任务表单，重开仍Layers。首跑未退出搜索就点完成失败，因为系统搜索焦点隐藏导航；按实际AX close退出后运行通过，非产品失败。失败日志未作为final，最终日志为四组本目录log。

选中trait确认使用XCTest实际XCUIElement.isSelected与AX Selected输出；不是运行VoiceOver朗读或焦点操作。真实VoiceOver、iPad、降低透明度等未验。保存持久沿用v4上一轮通过证据，本轮只角标绘制改动，未重复保存/跨清单大套业务。

旧问题截图保留在../V4/CompactDarkMax/v4-icon-picker.png。当前截图与AX以light-normal/dark-normal/light-max/dark-max区分，另有搜索选择证据。复跑runner仅选testV4IconBadge，分别用simctl ui appearance与content_size设置四组；README已有通用命令。最终恢复模拟器light/large。

结论：本轮角标布局、触点、选择/search/cancel检查通过，VoiceOver未验。
