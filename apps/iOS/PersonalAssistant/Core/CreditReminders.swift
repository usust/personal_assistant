import Foundation
import UserNotifications

/// 管理当前登录账户的本机还款通知；仅在明确开启时请求权限，刷新财务数据时续排未来提醒。
@MainActor enum CreditReminders {
    private static var revision = UUID()
    private static let storageKey = "creditReminderIdentifiers"

    /// 请求本机通知权限；参数：无；返回值：是否获准；系统错误向上传递，无服务端写入。
    static func authorize() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// 清除本功能通知；参数：无；返回值：无；使正在排程的任务失效，不影响其他通知。
    static func clear() {
        revision = UUID()
        let ids = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// 按最新账户续排提醒；参数：accounts 为当前用户完整的有效账户；返回值：无；最多保留最近 60 次提醒，日期超出当月时取月末，系统错误向上传递。
    static func sync(_ accounts: [FinancialAccount]) async throws {
        clear()
        let generation = revision
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard generation == revision, settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let calendar = Calendar.current
        let now = Date()
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        var requests: [(Date, UNNotificationRequest)] = []
        for account in accounts {
            guard AccountProvider.resolve(type: account.accountType, institution: account.institution).isCredit,
                  let days = account.reminderDays, [0, 1, 3, 7].contains(days) else { continue }
            var anchor = month
            var day = account.repaymentDay ?? 0
            var offsets = Array(0...12)
            if account.institution == "贷款", (Decimal(string: account.loanPrincipal ?? "0") ?? 0) > 0 {
                guard let first = account.loanFirstPaymentDate, !first.isEmpty,
                      let periods = account.loanPeriods, let paid = account.loanPaidPeriods,
                      paid >= 0, paid < periods, periods <= 480 else { continue }
                let firstDate = Values.date(first)
                anchor = calendar.date(from: calendar.dateComponents([.year, .month], from: firstDate))!
                day = calendar.component(.day, from: firstDate)
                // 贷款只排剩余期次，不因跨月重复提醒已还期次，也不在结清后继续提醒。
                let lastPayment = min(periods, account.loanPlan?.lastPaymentPeriod ?? periods)
                offsets = paid < lastPayment ? Array(paid..<lastPayment) : []
            }
            guard (1...31).contains(day) else { continue }
            // 服务端使用 HH:mm；旧数据无时间时回退 10:00，损坏的数据不参与排程。
            // 解析回调将时间分量转换为整数，返回 nil 时丢弃该分量，不产生副作用。
            let time = (account.reminderTime ?? "10:00").split(separator: ":").compactMap { Int($0) }
            guard time.count == 2, (0...23).contains(time[0]), (0...59).contains(time[1]) else { continue }
            for offset in offsets {
                guard let targetMonth = calendar.date(byAdding: .month, value: offset, to: anchor),
                      let range = calendar.range(of: .day, in: .month, for: targetMonth) else { continue }
                var components = calendar.dateComponents([.year, .month], from: targetMonth)
                components.day = min(day, range.count); components.hour = time[0]; components.minute = time[1]
                guard let due = calendar.date(from: components) else { continue }
                for advance in days == 0 ? [0] : [days, 0] {
                    guard let date = calendar.date(byAdding: .day, value: -advance, to: due), date > now else { continue }
                    let content = UNMutableNotificationContent()
                    content.title = account.institution == "贷款" ? "贷款还款提醒" : "信用卡还款提醒"
                    content.body = advance == 0 ? "\(account.name) 今天还款" : "\(account.name) 将于 \(days) 天后还款"
                    content.sound = .default
                    let id = "credit-repayment-\(generation.uuidString)-\(account.id)-\(Int(date.timeIntervalSince1970))"
                    let trigger = UNCalendarNotificationTrigger(dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date), repeats: false)
                    requests.append((date, UNNotificationRequest(identifier: id, content: content, trigger: trigger)))
                }
            }
        }
        // 排序回调以通知日期为输入、先后关系为输出；为多卡共享系统通知额度保留空间。
        let selected = requests.sorted { $0.0 < $1.0 }.prefix(60)
        // 标识提取回调接收排程项、返回通知 ID，保存后可在退出时精确清理。
        UserDefaults.standard.set(selected.map { $0.1.identifier }, forKey: storageKey)
        for (_, request) in selected {
            guard generation == revision else { return }
            try await center.add(request)
            // 退出或另一轮刷新可能发生于系统调用期间，旧请求不得跨会话残留。
            if generation != revision {
                center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
                return
            }
        }
    }
}
