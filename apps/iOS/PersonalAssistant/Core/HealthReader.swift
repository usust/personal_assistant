import Foundation
import HealthKit

@MainActor
final class HealthReader {
    private let health = HKHealthStore()
    private let metrics: [(HKQuantityTypeIdentifier, HKUnit, HKStatisticsOptions)] = [
        (.stepCount, .count(), .cumulativeSum),
        (.activeEnergyBurned, .kilocalorie(), .cumulativeSum),
        (.distanceWalkingRunning, .meter(), .cumulativeSum),
        (.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), .discreteAverage),
        (.bodyMass, .gramUnit(with: .kilo), .discreteAverage)
    ]
    /// 读取含今天在内的最近 30 个自然日；参数：progress 接收已完成的日期数（1–30），只更新 UI；返回值：每日汇总，今天截至读取时刻；仅请求读取权限，真实查询错误抛出。
    func read(progress: (Int) -> Void) async throws -> [HealthDay] {
        guard HKHealthStore.isHealthDataAvailable() else { throw APIError(status: 0, message: "当前设备不支持健康数据，请在 iPhone 上使用。") }
        let types = Set(metrics.map { HKQuantityType($0.0) })
        try await health.requestAuthorization(toShare: [], read: types)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var days: [HealthDay] = []
        for (index, interval) in Self.intervals(now: now, timezone: calendar.timeZone).enumerated() {
            try Task.checkCancellation()
            let start = interval.start
            let end = interval.end
            var values: [Double?] = []
            for metric in metrics { values.append(try await value(metric, start: start, end: end)) }
            days.append(HealthDay(date: formatter.string(from: start), timezone: calendar.timeZone.identifier, steps: values[0], active_energy: values[1], distance: values[2], resting_heart_rate: values[3], weight: values[4]))
            progress(index + 1)
        }
        return days
    }
    /// 构造最近 30 日查询区间；参数：now 为本次读取固定时刻，timezone 为设备时区；返回值：今天至前 29 天的区间，兼容夏令时，无副作用。
    nonisolated static func intervals(now: Date, timezone: TimeZone) -> [DateInterval] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timezone
        let today = calendar.startOfDay(for: now)
        // 日期映射回调：offset 是距今天的天数；返回对应区间，今天截断到 now，历史日采用日历计算边界。
        return (0..<30).map { offset in
            let start = calendar.date(byAdding: .day, value: -offset, to: today)!
            let end = offset == 0 ? now : calendar.date(byAdding: .day, value: 1, to: start)!
            return DateInterval(start: start, end: end)
        }
    }
    /// 将无样本统计解释为缺失；参数：value 为统计值，error 为 HealthKit 查询错误；返回值：值或 nil；除 errorNoData 外所有错误原样抛出，不把锁屏/授权/数据库故障当空数据。
    nonisolated static func queryValue(_ value: Double?, error: Error?) throws -> Double? {
        if let error {
            let nsError = error as NSError
            if nsError.domain == HKErrorDomain && nsError.code == HKError.Code.errorNoData.rawValue { return nil }
            throw error
        }
        return value
    }
    /// 查询单日单项系统统计，避免自行累加来源样本；参数：metric 为类型/单位/统计方式，start/end 为半开日期区间；返回值：统计数值或 nil；查询错误抛出。
    private func value(_ metric: (HKQuantityTypeIdentifier, HKUnit, HKStatisticsOptions), start: Date, end: Date) async throws -> Double? {
        // 延续回调将 HealthKit 查询桥接到 async；参数 continuation 为一次性返回通道；返回值无，不记录健康内容。
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            // 查询完成回调：query 为查询，result 为统计，error 为错误；返回值无，恰好恢复一次延续。
            let query = HKStatisticsQuery(quantityType: HKQuantityType(metric.0), quantitySamplePredicate: predicate, options: metric.2) { _, result, error in
                let quantity = metric.2 == .cumulativeSum ? result?.sumQuantity() : result?.averageQuantity()
                do { continuation.resume(returning: try Self.queryValue(quantity?.doubleValue(for: metric.1), error: error)) }
                catch { continuation.resume(throwing: error) }
            }
            health.execute(query)
        }
    }
}

