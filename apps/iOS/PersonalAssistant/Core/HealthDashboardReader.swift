import Foundation
import HealthKit
import Observation

/// 仅读取本机 HealthKit；构造时不访问健康数据，不请求写权限，不上传任何样本。
@MainActor
@Observable
final class HealthDashboardReader {
    private(set) var snapshot: HealthSnapshot?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// 判断设备是否提供 HealthKit；参数：无；返回值：设备能力，不代表任何读取授权状态。
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    @ObservationIgnored private let health = HKHealthStore()

    /// 创建读取器；参数：无；返回值：空状态读取器；无查询、授权弹窗或网络副作用。
    init() {}

    /// 按调用者明确动作刷新健康快照；参数：requestAuthorization 仅在用户点击连接/授权时为 true，后续刷新必须为 false；返回值：无；授权仅请求读取；失败通过 errorMessage 表示，取消不发布半成品，HealthKit 无数据不被解释为拒绝授权。
    func refresh(requestAuthorization: Bool) async {
        guard !isLoading else { return }
        guard isAvailable else {
            snapshot = nil
            errorMessage = "当前设备不支持健康数据"
            return
        }
        isLoading = true
        errorMessage = nil
        // 每次刷新清除旧快照，撤销读取权限或切换作用域后不沿用以前可见的数值。
        snapshot = nil
        defer { isLoading = false }
        do {
            try Task.checkCancellation()
            if requestAuthorization {
                try await health.requestAuthorization(toShare: [], read: readTypes)
                try Task.checkCancellation()
            }
            let now = Date()
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            var metrics: [HealthMetric] = []
            var failures: [String] = []
            var profile = HealthProfile()
            for spec in Self.quantitySpecs {
                try Task.checkCancellation()
                do {
                    let result = try await readQuantity(spec, today: today, now: now)
                    metrics.append(spec.metric(value: result?.value, measuredAt: result?.date))
                    // 历史测量仍在指标中展示日期，但公式仅采用近期且范围有效的体重/身高，否则让手动资料补足。
                    if let result, spec.id == "height", HealthProfile.validHeight(result.value), HealthProfile.isRecentMeasurement(result.date, now: now, maximumDays: 365) { profile.heightCM = result.value }
                    if let result, spec.id == "weight", HealthProfile.validWeight(result.value), HealthProfile.isRecentMeasurement(result.date, now: now, maximumDays: 30) { profile.weightKG = result.value }
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    metrics.append(spec.metric(value: nil, measuredAt: nil))
                    if !Self.isNoData(error) { failures.append(spec.title) }
                }
            }
            // 特征数据不会提供可公开判断的读取权限；未知或缺失不使用默认性别，也不推断用户拒绝。
            do {
                let birth = try health.dateOfBirthComponents()
                profile.age = HealthProfile.age(from: birth, now: now, timeZone: calendar.timeZone)
            } catch {
                if !Self.isNoData(error) { failures.append("出生日期") }
            }
            do {
                switch try health.biologicalSex().biologicalSex {
                case .female: profile.sex = .female
                case .male: profile.sex = .male
                default: profile.sex = .unspecified
                }
            } catch {
                if !Self.isNoData(error) { failures.append("生理性别") }
            }
            metrics.append(HealthMetric(id: "age", title: "年龄", symbol: "person.crop.circle", value: profile.age.map(Double.init), unit: "岁", measuredAt: nil))
            do {
                metrics.append(try await readSleep(now: now, calendar: calendar))
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                metrics.append(Self.sleepMetric(value: nil, measuredAt: nil))
                if !Self.isNoData(error) { failures.append("睡眠") }
            }
            do {
                metrics.append(try await readWorkouts(today: today, now: now))
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                metrics.append(Self.workoutMetric(value: nil, measuredAt: nil))
                if !Self.isNoData(error) { failures.append("训练") }
            }
            try Task.checkCancellation()
            snapshot = HealthSnapshot(profile: profile, metrics: metrics, readAt: now)
            if !failures.isEmpty {
                errorMessage = "部分数据读取失败（\(failures.joined(separator: "、"))），请解锁设备后重试"
            }
        } catch is CancellationError {
            errorMessage = "健康数据读取已取消"
        } catch {
            errorMessage = Task.isCancelled ? "健康数据读取已取消" : "健康数据读取失败：\(error.localizedDescription)"
        }
    }

    /// 汇总所需读取类型；参数：无；返回值：只读对象集合，包含特征、数量、睡眠及训练，不包含任何写入类型。
    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        for spec in Self.quantitySpecs { types.insert(HKQuantityType(spec.identifier)) }
        types.insert(HKObjectType.characteristicType(forIdentifier: .dateOfBirth)!)
        types.insert(HKObjectType.characteristicType(forIdentifier: .biologicalSex)!)
        types.insert(HKCategoryType(.sleepAnalysis))
        types.insert(HKObjectType.workoutType())
        return types
    }

    /// 数量项目定义；daily 表示本地今天系统汇总，否则读取最近实际样本。
    private struct QuantitySpec {
        let id: String
        let title: String
        let symbol: String
        let identifier: HKQuantityTypeIdentifier
        let unit: HKUnit
        let displayUnit: String
        var daily = false
        var scale: Double = 1

        /// 构造界面指标；参数：value 为 HealthKit 单位转换后数值，measuredAt 为最近实际样本日期；返回值：应用显示倍率后的指标，缺失保持 nil。
        func metric(value: Double?, measuredAt: Date?) -> HealthMetric {
            // 映射回调：输入原始数值，输出展示单位数值；不进行四舍五入或缺失值填零。
            HealthMetric(id: id, title: title, symbol: symbol, value: value.map { $0 * scale }, unit: displayUnit, measuredAt: measuredAt)
        }
    }

    /// 提供完整健康项目目录；参数：无；返回值：稳定 ID、系统单位及累计/最新查询方式；百分比读取 0…1 后转为 0…100。
    private static var quantitySpecs: [QuantitySpec] {
        [
            QuantitySpec(id: "height", title: "身高", symbol: "ruler", identifier: .height, unit: .meterUnit(with: .centi), displayUnit: "厘米"),
            QuantitySpec(id: "weight", title: "体重", symbol: "scalemass", identifier: .bodyMass, unit: .gramUnit(with: .kilo), displayUnit: "千克"),
            QuantitySpec(id: "bmi", title: "身体质量指数", symbol: "figure.stand", identifier: .bodyMassIndex, unit: .count(), displayUnit: ""),
            QuantitySpec(id: "bodyFat", title: "体脂率", symbol: "figure", identifier: .bodyFatPercentage, unit: .percent(), displayUnit: "%", scale: 100),
            QuantitySpec(id: "leanMass", title: "去脂体重", symbol: "figure.strengthtraining.traditional", identifier: .leanBodyMass, unit: .gramUnit(with: .kilo), displayUnit: "千克"),
            QuantitySpec(id: "steps", title: "今日步数", symbol: "figure.walk", identifier: .stepCount, unit: .count(), displayUnit: "步", daily: true),
            QuantitySpec(id: "activeEnergy", title: "今日活动能量", symbol: "flame", identifier: .activeEnergyBurned, unit: .kilocalorie(), displayUnit: "千卡", daily: true),
            QuantitySpec(id: "restingEnergy", title: "今日静息能量", symbol: "bed.double", identifier: .basalEnergyBurned, unit: .kilocalorie(), displayUnit: "千卡", daily: true),
            QuantitySpec(id: "walkingDistance", title: "今日步行与跑步距离", symbol: "figure.walk", identifier: .distanceWalkingRunning, unit: .meterUnit(with: .kilo), displayUnit: "公里", daily: true),
            QuantitySpec(id: "flights", title: "今日爬楼层数", symbol: "figure.stairs", identifier: .flightsClimbed, unit: .count(), displayUnit: "层", daily: true),
            QuantitySpec(id: "exerciseMinutes", title: "今日锻炼时间", symbol: "figure.run", identifier: .appleExerciseTime, unit: .minute(), displayUnit: "分钟", daily: true),
            QuantitySpec(id: "standMinutes", title: "今日站立时间", symbol: "figure.stand", identifier: .appleStandTime, unit: .minute(), displayUnit: "分钟", daily: true),
            QuantitySpec(id: "heartRate", title: "心率", symbol: "heart", identifier: .heartRate, unit: .count().unitDivided(by: .minute()), displayUnit: "次/分"),
            QuantitySpec(id: "restingHeartRate", title: "静息心率", symbol: "heart.fill", identifier: .restingHeartRate, unit: .count().unitDivided(by: .minute()), displayUnit: "次/分"),
            QuantitySpec(id: "hrv", title: "心率变异性", symbol: "waveform.path.ecg", identifier: .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), displayUnit: "毫秒"),
            QuantitySpec(id: "oxygen", title: "血氧饱和度", symbol: "drop", identifier: .oxygenSaturation, unit: .percent(), displayUnit: "%", scale: 100),
            QuantitySpec(id: "respiratoryRate", title: "呼吸频率", symbol: "lungs", identifier: .respiratoryRate, unit: .count().unitDivided(by: .minute()), displayUnit: "次/分"),
            QuantitySpec(id: "water", title: "今日饮水", symbol: "drop.fill", identifier: .dietaryWater, unit: .literUnit(with: .milli), displayUnit: "毫升", daily: true),
            QuantitySpec(id: "dietaryEnergy", title: "今日膳食能量", symbol: "fork.knife", identifier: .dietaryEnergyConsumed, unit: .kilocalorie(), displayUnit: "千卡", daily: true),
            QuantitySpec(id: "vo2Max", title: "最大摄氧量", symbol: "lungs.fill", identifier: .vo2Max, unit: HKUnit(from: "ml/kg*min"), displayUnit: "毫升/千克/分"),
            QuantitySpec(id: "walkingSpeed", title: "步行速度", symbol: "speedometer", identifier: .walkingSpeed, unit: .meter().unitDivided(by: .second()), displayUnit: "米/秒")
        ]
    }

    /// 查询数量指标；参数：spec 为目录定义、today 为今日本地零时、now 为固定读取时刻；返回值：数值与最近实际样本结束日期，无数据为 nil；查询错误抛出，系统 async 查询响应任务取消。
    private func readQuantity(_ spec: QuantitySpec, today: Date, now: Date) async throws -> (value: Double, date: Date)? {
        let type = HKQuantityType(spec.identifier)
        // 最新样本排除未来记录；日累计允许与今天交叠的历史区间，交给系统按日归档，避免自行叠加多个数据来源。
        let timePredicate = HKQuery.predicateForSamples(withStart: spec.daily ? today : nil, end: now, options: .strictEndDate)
        let predicate = HKSamplePredicate.quantitySample(type: type, predicate: timePredicate)
        let latestQuery = HKSampleQueryDescriptor(predicates: [predicate], sortDescriptors: [SortDescriptor(\HKQuantitySample.endDate, order: .reverse)], limit: 1)
        let latest = try await latestQuery.result(for: health).first
        try Task.checkCancellation()
        guard let latest else { return nil }
        if !spec.daily {
            let value = latest.quantity.doubleValue(for: spec.unit)
            return value.isFinite ? (value, latest.endDate) : nil
        }
        let query = HKStatisticsCollectionQueryDescriptor(predicate: predicate, options: .cumulativeSum, anchorDate: today, intervalComponents: DateComponents(day: 1))
        let collection = try await query.result(for: health)
        try Task.checkCancellation()
        guard let value = collection.statistics(for: today)?.sumQuantity()?.doubleValue(for: spec.unit), value.isFinite else { return nil }
        return (value, latest.endDate)
    }

    /// 读取最近一晚实际睡眠；参数：now 为读取时刻、calendar 为本地日历；返回值：小时与最后睡眠结束日期，无可读睡眠为 nil 指标；排除在床及清醒，裁剪并合并所有来源重叠段；查询错误抛出。
    private func readSleep(now: Date, calendar: Calendar) async throws -> HealthMetric {
        guard let window = HealthSleepWindow.interval(now: now, calendar: calendar) else { return Self.sleepMetric(value: nil, measuredAt: nil) }
        let predicate = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
        let query = HKSampleQueryDescriptor(predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: predicate)], sortDescriptors: [SortDescriptor(\HKCategorySample.startDate)])
        let samples = try await query.result(for: health)
        try Task.checkCancellation()
        let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        // 转换回调：输入睡眠分类样本，仅输出已睡眠且时间有效的区间；清醒、在床和未知类型忽略。
        let intervals = samples.compactMap { sample -> DateInterval? in
            guard asleep.contains(sample.value), sample.endDate > sample.startDate else { return nil }
            return DateInterval(start: sample.startDate, end: sample.endDate)
        }
        let result = HealthSleepWindow.mergedDuration(intervals, within: window)
        return Self.sleepMetric(value: result.map { $0.seconds / 3600 }, measuredAt: result?.measuredAt) // 映射回调：秒转小时，不取整。
    }

    /// 读取今天开始且已结束的训练次数；参数：today 为今日零时，now 为读取时刻；返回值：次数及最后训练结束日期，无可读样本为 nil；查询错误抛出，不将不可见数据当作零次训练。
    private func readWorkouts(today: Date, now: Date) async throws -> HealthMetric {
        let predicate = HKQuery.predicateForSamples(withStart: today, end: now, options: [.strictStartDate, .strictEndDate])
        let query = HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [SortDescriptor(\HKWorkout.endDate, order: .reverse)])
        let samples = try await query.result(for: health)
        try Task.checkCancellation()
        return Self.workoutMetric(value: samples.isEmpty ? nil : Double(samples.count), measuredAt: samples.first?.endDate)
    }

    /// 构造睡眠指标；参数：value 为去重后小时数，measuredAt 为最后睡眠结束日期；返回值：最近一晚指标，缺失保持 nil。
    private static func sleepMetric(value: Double?, measuredAt: Date?) -> HealthMetric {
        HealthMetric(id: "sleep", title: "昨夜睡眠", symbol: "moon.zzz", value: value, unit: "小时", measuredAt: measuredAt)
    }
    /// 构造训练指标；参数：value 为今天训练次数，measuredAt 为最近训练结束日期；返回值：今日训练指标，缺失保持 nil。
    private static func workoutMetric(value: Double?, measuredAt: Date?) -> HealthMetric {
        HealthMetric(id: "workouts", title: "今日训练", symbol: "figure.run", value: value, unit: "次", measuredAt: measuredAt)
    }
    /// 判断系统无数据错误；参数：error 为 HealthKit 错误；返回值：只有 errorNoData 为 true，其他错误必须向界面汇报，不能推断读取权限被拒绝。
    private static func isNoData(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == HKErrorDomain && error.code == HKError.Code.errorNoData.rawValue
    }
}
