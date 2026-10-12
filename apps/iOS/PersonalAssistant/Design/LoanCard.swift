import SwiftUI

/// 贷款页面统一卡片；Content 为任意内容视图，布局使用统一边距与圆角，随系统切换深浅色。
struct LoanCard<Content: View>: View {
    private let content: Content

    /// 创建内容卡片；参数：content 为无输入、返回 Content 的视图构造回调；返回值：卡片，无业务副作用。
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    /// 构建贷款卡片；参数：无；返回值：复用共享尺度的普通内容卡片，无业务副作用。
    var body: some View { ContentCard { content } }
}
