import Foundation

/// 仅用于成年人维持体重的估算结果；单位均为千卡/日，不包含减重缺口或治疗建议。
nonisolated struct CalorieRecommendation: Equatable, Sendable {
    let calories: Double
    let basalCalories: Double
    let activityMultiplier: Double
}

/// 可手动补全的本机健康资料；缺失数据保持 nil，生理性别不推断。
nonisolated struct HealthProfile: Codable, Equatable, Sendable {
    enum Sex: String, Codable, CaseIterable, Identifiable, Sendable {
        case female, male, unspecified

        /// 提供枚举稳定标识；参数：无；返回值：持久化原始值。
        var id: String { rawValue }
        /// 提供公式性别选项名称；参数：无；返回值：中文标题，不代表性别认同。
        var title: String {
            switch self {
            case .female: return "女性"
            case .male: return "男性"
            case .unspecified: return "未选择"
            }
        }
    }

    enum Activity: String, Codable, CaseIterable, Identifiable, Sendable {
        case sedentary, light, moderate, high

        /// 提供枚举稳定标识；参数：无；返回值：持久化原始值。
        var id: String { rawValue }
        /// 提供活动水平名称；参数：无；返回值：中文标题。
        var title: String {
            switch self {
            case .sedentary: return "久坐"
            case .light: return "轻度活动"
            case .moderate: return "中度活动"
            case .high: return "高强度活动"
            }
        }
        /// 返回常用维持热量活动系数；参数：无；返回值：1.2、1.375、1.55 或 1.725，不叠加运动消耗。
        var multiplier: Double {
            switch self {
            case .sedentary: return 1.2
            case .light: return 1.375
            case .moderate: return 1.55
            case .high: return 1.725
            }
        }
    }

    var heightCM: Double?
    var weightKG: Double?
    var age: Int?
    var sex: Sex
    var activity: Activity
    var requiresProfessionalGuidance: Bool

    /// 创建资料；参数：heightCM 为厘米、weightKG 为千克、age 为周岁，均可缺失；sex 为公式采用的生理性别，默认未知；activity 为活动水平；requiresProfessionalGuidance 表示孕期、哺乳或特殊医疗指导；返回值：资料，不在初始化时丢弃原始输入。
    init(heightCM: Double? = nil, weightKG: Double? = nil, age: Int? = nil, sex: Sex = .unspecified, activity: Activity = .sedentary, requiresProfessionalGuidance: Bool = false) {
        self.heightCM = heightCM
        self.weightKG = weightKG
        self.age = age
        self.sex = sex
        self.activity = activity
        self.requiresProfessionalGuidance = requiresProfessionalGuidance
    }

    /// 列出无法估算的原因；参数：无；返回值：缺失字段或适用范围提示；18…80 岁、100…250 厘米、30…350 千克且数值有限才适用。
    var missingRequirements: [String] {
        var requirements: [String] = []
        if requiresProfessionalGuidance { requirements.append("孕期、哺乳期或特殊医疗情况需专业指导") }
        if !Self.validHeight(heightCM) { requirements.append(heightCM == nil ? "身高" : "身高需为 100–250 厘米") }
        if !Self.validWeight(weightKG) { requirements.append(weightKG == nil ? "体重" : "体重需为 30–350 千克") }
        if let age {
            if !(18...80).contains(age) { requirements.append("仅适用于 18–80 岁成年人") }
        } else { requirements.append("年龄") }
        if sex == .unspecified { requirements.append("公式所需的生理性别") }
        return requirements
    }

    /// 按 Mifflin–St Jeor 估算维持热量；参数：无；返回值：基础代谢与活动系数乘积；资料缺失、超出适用范围或需专业指导时返回 nil；不生成减脂目标。
    var recommendation: CalorieRecommendation? {
        guard missingRequirements.isEmpty, let heightCM, let weightKG, let age else { return nil }
        let sexConstant: Double
        switch sex {
        case .female: sexConstant = -161
        case .male: sexConstant = 5
        case .unspecified: return nil
        }
        let basal = 10 * weightKG + 6.25 * heightCM - 5 * Double(age) + sexConstant
        guard basal.isFinite, basal > 0 else { return nil }
        return CalorieRecommendation(calories: basal * activity.multiplier, basalCalories: basal, activityMultiplier: activity.multiplier)
    }

    /// 将本次健康读取覆盖到手动资料副本；参数：observed 为当前读取值，缺失或无效测量使用手动后备；返回值：合并资料，保留手动活动与专业指导开关；不要持久化该副本以免授权改变后沿用旧读取值。
    func mergingHealth(_ observed: HealthProfile) -> HealthProfile {
        var merged = self
        if Self.validHeight(observed.heightCM) { merged.heightCM = observed.heightCM }
        if Self.validWeight(observed.weightKG) { merged.weightKG = observed.weightKG }
        // 年龄即使超出成人适用范围也必须采用，防止用手动年龄绕过适用性判断。
        if let age = observed.age, (0...130).contains(age) { merged.age = age }
        if observed.sex != .unspecified { merged.sex = observed.sex }
        return merged
    }

    /// 从 HealthKit 公历出生日期计算周岁；参数：birth 为公历年月日，now 为当前时刻，timeZone 为用户时区；返回值：0…130 周岁，缺失、未来或无效日期为 nil；不受系统佛历等显示日历影响。
    static func age(from birth: DateComponents, now: Date, timeZone: TimeZone = .current) -> Int? {
        guard let year = birth.year, let month = birth.month, let day = birth.day else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components), date <= now,
              calendar.dateComponents([.year, .month, .day], from: date) == components,
              let age = calendar.dateComponents([.year], from: date, to: now).year,
              (0...130).contains(age) else { return nil }
        return age
    }

    /// 判断测量是否适合当次公式；参数：measuredAt 为实际测量日期，now 为读取时刻，maximumDays 为允许的最大日龄且须非负；返回值：日期不在未来且未超过最大日龄时 true；只用于输入新鲜度，不隐藏历史指标。
    static func isRecentMeasurement(_ measuredAt: Date, now: Date, maximumDays: Int) -> Bool {
        guard maximumDays >= 0, measuredAt <= now else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let earliest = calendar.date(byAdding: .day, value: -maximumDays, to: now) else { return false }
        return measuredAt >= earliest
    }

    /// 验证用于成人公式的身高；参数：value 为可空厘米值；返回值：有限且处于 100…250 时为 true。
    static func validHeight(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value.isFinite && (100...250).contains(value)
    }
    /// 验证用于成人公式的体重；参数：value 为可空千克值；返回值：有限且处于 30…350 时为 true。
    static func validWeight(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value.isFinite && (30...350).contains(value)
    }
}

/// 界面负责格式化数值；nil 表示没有可读取样本，不能显示为零。
nonisolated struct HealthMetric: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let value: Double?
    let unit: String
    let measuredAt: Date?
}

nonisolated struct HealthSnapshot: Equatable, Sendable {
    let profile: HealthProfile
    let metrics: [HealthMetric]
    let readAt: Date
}

/// 纯日历及区间计算，供 HealthKit 读取及 Foundation 测试共用。
nonisolated enum HealthSleepWindow {
    /// 计算最近一晚范围；参数：now 为读取时刻，calendar 为用户本地日历；返回值：昨天 18:00 到今天 12:00，结束不超过 now；日历无法构建边界时返回 nil。
    static func interval(now: Date, calendar: Calendar = .current) -> DateInterval? {
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: yesterday),
              let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: today) else { return nil }
        return DateInterval(start: start, end: min(noon, now))
    }

    /// 裁剪并合并睡眠区间，消除阶段和不同来源重叠；参数：intervals 仅含已睡眠样本，window 为允许的夜间范围；返回值：去重后的秒数及最后有效结束日期，无正时长样本返回 nil。
    static func mergedDuration(_ intervals: [DateInterval], within window: DateInterval) -> (seconds: TimeInterval, measuredAt: Date)? {
        // 转换回调：输入原始区间，输出窗口内的正时长交集，过滤无交集样本。
        let clipped = intervals.compactMap { interval -> DateInterval? in
            let start = max(interval.start, window.start)
            let end = min(interval.end, window.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start < $1.start } // 排序回调：按开始日期升序，返回比较结果。
        guard var current = clipped.first else { return nil }
        var total: TimeInterval = 0
        for interval in clipped.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                total += current.duration
                current = interval
            }
        }
        return (total + current.duration, current.end)
    }
}

/// 本机手动资料仓库；以服务地址与账户 ID 组成的 owner 精确隔离，不保存任何 HealthKit 样本、不联网。
@MainActor
enum HealthProfileStore {
    /// 读取手动资料；参数：owner 为非空账户作用域；返回值：资料，缺失、文件不可读或格式损坏时返回 nil；无网络与写入副作用。
    static func load(owner: String) -> HealthProfile? {
        guard !owner.isEmpty else { return nil }
        do { return try readProfiles(at: storageURL())[owner] } catch { return nil }
    }

    /// 严格捕获指定空间资料；参数：owner 为非空本机作用域；返回值：已有资料或确实不存在时的 nil；读取或解码失败抛错，避免备份将损坏误作空数据。
    static func capture(owner: String) throws -> HealthProfile? {
        guard !owner.isEmpty else { throw CocoaError(.fileReadInvalidFileName) }
        return try readProfiles(at: storageURL())[owner]
    }

    /// 保存手动资料；参数：profile 仅含用户填写数据，owner 为非空账户作用域；返回值：无；原子写入本机受保护文件，磁盘或编码错误抛出，不覆盖损坏文件。
    static func save(_ profile: HealthProfile, owner: String) throws {
        guard !owner.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = try storageURL()
        var profiles = try readProfiles(at: url)
        profiles[owner] = profile
        try writeProfiles(profiles, to: url)
    }

    /// 删除指定账户手动资料；参数：owner 为非空账户作用域；返回值：无；不存在时无操作，磁盘错误抛出，其他账户保持不变。
    static func remove(owner: String) throws {
        guard !owner.isEmpty else { return }
        let url = try storageURL()
        var profiles = try readProfiles(at: url)
        guard profiles.removeValue(forKey: owner) != nil else { return }
        try writeProfiles(profiles, to: url)
    }

    /// 构造本机私有文件位置；参数：无；返回值：Application Support 下资料路径；无可用目录时抛错，不创建文件。
    private static func storageURL() throws -> URL {
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return root.appendingPathComponent("LocalHealthProfiles", isDirectory: true).appendingPathComponent("manual-profiles.json")
    }

    /// 解码账户资料字典；参数：url 为应用私有文件；返回值：已有资料，文件不存在时为空；解码及其他文件错误抛出，防止保存覆盖原数据。
    private static func readProfiles(at url: URL) throws -> [String: HealthProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: HealthProfile].self, from: Data(contentsOf: url))
    }

    /// 写入排除备份的私有文件；参数：profiles 为各账户手动资料、url 为应用私有路径；返回值：无；iOS 使用完整文件保护，写入及备份排除失败抛出。
    private static func writeProfiles(_ profiles: [String: HealthProfile], to url: URL) throws {
        var directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let data = try JSONEncoder().encode(profiles)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        var file = url
        try file.setResourceValues(values)
    }
}
