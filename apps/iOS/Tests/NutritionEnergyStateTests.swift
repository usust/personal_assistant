import Foundation

/// 验证摄入可视化不会误把缺失、零值和超量当成同一状态；参数：无；返回值：无；断言失败退出。
func testNutritionEnergyState() {
    let empty = NutritionEnergyState(recorded: 0, goal: 2000, hasMeals: false)
    assert(empty.fill == 0 && empty.title == "等你记录第一餐")
    let missing = NutritionEnergyState(recorded: 900, goal: nil, hasMeals: true)
    assert(missing.ratio == nil && missing.title == "等一个每日参考")
    let within = NutritionEnergyState(recorded: 800, goal: 2000, hasMeals: true)
    assert(within.ratio == 0.4 && within.fill == 0.4)
    let near = NutritionEnergyState(recorded: 1900, goal: 2000, hasMeals: true)
    assert(near.title == "接近每日参考")
    let over = NutritionEnergyState(recorded: 3000, goal: 2000, hasMeals: true)
    assert(over.ratio == 1.5 && over.fill == 1)
    assert(over.title == "已超过参考值" && over.accessibilitySummary.contains("1000"))
    for invalid in [Double.nan, .infinity, -1] {
        assert(NutritionEnergyState(recorded: invalid, goal: 2000, hasMeals: true).ratio == nil)
    }
    assert(NutritionEnergyState(recorded: 800, goal: 0, hasMeals: true).ratio == nil)
    assert(NutritionEnergyState(recorded: 800, goal: .infinity, hasMeals: true).ratio == nil)
    print("NutritionEnergyState: 11 assertions passed")
}

@main struct NutritionEnergyStateTests {
    /// 执行可视化边界测试；参数：无；返回值：无；断言失败终止进程。
    static func main() { testNutritionEnergyState() }
}
