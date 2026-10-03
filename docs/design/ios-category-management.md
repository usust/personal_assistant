# iOS 账单分类管理设计

顶部使用支出／收入分段控件。左侧为一级分类，右侧为具体项目，两栏独立滚动。选中分组采用浅色背景、彩色图标及左侧标记；具体项目采用圆角图标底座和完整名称。支持系统深色与动态字号，大字号下具体项目自动减少列数。

已有分类与推荐分类分开展示。推荐项目有加号，点击进入预填表单，保存后才进入账本；自定义入口支持填写名称及选择本组图标。表单继承当前收支类型与一级分组，提交中锁定关闭，失败保留输入。

## 素材评估

| 方案 | 授权与来源 | 适配评价 |
| --- | --- | --- |
| Lucide | [ISC，官方项目](https://github.com/lucide-icons/lucide/blob/main/LICENSE) | 线条简洁，适合 Vue/Web，后续跨端统一 SVG 可优先考虑 |
| Tabler Icons | [MIT，官方项目](https://github.com/tabler/tabler-icons) | 题材丰富，适合需要更多细分类图标的 Web 页面 |
| SF Symbols（本次采用） | [Apple 官方资源](https://developer.apple.com/sf-symbols/)，不是开源库 | 当前 iOS 已使用系统符号，可随字体缩放、适配深色，无额外图片依赖 |

本次不混用多套素材。颜色按一级分组统一，图标负责表达具体含义；图标均通过 `Image(systemName:)` 显示。

## 分类与图标完整清单

### 支出 · 餐饮

一级图标：`fork.knife`；分组键：`food`；颜色：`#E99B43`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 早餐 | `sunrise` |
| 午餐 | `fork.knife` |
| 晚餐 | `moon.stars` |
| 外卖 | `takeoutbag.and.cup.and.straw` |
| 咖啡 | `cup.and.saucer` |
| 奶茶 | `cup.and.saucer.fill` |
| 零食 | `birthday.cake` |
| 水果 | `carrot` |

### 支出 · 交通

一级图标：`tram.fill`；分组键：`transport`；颜色：`#5C91CE`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 公交 | `bus` |
| 地铁 | `tram` |
| 打车 | `car.side` |
| 加油 | `fuelpump` |
| 停车 | `parkingsign.circle` |
| 火车 | `tram.fill` |
| 机票 | `airplane` |
| 骑行 | `bicycle` |

### 支出 · 购物

一级图标：`bag.fill`；分组键：`shopping`；颜色：`#D57FA6`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 服饰 | `tshirt` |
| 鞋包 | `bag` |
| 日用品 | `basket` |
| 数码 | `headphones` |
| 家电 | `tv` |
| 美妆 | `sparkles` |

### 支出 · 居住

一级图标：`house.fill`；分组键：`home`；颜色：`#B88D69`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 房租 | `house` |
| 物业 | `building.2` |
| 维修 | `wrench.and.screwdriver` |
| 家居 | `sofa` |
| 装修 | `paintbrush` |

### 支出 · 缴费

一级图标：`bolt.fill`；分组键：`utilities`；颜色：`#C4A34B`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 水费 | `drop` |
| 电费 | `bolt` |
| 燃气 | `flame` |
| 话费 | `iphone` |
| 宽带 | `wifi` |

### 支出 · 医疗

一级图标：`cross.case.fill`；分组键：`health`；颜色：`#DB7A7A`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 门诊 | `cross.case` |
| 药品 | `pills` |
| 体检 | `heart.text.square` |
| 牙科 | `cross` |
| 医疗保险 | `shield.lefthalf.filled` |

### 支出 · 休闲

一级图标：`gamecontroller.fill`；分组键：`leisure`；颜色：`#9983C9`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 电影 | `film` |
| 游戏 | `gamecontroller` |
| 运动 | `figure.run` |
| 旅行 | `airplane.departure` |
| 住宿 | `bed.double` |
| 订阅 | `play.rectangle` |

### 支出 · 学习

一级图标：`book.fill`；分组键：`education`；颜色：`#6C9F9B`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 书籍 | `books.vertical` |
| 课程 | `graduationcap` |
| 考试 | `pencil.and.list.clipboard` |
| 文具 | `pencil` |

### 支出 · 人情

一级图标：`gift.fill`；分组键：`social`；颜色：`#D18B97`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 礼物 | `gift` |
| 红包 | `envelope` |
| 请客 | `person.2` |
| 捐赠 | `heart` |

### 支出 · 家庭

一级图标：`figure.2.and.child.holdinghands`；分组键：`family`；颜色：`#BC956C`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 育儿 | `figure.and.child.holdinghands` |
| 孝敬父母 | `person.2.fill` |
| 家庭用品 | `house` |

### 支出 · 宠物

一级图标：`pawprint.fill`；分组键：`pets`；颜色：`#B39070`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 宠物食品 | `pawprint` |
| 宠物医疗 | `cross.case` |
| 宠物用品 | `tennisball` |

### 支出 · 其他

一级图标：`ellipsis.circle.fill`；分组键：`other-expense`；颜色：`#8E98A5`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 手续费 | `creditcard` |
| 其他支出 | `ellipsis.circle` |

### 收入 · 工资

一级图标：`briefcase.fill`；分组键：`salary`；颜色：`#51A997`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 月薪 | `briefcase` |
| 奖金 | `star` |
| 补贴 | `banknote` |
| 年终奖 | `rosette` |

### 收入 · 兼职

一级图标：`laptopcomputer`；分组键：`side-job`；颜色：`#629FC5`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 兼职报酬 | `laptopcomputer` |
| 稿费 | `pencil.line` |
| 劳务报酬 | `hammer` |

### 收入 · 投资

一级图标：`chart.line.uptrend.xyaxis`；分组键：`investment`；颜色：`#A28AC8`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 利息 | `percent` |
| 分红 | `chart.pie` |
| 投资收益 | `chart.line.uptrend.xyaxis` |
| 租金 | `building.2` |

### 收入 · 礼金

一级图标：`gift.fill`；分组键：`gifts`；颜色：`#D791A6`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 礼金 | `gift` |
| 收到红包 | `envelope` |
| 奖励 | `medal` |

### 收入 · 其他

一级图标：`ellipsis.circle.fill`；分组键：`other-income`；颜色：`#8E98A5`。

| 名称 | SF Symbols 图标 |
| --- | --- |
| 二手出售 | `shippingbox` |
| 其他收入 | `ellipsis.circle` |

## 数据兼容与发布

分类接口新增可选 `groupKey`、`icon`，服务端校验分组白名单及收支归属。已有分类 ID 和流水引用不变；iOS 对旧分类按精确名称映射分组，无法识别时归入同收支类型的“其他”。新字段由现有启动迁移添加；需要先部署后端再发布新 iOS，否则旧后端会拒绝新增字段。

一级分类是内置目录，本次未加入一级分类自定义、分类重命名或删除接口。现有 Web 客户端继续兼容原字段，此次改版针对用户截图中的 iOS 页面。

## 验证

后端：`go test ./internal/finance ./internal/app`，包含展示字段持久化、旧客户端省略字段、分组错配及非法图标校验。

iOS：Xcode 模拟器 Debug 构建；独立 `CategoryCatalogTests.swift` 检查旧数据解码、归组、自定义字段优先级和目录唯一性。该测试与现有 CoreTests 各自包含入口，应单独编译运行。
