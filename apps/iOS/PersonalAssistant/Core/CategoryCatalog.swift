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
