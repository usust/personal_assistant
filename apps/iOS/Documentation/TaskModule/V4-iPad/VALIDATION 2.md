# v4 iPad 布局独立验收

2026-10-05，runtime_baseline，未修改业务或测试源码。simctl实际设备iPad Pro11-inch M5，UUID E8A87829-F0B0-444E-81F0-5C4B2C39238E，iOS27.0。默认large浅色、竖屏834×1210pt、截图1668×2420px。安装现有badge修正版Debug应用，复用testV4Pages，单项TEST SUCCEEDED。

六页实际运行并目视：清单根为iPad顶部原生Tab/sidebarAdaptable呈现，列表图标/name/remark/count清晰；清单树push后顶部全局Tab隐藏，保留平台sidebar切换按钮，返回可达；main6/11和54.5%/leaf5/10和50%正确，bar比例可见；main编辑居中系统sheet、字段浮动label和归属正常，长表单需要滚动；图标picker六列全显、选中角标无遮挡；leaf无新增下级，底部减少/数值/增加工具栏可见；空main暂无任务已运行。

原生呈现差异：浏览内容使用全宽，标题与右侧数值距离较大；leaf底部工具栏系统将三个item分布在左右/中间，不是iPhone紧邻组。没有裁字、遮挡或功能不可达的证据，不据此宣称每种宽屏阅读品质已优化。sidebar展开状态未操作，只确认已有toggle与顶部Tab平台适配。

本轮只默认浅色竖屏；dark/max字号、横屏、分屏/Stage Manager、sidebar展开、硬件键盘、VoiceOver、真实服务业务均未验。既有iPhone/Store行为证据保留，不重跑大套。

复跑：按Tests/UITests/TaskModule/README.md安装Debug，以上述设备destination执行only-testing:LoanSwipeTests/LoanSwipeTests/testV4Pages；app虚构v4样本，非真实账号。六图及额外空main、AX、日志保存在本目录，不覆盖iPhone证据。

结论：实际六页默认浅色iPad布局运行检查通过，明确剩余尺寸/平台交互未验。
