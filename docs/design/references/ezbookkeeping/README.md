# ezBookkeeping 分类方案核验

这是一份外部方案的来源快照和亮暗对照资料，尚未替换应用内目录或迁移用户数据。分类、中文名称、顺序、颜色与图标 ID 均原样提取，没有重新组合分类。

## 来源

- 项目：https://github.com/mayswind/ezbookkeeping
- 固定提交：`bfdaf0a96a74953123aef3bdb40f913efc0662a2`
- 两级目录：`src/consts/category.ts`
- 官方中文：`src/locales/zh_Hans.json`
- 图标映射：`src/consts/icon.ts`
- 颜色处理：`src/components/base/ItemIconBase.ts`
- 亮暗变量：`src/styles/mobile/_variable.scss`、`src/styles/desktop/_variable.scss`
- 原始图标：https://github.com/icons8/line-awesome
- 项目 MIT 许可及图标许可声明保存在本目录；图标上游说明可选择 MIT 授权。

## 已核对

- 支出 11 个一级分类、42 个二级分类；收入 3 个一级分类、11 个二级分类。
- `catalog.json` 包含官方中文、英文原名、图标 ID、原始类名和颜色；`icons/` 保留所需原始 SVG。
- 默认黑色图标随主题切换为黑／白；其余分类保留上游配色。
- 对照底色沿用上游桌面表面色：亮色 `#FFFFFF`、暗色 `#1C1A18`。
- 对照布局是资源核验视图，不是原产品截图或已完成的本项目界面。
- 未纳入上游转账分类，避免改变本项目按账户类型区分充值、还款的既有语义。

## 接入边界

- 官方译文包含“服饰外貌”“交流通讯”“租金贷款”等，快照没有自行润色。
- 本项目将贷款本金与利息分开处理；不能照搬“租金贷款”的名称，把还本金重复计入消费支出。
- 不能把新目录追加到旧目录。实施时需保留旧分类 ID 与历史流水关联，把旧内置分类从新记账选择中退役，保留用户自定义分类。
- 同名不等于同义，不能只按字符串自动合并历史数据。
