# Third-party finance icons

- Chinese bank logo SVGs: [IconGo/bank-logos](https://github.com/icongo/bank-logos), MIT License.
- Alipay and WeChat brand SVGs: [Simple Icons](https://simpleicons.org/), CC0 1.0. Product names and trademarks remain the property of their owners.
- Generic finance SVGs: [Material Design Icons](https://pictogrammers.com/library/mdi/) downloaded through the Iconify public API, Apache License 2.0.

The assets are stored locally and do not make network requests at application runtime.

## 账户用途图标（2026-09-27）

`type-*` 的 14 个金色圆形 SVG 为本项目绘制的通用钱包、卡片、理财等线条图形，非 iCost 或平台商标。缺少可用品牌素材时使用这些通用图标；已有品牌素材沿用上述来源。

## 品牌素材补齐（2026-09-27）

161 家可选银行全部使用品牌素材：113 个来自 IconGo/bank-logos 的方形标志 SVG（MIT，许可证副本 `shared/finance/BANK_LOGOS_LICENSE`），48 个来自逐项核对应用名和发行方的官方 App Store 应用图标。28 个产品条目新增品牌素材，来源包括官方 App Store、PayPal、美团、微粒贷、澳门通和 Timon 官网；花呗为 BootstrapMB 发布的品牌矢量，按品牌蓝色着色，并非官网发布。

逐项名称、目录 ID、图片 URL、来源页面、发行方（如适用）、SHA-256 与产品／平台标志说明见 `shared/finance/brand-icons.json`。应用图标可能带版本活动角标；白条与金条使用京东金融平台标志，抖音月付与放心借使用抖音平台标志，不能视为产品专属标志。商标归各品牌所有，App Store 与官网素材仅用于识别账户，不代表获得官方授权或背书。

余额宝、余利宝、小荷包、微信零钱通、借呗、微信分付、备用金尚未取得可确认且适合小尺寸的独立品牌素材，仍列在 manifest 的 pendingProductMarks 中，不计入已补齐数量。现金、储蓄卡、贷款等非品牌类型继续使用类别图标。

所有素材本地打包，运行时不请求图标服务。iOS/Web 同步通过 `node scripts/sync-account-catalog.mjs` 完成；重新导入银行目录后执行此命令可恢复品牌绑定。
