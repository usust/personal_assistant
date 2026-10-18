import SwiftUI

/// 共用一级导航栈；Content 为业务页面类型，每个原生标签独立保留自己的导航层级。
struct TabRootNavigation<Content: View>: View {
    private let content: Content

    /// 创建一级导航栈；参数：content 为无输入、返回 Content 的业务页面构造回调；返回值：导航容器，无业务副作用。
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    /// 构建系统导航；参数：无；返回值：独立的原生导航栈；顶层标签不超过五个，不再接管 UIKit More 导航栏或插入自定义返回按钮。
    var body: some View {
        NavigationStack { content }
    }
}
