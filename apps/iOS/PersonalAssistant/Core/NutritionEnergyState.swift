import Foundation

/// 已记录摄入与参考目标的可视化状态；不把未记录当作实际未进食。
nonisolated struct NutritionEnergyState: Equatable {
    let recorded: Double
    let goal: Double?
    let hasMeals: Bool

    /// 返回有效参考目标；参数：无；返回值：1000…6000 千卡的目标或 nil。
    var validGoal: Double? { goal.flatMap { NutritionMath.validGoal($0) ? $0 : nil } }
    /// 返回未截断的摄入比例；参数：无；返回值：有限非负比例，缺失目标或无效摄入为 nil。
    var ratio: Double? {
        guard let validGoal, recorded.isFinite, recorded >= 0 else { return nil }
        return recorded / validGoal
    }
    /// 返回形状填充比例；参数：无；返回值：0…1；超出部分通过实际百分比和差值另行表达。
    var fill: Double { min(max(ratio ?? 0, 0), 1) }
    /// 返回简短状态标签；参数：无；返回值：中性描述，不生成节食或运动补偿建议。
    var title: String {
        guard hasMeals else { return "等你记录第一餐" }
        guard let ratio else { return "等一个每日参考" }
        if ratio > 1 { return "已超过参考值" }
        if ratio >= 0.9 { return "接近每日参考" }
        return "这一日的能量足迹"
    }
    /// 返回可访问性完整说明；参数：无；返回值：已记录的摄入、目标与差值，不声称是全天实际摄入。
    var accessibilitySummary: String {
        guard hasMeals else { return "尚未记录餐食，不代表尚未进食" }
        return NutritionMath.comparison(recorded: recorded, goal: validGoal)
    }
}
