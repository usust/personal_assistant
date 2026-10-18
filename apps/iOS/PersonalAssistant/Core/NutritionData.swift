import Foundation

/// 饮食数据只保存用户确认的结构化估算，不包含照片或 HealthKit 写入。
nonisolated struct MealItem: Codable, Equatable {
    var name: String
    var grams: Double
    var calories: Double
    /// 校验食物字段；参数：无；返回值：名称、克数和千卡是否满足后端范围；无副作用。
    var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 120 &&
        grams.isFinite && grams > 0 && grams <= 10_000 && calories.isFinite && calories > 0 && calories <= 20_000
    }
}

nonisolated struct MealRecord: Decodable, Identifiable {
    let id: String
    let date: String
    let meal_type: String
    let items: [MealItem]
    let note: String
    let created_at: String
    /// 汇总确认过的餐食；参数：无；返回值：估算千卡合计；无副作用。
    var calories: Double { items.reduce(0) { $0 + $1.calories } }
}

nonisolated struct NutritionOverview: Decodable {
    let daily_goal: Double?
    let meals: [MealRecord]
    /// 汇总所选日期已记录摄入；参数：无；返回值：已记录千卡，不代表完整全天实际摄入；无副作用。
    var calories: Double { meals.reduce(0) { $0 + $1.calories } }
}

nonisolated struct MealAnalysisResult: Decodable {
    let recognized: Bool
    let items: [MealItem]
    let note: String
    /// 再次校验视觉协议；参数：无；返回值：可供核对的结果是否合法；未识别不允许夹带食物。
    var valid: Bool {
        note.utf8.count <= 1500 && items.count <= 20 && items.allSatisfy(\.valid) &&
        (recognized ? !items.isEmpty : items.isEmpty)
    }
}

/// 编辑时使用字符串，保留清空、未完成数字等草稿状态，避免非法输入悄悄变成零。
nonisolated struct MealItemDraft: Identifiable {
    let id = UUID()
    var name = ""
    var grams = ""
    var calories = ""
    private var caloriesPerGram: Double?
    /// 创建空白食物草稿；参数：无；返回值：未通过校验的空白草稿；无副作用。
    init() {}
    /// 从估算构建可编辑草稿；参数：item 为已校验食物；返回值：保留足够精度的草稿；无副作用。
    init(_ item: MealItem) {
        name = item.name; grams = Self.number(item.grams); calories = Self.number(item.calories)
        caloriesPerGram = item.grams > 0 ? item.calories / item.grams : nil
    }
    /// 获取合法食物；参数：无；返回值：有效字段或 nil，不将非法文本转成零。
    var item: MealItem? {
        guard let weight = Double(grams), let energy = Double(calories) else { return nil }
        let result = MealItem(name: name.trimmingCharacters(in: .whitespacesAndNewlines), grams: weight, calories: energy)
        return result.valid ? result : nil
    }
    /// 按份量比例调整热量；参数：newGrams 为新克数文本；返回值：无；仅新旧克数合法时等比例更新，非法草稿不会除零或产生非有限值。
    mutating func changeGrams(_ newGrams: String) {
        // 缓存热量密度，输入被暂时清空也不丢失比例，逐字输入不会重复按旧热量累乘。
        if caloriesPerGram == nil { updateDensity() }
        if let density = caloriesPerGram, let weight = Double(newGrams), weight.isFinite, weight > 0, weight <= 10_000 {
            let scaled = density * weight
            if scaled.isFinite { calories = Self.number(scaled) }
        }
        grams = newGrams
    }
    /// 修改热量并更新份量换算基准；参数：newCalories 为手动文本；返回值：无；无效输入清除比例，避免以后沿用未确认值。
    mutating func changeCalories(_ newCalories: String) {
        calories = newCalories; updateDensity()
    }
    /// 更新换算密度；参数：无；返回值：无；仅对有效正数建立比例，不改写草稿文字。
    private mutating func updateDensity() {
        guard let weight = Double(grams), weight.isFinite, weight > 0,
              let energy = Double(calories), energy.isFinite, energy > 0 else { caloriesPerGram = nil; return }
        caloriesPerGram = energy / weight
    }
    /// 格式化编辑值；参数：value 为有限数值；返回值：不依赖地区小数点的数字，不额外舍入到整数；无副作用。
    static func number(_ value: Double) -> String {
        if value.isFinite, value.rounded() == value, abs(value) < 1e15 {
            return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
        }
        return String(value)
    }
}

nonisolated enum NutritionMath {
    static let mealNames = ["breakfast": "早餐", "lunch": "午餐", "dinner": "晚餐", "snack": "加餐"]
    /// 校验手动每日目标；参数：value 为千卡；返回值：是否在支持范围；范围不是个体医学建议。
    static func validGoal(_ value: Double) -> Bool { value.isFinite && (1000...6000).contains(value) }
    /// 生成已记录摄入与目标比较；参数：recorded 为所选日期记录合计，adding 为待确认单餐，goal 为手动目标；返回值：不将缺失目标或未知全天记录当成已超标的中文状态，无副作用。
    static func comparison(recorded: Double, adding: Double = 0, goal: Double?) -> String {
        guard recorded.isFinite, adding.isFinite, recorded >= 0, adding >= 0 else { return "摄入数据无效" }
        guard let goal, validGoal(goal) else { return "设置每日热量目标后可比较" }
        let total = recorded + adding
        guard total.isFinite else { return "摄入数据无效" }
        let context = adding > 0 ? "计入本餐后，已记录摄入" : "已记录摄入"
        if total > goal { return "\(context)高于目标约 \(String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), total - goal)) 千卡" }
        if total == goal { return "\(context)达到每日目标" }
        return "\(context)低于目标约 \(String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), goal - total)) 千卡"
    }
    /// 校验可保存餐食；参数：items 为草稿、note 为备注；返回值：所有项目有效且在接口限制内时为 true；无副作用。
    static func validMeal(_ items: [MealItemDraft], note: String) -> Bool {
        (1...20).contains(items.count) && note.utf8.count <= 1500 && items.allSatisfy { $0.item != nil }
    }
}
