# 任务清单界面

- 页面使用系统居中 inline 导航标题；导航与保存操作沿用原生工具栏，使用 iOS 27 系统外观。
- 清单列表名称与备注紧邻图标并左对齐，新建清单保留居中预览，编辑清单不显示顶部预览卡片；颜色作用于名称与图标；内容使用普通系统背景，避免玻璃叠加影响可读性。
- “颜色”分组提供 17 种常用色与原生 ColorPicker，共 18 个入口，固定按六列三行排列，颜色盘位于最后一格且不显示独立文字行，颜色保存为不透明 #RRGGBB。
- 92 个任务、计划、日程及日常生活图标采用 Apple SF Symbols，通过跨端共用键存储，编辑保留未改动的旧图标值。
- 任务与清单文本输入在聚焦或有值时浮起字段名；减少动态效果开启时关闭动画。

## 官方资源

- [SF Symbols 图标资源与下载](https://developer.apple.com/sf-symbols/)
- [SF Symbols 设计规范](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- [Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/liquid-glass)
- [Apple Design Resources](https://developer.apple.com/design/resources/)

图标使用系统 Image(systemName:) 绘制，无第三方素材依赖。新增候选图标应同时确认目标 SDK 支持及跨端图标键；不将未知旧键自动覆盖为默认值。
