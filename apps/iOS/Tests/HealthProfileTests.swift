import Foundation

/// 测试失败描述，仅包含虚构测试场景，不输出任何真实健康资料。
struct HealthProfileTestFailure: Error, CustomStringConvertible {
    let description: String
}

/// 校验断言；参数：condition 为预先求值的条件，message 为失败描述；返回值：无；不满足时抛出测试错误。
func healthExpect(_ condition: Bool, _ message: String) throws {
    if !condition { throw HealthProfileTestFailure(description: message) }
}

/// 校验浮点结果；参数：actual 为可能缺失的结果，expected 为期望值，message 为场景说明；返回值：无；误差超过 0.000001 或结果缺失时抛错。
func healthExpectClose(_ actual: Double?, _ expected: Double, _ message: String) throws {
    try healthExpect(actual.map { abs($0 - expected) < 0.000001 } ?? false, message) // 比较回调：输入实际值，返回容差内是否相等。
}

/// 解析测试专用固定时间；参数：value 为带时区的 ISO 8601 时间文本；返回值：日期；格式错误属于测试配置错误并抛出。
func healthDate(_ value: String) throws -> Date {
    guard let date = ISO8601DateFormatter().date(from: value) else { throw HealthProfileTestFailure(description: "测试日期无效：\(value)") }
    return date
}

/// 验证公式、资格、缺失值及 Codable；参数：无；返回值：无；失败抛错，不访问 HealthKit 或网络。
func testHealthProfile() throws {
    let female = HealthProfile(heightCM: 165, weightKG: 60, age: 30, sex: .female, activity: .light)
    try healthExpectClose(female.recommendation?.basalCalories, 1320.25, "女性 Mifflin 基础代谢")
    try healthExpectClose(female.recommendation?.calories, 1815.34375, "女性维持热量不包含减重缺口")
    let male = HealthProfile(heightCM: 180, weightKG: 80, age: 40, sex: .male, activity: .moderate)
    try healthExpectClose(male.recommendation?.basalCalories, 1730, "男性 Mifflin 基础代谢")
    try healthExpectClose(male.recommendation?.calories, 2681.5, "男性维持热量")
    let expectedMultipliers: [Double] = [1.2, 1.375, 1.55, 1.725]
    for (activity, expected) in zip(HealthProfile.Activity.allCases, expectedMultipliers) {
        var profile = female
        profile.activity = activity
        try healthExpectClose(profile.recommendation?.activityMultiplier, expected, "活动水平系数 \(activity.rawValue)")
        try healthExpectClose(profile.recommendation?.calories, 1320.25 * expected, "活动系数仅应用一次")
    }
    try healthExpect(HealthProfile().recommendation == nil, "空资料不能给出建议")
    try healthExpect(HealthProfile().missingRequirements.count == 4, "空资料必须列出四项必填条件")
    var missingSex = female
    missingSex.sex = .unspecified
    try healthExpect(missingSex.recommendation == nil, "不为缺失性别设置默认常量")
    var guidance = female
    guidance.requiresProfessionalGuidance = true
    try healthExpect(guidance.recommendation == nil && !guidance.missingRequirements.isEmpty, "专业指导开关停止自动建议")
    for age in [-1, 0, 17, 81, 130] {
        var profile = female
        profile.age = age
        try healthExpect(profile.recommendation == nil, "超出成人适用年龄 \(age)")
    }
    for age in [18, 80] {
        var profile = female
        profile.age = age
        try healthExpect(profile.recommendation != nil, "年龄边界 \(age)")
    }
    for height in [0, 99.9, 250.1, .infinity, -.infinity, .nan] {
        var profile = female
        profile.heightCM = height
        try healthExpect(profile.recommendation == nil, "异常身高拒绝估算")
    }
    for weight in [0, 29.9, 350.1, .infinity, -.infinity, .nan] {
        var profile = female
        profile.weightKG = weight
        try healthExpect(profile.recommendation == nil, "异常体重拒绝估算")
    }
    for height in [100.0, 250.0] {
        for weight in [30.0, 350.0] {
            var profile = female
            profile.heightCM = height
            profile.weightKG = weight
            try healthExpect(profile.recommendation != nil, "有效身高体重边界")
        }
    }
    let encoded = try JSONEncoder().encode(guidance)
    let decoded = try JSONDecoder().decode(HealthProfile.self, from: encoded)
    try healthExpect(decoded == guidance, "全部手动字段 Codable 往返")
    let emptyData = try JSONEncoder().encode(HealthProfile())
    try healthExpect(try JSONDecoder().decode(HealthProfile.self, from: emptyData) == HealthProfile(), "nil 字段及未选择性别保持缺失")
}

/// 验证手动后备与本次观察合并；参数：无；返回值：无；无效测量不覆盖手动值，医疗开关和活动水平不得被观察重置。
func testHealthProfileMerge() throws {
    let manual = HealthProfile(heightCM: 165, weightKG: 60, age: 30, sex: .female, activity: .high, requiresProfessionalGuidance: true)
    let observed = HealthProfile(heightCM: 170, weightKG: 65, age: 32, sex: .male)
    let merged = manual.mergingHealth(observed)
    try healthExpect(merged.heightCM == 170 && merged.weightKG == 65 && merged.age == 32 && merged.sex == .male, "有效观察覆盖手动数值")
    try healthExpect(merged.activity == .high && merged.requiresProfessionalGuidance, "手动活动水平和医疗开关保留")
    try healthExpect(manual.heightCM == 165 && manual.age == 30, "合并不修改手动原件")
    try healthExpect(manual.mergingHealth(HealthProfile()) == manual, "无观察时完整使用手动后备")
    let invalid = HealthProfile(heightCM: .nan, weightKG: 0, age: -1)
    try healthExpect(manual.mergingHealth(invalid) == manual, "无效观察使用手动后备")
    let minor = manual.mergingHealth(HealthProfile(age: 16))
    try healthExpect(minor.age == 16 && minor.recommendation == nil, "真实未成年年龄不能被手动年龄遮盖")
}

/// 验证最近一晚边界、午夜截断、夏令时及重叠去重；参数：无；返回值：无；只使用虚构日期，不读取系统健康数据。
func testHealthSleepWindow() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = try healthDate("2026-10-20T15:00:00Z")
    guard let window = HealthSleepWindow.interval(now: now, calendar: calendar) else { throw HealthProfileTestFailure(description: "夜间窗口缺失") }
    try healthExpect(window.start == healthDate("2026-10-19T18:00:00Z"), "从昨天 18 点开始")
    try healthExpect(window.end == healthDate("2026-10-20T12:00:00Z"), "下午读取仍截至今天中午")
    let morning = try healthDate("2026-10-20T07:30:00Z")
    try healthExpect(HealthSleepWindow.interval(now: morning, calendar: calendar)?.end == morning, "早晨结束不超过现在")
    let midnight = try healthDate("2026-10-20T00:00:00Z")
    try healthExpect(HealthSleepWindow.interval(now: midnight, calendar: calendar)?.duration == 6 * 3600, "午夜只覆盖昨晚六小时")
    let samples = try [
        DateInterval(start: healthDate("2026-10-19T23:00:00Z"), end: healthDate("2026-10-20T07:00:00Z")),
        DateInterval(start: healthDate("2026-10-20T00:00:00Z"), end: healthDate("2026-10-20T02:00:00Z")),
        DateInterval(start: healthDate("2026-10-19T23:00:00Z"), end: healthDate("2026-10-20T07:00:00Z")),
        DateInterval(start: healthDate("2026-10-20T06:00:00Z"), end: healthDate("2026-10-20T08:00:00Z")),
        DateInterval(start: healthDate("2026-10-20T10:00:00Z"), end: healthDate("2026-10-20T13:00:00Z")),
        DateInterval(start: healthDate("2026-10-20T16:00:00Z"), end: healthDate("2026-10-20T17:00:00Z"))
    ]
    let merged = HealthSleepWindow.mergedDuration(samples, within: window)
    try healthExpectClose(merged?.seconds, 11 * 3600, "阶段/来源去重且仅计算窗口内时长")
    try healthExpect(merged?.measuredAt == window.end, "最后样本日期必须裁剪到窗口")
    try healthExpect(HealthSleepWindow.mergedDuration([], within: window) == nil, "无睡眠是 nil，不是零小时")
    let outside = try DateInterval(start: healthDate("2026-10-18T22:00:00Z"), end: healthDate("2026-10-19T08:00:00Z"))
    try healthExpect(HealthSleepWindow.mergedDuration([outside], within: window) == nil, "更早一晚不进入最近睡眠")
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let spring = HealthSleepWindow.interval(now: try healthDate("2026-03-08T20:00:00Z"), calendar: calendar)
    let autumn = HealthSleepWindow.interval(now: try healthDate("2026-11-01T21:00:00Z"), calendar: calendar)
    try healthExpectClose(spring?.duration, 17 * 3600, "春季夏令时日历边界")
    try healthExpectClose(autumn?.duration, 19 * 3600, "秋季夏令时日历边界")
}

/// 验证公历出生日期和公式输入新鲜度；参数：无；返回值：无；不读取系统健康资料，失败抛错。
func testHealthInputDates() throws {
    let now = try healthDate("2026-10-20T12:00:00Z")
    let timeZone = TimeZone(secondsFromGMT: 0)!
    var birth = DateComponents(year: 1996, month: 10, day: 21)
    birth.calendar = Calendar(identifier: .buddhist)
    try healthExpect(HealthProfile.age(from: birth, now: now, timeZone: timeZone) == 29, "HealthKit 出生年月日始终按公历计算")
    birth.day = 20
    try healthExpect(HealthProfile.age(from: birth, now: now, timeZone: timeZone) == 30, "生日当天周岁增加")
    try healthExpect(HealthProfile.age(from: DateComponents(year: 2026, month: 2, day: 30), now: now, timeZone: timeZone) == nil, "无效日期不得自动归一化")
    try healthExpect(HealthProfile.age(from: DateComponents(year: 2030, month: 1, day: 1), now: now, timeZone: timeZone) == nil, "未来出生日期拒绝")
    try healthExpect(HealthProfile.isRecentMeasurement(now.addingTimeInterval(-29 * 86400), now: now, maximumDays: 30), "近期体重可参与公式")
    try healthExpect(!HealthProfile.isRecentMeasurement(now.addingTimeInterval(-31 * 86400), now: now, maximumDays: 30), "过时体重不参与公式")
    try healthExpect(!HealthProfile.isRecentMeasurement(now.addingTimeInterval(-366 * 86400), now: now, maximumDays: 365), "过时身高不参与公式")
    try healthExpect(!HealthProfile.isRecentMeasurement(now.addingTimeInterval(1), now: now, maximumDays: 365), "未来测量不参与公式")
}

try testHealthProfile()
try testHealthProfileMerge()
try testHealthSleepWindow()
try testHealthInputDates()
print("HealthProfile tests passed: formula, eligibility, Codable, manual fallback, sleep overlap and DST")
