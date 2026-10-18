import Foundation

/// 内置收支分类目录；服务端默认补齐分类，客户端提供分组与图标，并兼容旧服务端的按需创建。
nonisolated struct CategoryTemplate: Identifiable {
    let name: String
    let icon: String
    var id: String { name }
}
nonisolated struct CategoryGroup: Identifiable {
    let id: String
    let name: String
    let icon: String
    let color: String
    let type: String
    let aliases: [String]
    let items: [CategoryTemplate]
}
/// 分类编辑器共用图标；symbol 为持久化的 SF Symbols 名，中文名称与关键词用于辅助朗读和搜索。
nonisolated struct CategoryIcon: Identifiable {
    let symbol: String
    let name: String
    var groupIDs: [String]
    var keywords: [String]
    /// 图标稳定标识；参数：无；返回值：系统符号名称，与持久化值一致。
    var id: String { symbol }
}

nonisolated enum CategoryCatalog {
    static let groups: [CategoryGroup] = [
        CategoryGroup(id: "food", name: "餐饮", icon: "fork.knife", color: "#E99B43", type: "expense", aliases: ["餐饮"], items: [
            CategoryTemplate(name: "早餐", icon: "sunrise"),
            CategoryTemplate(name: "午餐", icon: "fork.knife"),
            CategoryTemplate(name: "晚餐", icon: "moon.stars"),
            CategoryTemplate(name: "外卖", icon: "takeoutbag.and.cup.and.straw"),
            CategoryTemplate(name: "咖啡", icon: "cup.and.saucer"),
            CategoryTemplate(name: "奶茶", icon: "cup.and.saucer.fill"),
            CategoryTemplate(name: "零食", icon: "birthday.cake"),
            CategoryTemplate(name: "水果", icon: "carrot"),
        ]),
        CategoryGroup(id: "transport", name: "交通", icon: "tram.fill", color: "#5C91CE", type: "expense", aliases: ["交通"], items: [
            CategoryTemplate(name: "公交", icon: "bus"),
            CategoryTemplate(name: "地铁", icon: "tram"),
            CategoryTemplate(name: "打车", icon: "car.side"),
            CategoryTemplate(name: "加油", icon: "fuelpump"),
            CategoryTemplate(name: "停车", icon: "parkingsign.circle"),
            CategoryTemplate(name: "火车", icon: "tram.fill"),
            CategoryTemplate(name: "机票", icon: "airplane"),
            CategoryTemplate(name: "骑行", icon: "bicycle"),
        ]),
        CategoryGroup(id: "shopping", name: "购物", icon: "bag.fill", color: "#D57FA6", type: "expense", aliases: ["购物"], items: [
            CategoryTemplate(name: "服饰", icon: "tshirt"),
            CategoryTemplate(name: "鞋包", icon: "bag"),
            CategoryTemplate(name: "日用品", icon: "basket"),
            CategoryTemplate(name: "数码", icon: "headphones"),
            CategoryTemplate(name: "家电", icon: "tv"),
            CategoryTemplate(name: "美妆", icon: "sparkles"),
        ]),
        CategoryGroup(id: "home", name: "居住", icon: "house.fill", color: "#B88D69", type: "expense", aliases: ["居住"], items: [
            CategoryTemplate(name: "房租", icon: "house"),
            CategoryTemplate(name: "物业", icon: "building.2"),
            CategoryTemplate(name: "维修", icon: "wrench.and.screwdriver"),
            CategoryTemplate(name: "家居", icon: "sofa"),
            CategoryTemplate(name: "装修", icon: "paintbrush"),
        ]),
        CategoryGroup(id: "utilities", name: "缴费", icon: "bolt.fill", color: "#C4A34B", type: "expense", aliases: ["生活缴费"], items: [
            CategoryTemplate(name: "水费", icon: "drop"),
            CategoryTemplate(name: "电费", icon: "bolt"),
            CategoryTemplate(name: "燃气", icon: "flame"),
            CategoryTemplate(name: "话费", icon: "iphone"),
            CategoryTemplate(name: "宽带", icon: "wifi"),
        ]),
        CategoryGroup(id: "health", name: "医疗", icon: "cross.case.fill", color: "#DB7A7A", type: "expense", aliases: ["医疗"], items: [
            CategoryTemplate(name: "门诊", icon: "cross.case"),
            CategoryTemplate(name: "药品", icon: "pills"),
            CategoryTemplate(name: "体检", icon: "heart.text.square"),
            CategoryTemplate(name: "牙科", icon: "cross"),
            CategoryTemplate(name: "医疗保险", icon: "shield.lefthalf.filled"),
        ]),
        CategoryGroup(id: "leisure", name: "休闲", icon: "gamecontroller.fill", color: "#9983C9", type: "expense", aliases: ["娱乐", "休闲"], items: [
            CategoryTemplate(name: "电影", icon: "film"),
            CategoryTemplate(name: "游戏", icon: "gamecontroller"),
            CategoryTemplate(name: "运动", icon: "figure.run"),
            CategoryTemplate(name: "旅行", icon: "airplane.departure"),
            CategoryTemplate(name: "住宿", icon: "bed.double"),
            CategoryTemplate(name: "订阅", icon: "play.rectangle"),
        ]),
        CategoryGroup(id: "education", name: "学习", icon: "book.fill", color: "#6C9F9B", type: "expense", aliases: ["教育", "学习"], items: [
            CategoryTemplate(name: "书籍", icon: "books.vertical"),
            CategoryTemplate(name: "课程", icon: "graduationcap"),
            CategoryTemplate(name: "考试", icon: "pencil.and.list.clipboard"),
            CategoryTemplate(name: "文具", icon: "pencil"),
        ]),
        CategoryGroup(id: "social", name: "人情", icon: "gift.fill", color: "#D18B97", type: "expense", aliases: ["人情"], items: [
            CategoryTemplate(name: "礼物", icon: "gift"),
            CategoryTemplate(name: "红包", icon: "envelope"),
            CategoryTemplate(name: "请客", icon: "person.2"),
            CategoryTemplate(name: "捐赠", icon: "heart"),
        ]),
        CategoryGroup(id: "family", name: "家庭", icon: "figure.2.and.child.holdinghands", color: "#BC956C", type: "expense", aliases: ["家庭"], items: [
            CategoryTemplate(name: "育儿", icon: "figure.and.child.holdinghands"),
            CategoryTemplate(name: "孝敬父母", icon: "person.2.fill"),
            CategoryTemplate(name: "家庭用品", icon: "house"),
        ]),
        CategoryGroup(id: "pets", name: "宠物", icon: "pawprint.fill", color: "#B39070", type: "expense", aliases: ["宠物"], items: [
            CategoryTemplate(name: "宠物食品", icon: "pawprint"),
            CategoryTemplate(name: "宠物医疗", icon: "cross.case"),
            CategoryTemplate(name: "宠物用品", icon: "tennisball"),
        ]),
        // 扩展目录仅提供可选模板，保留前面的旧模板以兼容无 groupKey 的历史分类。
        CategoryGroup(id: "clothing", name: "服饰", icon: "tshirt.fill", color: "#D57FA6", type: "expense", aliases: ["服饰"], items: [
            CategoryTemplate(name: "上装", icon: "tshirt"),
            CategoryTemplate(name: "鞋履", icon: "shoe"),
            CategoryTemplate(name: "箱包", icon: "bag"),
            CategoryTemplate(name: "配饰", icon: "eyeglasses"),
            CategoryTemplate(name: "洗衣", icon: "washer"),
        ]),
        CategoryGroup(id: "daily", name: "日用", icon: "basket.fill", color: "#BB9966", type: "expense", aliases: ["日用"], items: [
            CategoryTemplate(name: "清洁用品", icon: "bubbles.and.sparkles"),
            CategoryTemplate(name: "洗护用品", icon: "shower"),
            CategoryTemplate(name: "厨房用品", icon: "frying.pan"),
            CategoryTemplate(name: "收纳用品", icon: "shippingbox"),
        ]),
        CategoryGroup(id: "digital", name: "数码", icon: "desktopcomputer", color: "#638FCB", type: "expense", aliases: ["数码"], items: [
            CategoryTemplate(name: "手机设备", icon: "iphone"),
            CategoryTemplate(name: "电脑设备", icon: "laptopcomputer"),
            CategoryTemplate(name: "影音设备", icon: "headphones"),
            CategoryTemplate(name: "摄影器材", icon: "camera"),
            CategoryTemplate(name: "数码配件", icon: "keyboard"),
        ]),
        CategoryGroup(id: "beauty", name: "美容", icon: "comb.fill", color: "#CF87AE", type: "expense", aliases: ["美容"], items: [
            CategoryTemplate(name: "护肤", icon: "drop"),
            CategoryTemplate(name: "彩妆", icon: "paintbrush.pointed"),
            CategoryTemplate(name: "美发", icon: "scissors"),
            CategoryTemplate(name: "美甲", icon: "hand.raised"),
            CategoryTemplate(name: "美容护理", icon: "sparkles"),
        ]),
        CategoryGroup(id: "software", name: "软件", icon: "app.badge.fill", color: "#8B82C6", type: "expense", aliases: ["软件"], items: [
            CategoryTemplate(name: "应用购买", icon: "app"),
            CategoryTemplate(name: "软件会员", icon: "checkmark.seal"),
            CategoryTemplate(name: "云存储", icon: "icloud"),
            CategoryTemplate(name: "影音会员", icon: "play.rectangle"),
        ]),
        CategoryGroup(id: "communication", name: "通讯", icon: "phone.fill", color: "#62A8A0", type: "expense", aliases: ["通讯"], items: [
            CategoryTemplate(name: "手机套餐", icon: "simcard"),
            CategoryTemplate(name: "流量包", icon: "antenna.radiowaves.left.and.right"),
            CategoryTemplate(name: "网络服务", icon: "network"),
            CategoryTemplate(name: "邮寄快递", icon: "envelope"),
        ]),
        CategoryGroup(id: "car", name: "汽车", icon: "car.fill", color: "#648DB0", type: "expense", aliases: ["汽车"], items: [
            CategoryTemplate(name: "车辆保养", icon: "wrench.and.screwdriver"),
            CategoryTemplate(name: "洗车", icon: "car.side"),
            CategoryTemplate(name: "汽车保险", icon: "shield"),
            CategoryTemplate(name: "过路费", icon: "road.lanes"),
            CategoryTemplate(name: "车辆充电", icon: "bolt.car"),
        ]),
        CategoryGroup(id: "sports", name: "运动", icon: "dumbbell.fill", color: "#72A583", type: "expense", aliases: ["运动"], items: [
            CategoryTemplate(name: "健身", icon: "dumbbell"),
            CategoryTemplate(name: "球类", icon: "basketball"),
            CategoryTemplate(name: "游泳", icon: "figure.pool.swim"),
            CategoryTemplate(name: "户外", icon: "figure.hiking"),
            CategoryTemplate(name: "运动装备", icon: "sportscourt"),
        ]),
        CategoryGroup(id: "travel", name: "旅行", icon: "suitcase.rolling.fill", color: "#C99A5E", type: "expense", aliases: ["旅行"], items: [
            CategoryTemplate(name: "酒店民宿", icon: "bed.double"),
            CategoryTemplate(name: "景点门票", icon: "ticket"),
            CategoryTemplate(name: "旅游团费", icon: "flag"),
            CategoryTemplate(name: "签证", icon: "globe.asia.australia"),
            CategoryTemplate(name: "露营", icon: "tent"),
        ]),
        CategoryGroup(id: "office", name: "办公", icon: "printer.fill", color: "#7F98A9", type: "expense", aliases: ["办公"], items: [
            CategoryTemplate(name: "办公耗材", icon: "paperclip"),
            CategoryTemplate(name: "打印复印", icon: "printer"),
            CategoryTemplate(name: "办公设备", icon: "desktopcomputer"),
            CategoryTemplate(name: "办公场地", icon: "building.2"),
        ]),
        CategoryGroup(id: "kids", name: "育儿", icon: "figure.and.child.holdinghands", color: "#D39679", type: "expense", aliases: ["育儿"], items: [
            CategoryTemplate(name: "奶粉辅食", icon: "carrot"),
            CategoryTemplate(name: "婴童用品", icon: "stroller"),
            CategoryTemplate(name: "玩具", icon: "teddybear"),
            CategoryTemplate(name: "托育", icon: "figure.child"),
            CategoryTemplate(name: "亲子活动", icon: "balloon"),
        ]),
        CategoryGroup(id: "insurance", name: "保险", icon: "shield.lefthalf.filled", color: "#709FAD", type: "expense", aliases: ["保险"], items: [
            CategoryTemplate(name: "意外保险", icon: "bandage"),
            CategoryTemplate(name: "寿险", icon: "heart"),
            CategoryTemplate(name: "财产保险", icon: "house"),
            CategoryTemplate(name: "旅行保险", icon: "airplane.circle"),
        ]),
        CategoryGroup(id: "other-expense", name: "其他", icon: "ellipsis.circle.fill", color: "#8E98A5", type: "expense", aliases: ["其他支出"], items: [
            CategoryTemplate(name: "手续费", icon: "creditcard"),
            CategoryTemplate(name: "其他支出", icon: "ellipsis.circle"),
        ]),
        CategoryGroup(id: "salary", name: "工资", icon: "briefcase.fill", color: "#51A997", type: "income", aliases: ["工资"], items: [
            CategoryTemplate(name: "月薪", icon: "briefcase"),
            CategoryTemplate(name: "奖金", icon: "star"),
            CategoryTemplate(name: "补贴", icon: "banknote"),
            CategoryTemplate(name: "年终奖", icon: "rosette"),
        ]),
        CategoryGroup(id: "side-job", name: "兼职", icon: "laptopcomputer", color: "#629FC5", type: "income", aliases: ["兼职"], items: [
            CategoryTemplate(name: "兼职报酬", icon: "laptopcomputer"),
            CategoryTemplate(name: "稿费", icon: "pencil.line"),
            CategoryTemplate(name: "劳务报酬", icon: "hammer"),
        ]),
        CategoryGroup(id: "investment", name: "投资", icon: "chart.line.uptrend.xyaxis", color: "#A28AC8", type: "income", aliases: ["投资", "理财"], items: [
            CategoryTemplate(name: "利息", icon: "percent"),
            CategoryTemplate(name: "分红", icon: "chart.pie"),
            CategoryTemplate(name: "投资收益", icon: "chart.line.uptrend.xyaxis"),
            CategoryTemplate(name: "租金", icon: "building.2"),
        ]),
        CategoryGroup(id: "gifts", name: "礼金", icon: "gift.fill", color: "#D791A6", type: "income", aliases: ["礼金"], items: [
            CategoryTemplate(name: "礼金", icon: "gift"),
            CategoryTemplate(name: "收到红包", icon: "envelope"),
            CategoryTemplate(name: "奖励", icon: "medal"),
        ]),
        CategoryGroup(id: "other-income", name: "其他", icon: "ellipsis.circle.fill", color: "#8E98A5", type: "income", aliases: ["其他收入"], items: [
            CategoryTemplate(name: "二手出售", icon: "shippingbox"),
            CategoryTemplate(name: "其他收入", icon: "ellipsis.circle"),
        ]),
    ]
    // 图标先收录全部目录符号，再按目录附加生活与收支常用项；不改变模板或历史分类归属。
    private static let additionalIcons: [String: [CategoryTemplate]] = [
        "food": [
            CategoryTemplate(name: "餐具", icon: "fork.knife.circle"), CategoryTemplate(name: "热饮", icon: "mug"),
            CategoryTemplate(name: "饮品", icon: "mug.fill"), CategoryTemplate(name: "酒水", icon: "wineglass"),
            CategoryTemplate(name: "聚餐", icon: "wineglass.fill"), CategoryTemplate(name: "蛋糕", icon: "birthday.cake.fill"),
            CategoryTemplate(name: "生鲜", icon: "fish"), CategoryTemplate(name: "海鲜", icon: "fish.fill"),
            CategoryTemplate(name: "蔬果", icon: "leaf"), CategoryTemplate(name: "蔬菜", icon: "leaf.fill"),
            CategoryTemplate(name: "打包", icon: "takeoutbag.and.cup.and.straw.fill"),
        ],
        "transport": [
            CategoryTemplate(name: "公交车", icon: "bus.fill"), CategoryTemplate(name: "汽车", icon: "car"),
            CategoryTemplate(name: "轮渡", icon: "ferry"), CategoryTemplate(name: "滑板车", icon: "scooter"),
            CategoryTemplate(name: "到达", icon: "airplane.arrival"), CategoryTemplate(name: "帆船", icon: "sailboat"),
        ],
        "shopping": [
            CategoryTemplate(name: "购物车", icon: "cart"), CategoryTemplate(name: "超市", icon: "cart.fill"),
            CategoryTemplate(name: "付款", icon: "creditcard.fill"), CategoryTemplate(name: "折扣", icon: "tag"),
            CategoryTemplate(name: "优惠券", icon: "tag.fill"), CategoryTemplate(name: "扫码", icon: "barcode.viewfinder"),
        ],
        "home": [
            CategoryTemplate(name: "钥匙", icon: "key"), CategoryTemplate(name: "门锁", icon: "key.fill"),
            CategoryTemplate(name: "灯具", icon: "lightbulb"), CategoryTemplate(name: "照明", icon: "lightbulb.fill"),
            CategoryTemplate(name: "台灯", icon: "lamp.desk"), CategoryTemplate(name: "座椅", icon: "chair"),
            CategoryTemplate(name: "冰箱", icon: "refrigerator"),
        ],
        "daily": [
            CategoryTemplate(name: "垃圾袋", icon: "trash"), CategoryTemplate(name: "垃圾桶", icon: "trash.fill"),
            CategoryTemplate(name: "肥皂", icon: "bubbles.and.sparkles"), CategoryTemplate(name: "卫浴", icon: "toilet"),
            CategoryTemplate(name: "洗浴", icon: "bathtub"), CategoryTemplate(name: "烹饪", icon: "frying.pan.fill"),
        ],
        "health": [
            CategoryTemplate(name: "诊疗", icon: "stethoscope"), CategoryTemplate(name: "护理", icon: "bandage.fill"),
            CategoryTemplate(name: "用药", icon: "pills.fill"), CategoryTemplate(name: "疫苗", icon: "syringe"),
            CategoryTemplate(name: "体温", icon: "medical.thermometer"), CategoryTemplate(name: "保健", icon: "heart.fill"),
        ],
        "leisure": [
            CategoryTemplate(name: "音乐", icon: "music.note"), CategoryTemplate(name: "歌单", icon: "music.note.list"),
            CategoryTemplate(name: "乐器", icon: "guitars"), CategoryTemplate(name: "演出", icon: "theatermasks"),
            CategoryTemplate(name: "剧院", icon: "theatermasks.fill"), CategoryTemplate(name: "爆米花", icon: "popcorn"),
        ],
        "education": [
            CategoryTemplate(name: "阅读", icon: "book"), CategoryTemplate(name: "教材", icon: "book.closed"),
            CategoryTemplate(name: "书包", icon: "backpack"), CategoryTemplate(name: "课桌", icon: "studentdesk"),
            CategoryTemplate(name: "学习用品", icon: "pencil.and.ruler"),
        ],
        "social": [
            CategoryTemplate(name: "礼品卡", icon: "giftcard"), CategoryTemplate(name: "赠礼", icon: "giftcard.fill"),
            CategoryTemplate(name: "庆祝", icon: "party.popper"), CategoryTemplate(name: "聚会", icon: "hands.clap"),
            CategoryTemplate(name: "赞赏", icon: "hand.thumbsup"),
        ],
        "family": [
            CategoryTemplate(name: "个人", icon: "person"), CategoryTemplate(name: "家人", icon: "person.fill"),
            CategoryTemplate(name: "家庭成员", icon: "person.3"),
        ],
        "pets": [
            CategoryTemplate(name: "猫咪", icon: "cat"), CategoryTemplate(name: "狗狗", icon: "dog"),
            CategoryTemplate(name: "小鸟", icon: "bird"), CategoryTemplate(name: "兔子", icon: "hare"),
            CategoryTemplate(name: "乌龟", icon: "tortoise"),
        ],
        "clothing": [
            CategoryTemplate(name: "外套", icon: "jacket"), CategoryTemplate(name: "帽子", icon: "hat.widebrim"),
            CategoryTemplate(name: "墨镜", icon: "sunglasses"),
        ],
        "digital": [
            CategoryTemplate(name: "平板", icon: "ipad"), CategoryTemplate(name: "显示器", icon: "display"),
            CategoryTemplate(name: "鼠标", icon: "computermouse"), CategoryTemplate(name: "无线耳机", icon: "airpods"),
            CategoryTemplate(name: "手表", icon: "applewatch"), CategoryTemplate(name: "数据线", icon: "cable.connector"),
        ],
        "beauty": [CategoryTemplate(name: "梳子", icon: "comb")],
        "software": [
            CategoryTemplate(name: "应用", icon: "app.fill"), CategoryTemplate(name: "云服务", icon: "icloud.fill"),
            CategoryTemplate(name: "存储", icon: "externaldrive"), CategoryTemplate(name: "安全服务", icon: "lock.shield"),
        ],
        "communication": [
            CategoryTemplate(name: "电话", icon: "phone"), CategoryTemplate(name: "短信", icon: "message"),
            CategoryTemplate(name: "聊天", icon: "message.fill"), CategoryTemplate(name: "寄件", icon: "paperplane"),
            CategoryTemplate(name: "快递", icon: "paperplane.fill"),
        ],
        "car": [
            CategoryTemplate(name: "汽油", icon: "fuelpump.fill"), CategoryTemplate(name: "驾驶", icon: "steeringwheel"),
            CategoryTemplate(name: "车辆", icon: "car.side.fill"), CategoryTemplate(name: "充电", icon: "bolt.car.fill"),
        ],
        "sports": [
            CategoryTemplate(name: "橄榄球", icon: "football"), CategoryTemplate(name: "棒球", icon: "baseball"),
            CategoryTemplate(name: "网球", icon: "tennis.racket"), CategoryTemplate(name: "足球", icon: "soccerball"),
            CategoryTemplate(name: "瑜伽", icon: "figure.yoga"), CategoryTemplate(name: "步行", icon: "figure.walk"),
            CategoryTemplate(name: "户外骑行", icon: "figure.outdoor.cycle"),
        ],
        "travel": [
            CategoryTemplate(name: "行李", icon: "suitcase"), CategoryTemplate(name: "地图", icon: "map"),
            CategoryTemplate(name: "导航", icon: "map.fill"), CategoryTemplate(name: "登山", icon: "mountain.2"),
            CategoryTemplate(name: "海滩", icon: "beach.umbrella"), CategoryTemplate(name: "拍照", icon: "camera.fill"),
            CategoryTemplate(name: "营地", icon: "tent.fill"),
        ],
        "office": [
            CategoryTemplate(name: "文件夹", icon: "folder"), CategoryTemplate(name: "资料", icon: "folder.fill"),
            CategoryTemplate(name: "文档", icon: "doc.text"), CategoryTemplate(name: "收件", icon: "tray"),
            CategoryTemplate(name: "日程", icon: "calendar"), CategoryTemplate(name: "计时", icon: "clock"),
        ],
        "kids": [
            CategoryTemplate(name: "拼图", icon: "puzzlepiece"), CategoryTemplate(name: "毛绒玩具", icon: "teddybear.fill"),
            CategoryTemplate(name: "气球", icon: "balloon.fill"), CategoryTemplate(name: "儿童", icon: "figure.child.circle"),
        ],
        "insurance": [
            CategoryTemplate(name: "保障", icon: "checkmark.shield"), CategoryTemplate(name: "雨伞", icon: "umbrella"),
            CategoryTemplate(name: "守护", icon: "umbrella.fill"),
        ],
        "other-expense": [
            CategoryTemplate(name: "更多", icon: "ellipsis"), CategoryTemplate(name: "待定", icon: "questionmark.circle"),
            CategoryTemplate(name: "临时支出", icon: "exclamationmark.circle"),
        ],
        "salary": [
            CategoryTemplate(name: "现金", icon: "banknote.fill"), CategoryTemplate(name: "外币", icon: "dollarsign.circle"),
            CategoryTemplate(name: "人民币", icon: "yensign.circle"), CategoryTemplate(name: "钱包", icon: "wallet.pass"),
            CategoryTemplate(name: "银行", icon: "building.columns"),
        ],
        "side-job": [CategoryTemplate(name: "劳务", icon: "hammer.fill"), CategoryTemplate(name: "手工", icon: "wrench")],
        "investment": [
            CategoryTemplate(name: "收益", icon: "chart.bar"), CategoryTemplate(name: "理财", icon: "chart.bar.fill"),
            CategoryTemplate(name: "资产配置", icon: "chart.pie.fill"), CategoryTemplate(name: "行情", icon: "chart.line.downtrend.xyaxis"),
        ],
        "gifts": [CategoryTemplate(name: "奖励", icon: "star.fill"), CategoryTemplate(name: "奖牌", icon: "medal.fill")],
        "other-income": [CategoryTemplate(name: "入账", icon: "plus.circle"), CategoryTemplate(name: "收款", icon: "arrow.down.circle")],
    ]

    static let iconLibrary: [CategoryIcon] = makeIconLibrary()

    /// 汇总去重图标及中文索引；参数：无；返回值：按目录顺序排列的图标，每个系统符号仅一项，合并重复图标的名称、收支与分组关键词；无副作用。
    private static func makeIconLibrary() -> [CategoryIcon] {
        var result: [CategoryIcon] = []
        var positions: [String: Int] = [:]
        /// 收录目录符号；参数：symbol 为有效系统符号，name 为中文名称，group 为所属目录；返回值：无，仅合并本次构建中的图标与搜索索引。
        func append(symbol: String, name: String, group: CategoryGroup) {
            let keywords = [name, group.name, group.type == "income" ? "收入" : "支出"] + group.aliases
            if let index = positions[symbol] {
                if !result[index].groupIDs.contains(group.id) { result[index].groupIDs.append(group.id) }
                result[index].keywords = Array(Set(result[index].keywords + keywords)).sorted()
            } else {
                positions[symbol] = result.count
                result.append(CategoryIcon(symbol: symbol, name: name, groupIDs: [group.id], keywords: keywords))
            }
        }
        for group in groups {
            append(symbol: group.icon, name: group.name, group: group)
            for item in group.items + (additionalIcons[group.id] ?? []) { append(symbol: item.icon, name: item.name, group: group) }
        }
        return result
    }

    /// 搜索并筛选图标；参数：groupID 为目录键，nil 或空串表示全部，未知键返回空数组；query 为中文名称、目录、收支或符号名，空白分隔词须全部匹配；返回值：保持目录顺序的去重图标，无副作用。
    static func icons(groupID: String? = nil, matching query: String = "") -> [CategoryIcon] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // 筛选回调输入一个图标，返回是否同时符合目录和所有搜索词；合并的别名保证共享图标可从各原目录搜到。
        return iconLibrary.filter { option in
            if let groupID, !groupID.isEmpty, !option.groupIDs.contains(groupID) { return false }
            let text = ([option.name, option.symbol] + option.keywords).joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    /// 获取图标中文名称；参数：symbol 为已保存或候选系统符号；返回值：库内中文名称，库外符号返回“自定义图标”，不替换原始符号。
    static func iconName(for symbol: String) -> String { iconLibrary.first { $0.symbol == symbol }?.name ?? "自定义图标" }

    /// 获取收支分组；参数：type 为 expense 或 income；返回值：该类型有序分组，未知类型返回空数组。
    static func groups(for type: String) -> [CategoryGroup] { groups.filter { $0.type == type } }

    /// 解析旧分类的展示归属；参数：category 为服务端分类；返回值：同收支分组；优先使用持久化字段，旧名称精确匹配，未知名称归入其他，不改历史数据。
    static func group(for category: TransactionCategory) -> CategoryGroup {
        let candidates = groups(for: category.type)
        if let explicit = candidates.first(where: { $0.id == category.groupKey }) { return explicit }
        if let inferred = candidates.first(where: { $0.aliases.contains(category.name) || $0.items.contains(where: { $0.name == category.name }) }) { return inferred }
        return candidates.last ?? groups.first(where: { $0.id == "other-expense" })!
    }

    /// 获取分类图标；参数：category 为已有分类；返回值：持久化图标、精确匹配模板图标或分组图标，无副作用。
    static func icon(for category: TransactionCategory) -> String {
        if let icon = category.icon, !icon.isEmpty { return icon }
        let group = group(for: category)
        return group.items.first(where: { $0.name == category.name })?.icon ?? group.icon
    }
}
