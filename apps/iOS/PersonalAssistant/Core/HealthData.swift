import Foundation

nonisolated struct HealthDay: Codable, Identifiable {
    var id: Int?
    let date: String
    let timezone: String
    var steps: Double?
    var active_energy: Double?
    var distance: Double?
    var resting_heart_rate: Double?
    var weight: Double?
    var updated_at: String?
    /// 判断当天是否至少读到一个指标；参数：无；返回值：包含显式零值时也为 true，无副作用。
    var hasData: Bool { [steps, active_energy, distance, resting_heart_rate, weight].contains { $0 != nil } }
}
nonisolated struct HealthReport: Decodable, Identifiable {
    let id: Int
    let content: String
    let created_at: String
}
nonisolated struct HealthOverview: Decodable {
    let days: [HealthDay]
    let reports: [HealthReport]
}

nonisolated struct HealthSyncReceipt: Decodable { let synced: Int }

extension APIClient {
    /// 上传完整日快照并验证服务器回执；参数：days 为包含至少一个有效指标的 1–30 天数据；返回值：服务端确认的日期数；空数据不发请求，网络或回执不符抛错。
    func uploadHealth(_ days: [HealthDay]) async throws -> Int {
        guard !days.isEmpty, days.count <= 30, days.contains(where: { $0.hasData }) else {
            throw APIError(status: 0, message: "未读取到健康数据，本次未上传。请先在 iPhone 健康 App 确认有记录，并检查本应用的读取权限。")
        }
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(days))
        let receipt: HealthSyncReceipt = try await request("/health-management/sync", method: "POST", body: ["days": json])
        guard receipt.synced == days.count else {
            throw APIError(status: 0, message: "服务器同步回执不完整，请刷新核对后重试。")
        }
        return receipt.synced
    }
}
