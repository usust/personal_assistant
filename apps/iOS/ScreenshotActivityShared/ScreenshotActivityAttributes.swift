import ActivityKit
import Foundation

/// 主应用与 Widget 共用的实时活动协议，只传状态，不在锁屏暴露金额、商户或账户。
nonisolated struct ScreenshotActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case processing, posted, review, failed

        /// 显示精简状态；参数：无；返回值：中文状态文案，无副作用。
        var title: String {
            switch self {
            case .processing: return "正在识别"
            case .posted: return "已入账"
            case .review: return "待补全"
            case .failed: return "识别失败"
            }
        }

        /// 选择各状态的系统图标；参数：无；返回值：SF Symbol 名称，无副作用。
        var symbol: String {
            switch self {
            case .processing: return "viewfinder"
            case .posted: return "checkmark.circle.fill"
            case .review: return "exclamationmark.circle.fill"
            case .failed: return "xmark.circle.fill"
            }
        }
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
    }
    var id: String
}
