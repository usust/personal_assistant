import SwiftUI
import UIKit
import Combine

/// 一级页面在系统 More 内的导航状态；只管理外层导航栏，不改变页面选择或业务数据。
@MainActor private final class MoreTabNavigationState: ObservableObject {
    @Published var active = false
    private weak var navigation: UINavigationController?
    private weak var host: UIViewController?
    private weak var knownNavigation: UINavigationController?
    private weak var knownHost: UIViewController?
    private var wasHidden = false

    /// 接管已确认的 More 容器；参数：navigation 为外层系统导航，host 为其直属页面控制器；返回值：无，仅暂时隐藏重复导航栏。
    func attach(_ navigation: UINavigationController, host: UIViewController) {
        knownNavigation = navigation
        knownHost = host
        if self.navigation == nil {
            self.navigation = navigation
            self.host = host
            wasHidden = navigation.isNavigationBarHidden
        }
        navigation.setNavigationBarHidden(true, animated: false)
        // 状态回调无输入、返回值无；避开 SwiftUI 更新阶段发布状态，控制器离开时不重新激活旧入口。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.navigation != nil else { return }
            self.active = true
        }
    }

    /// 重新进入一级页面时恢复适配；参数：无；返回值：无，保留弱引用以覆盖 UIKit 背景探针没有重新挂载的返回路径。
    func reactivate() {
        // 恢复回调无输入、返回值无；下一主线程周期核对已完成的导航归属，不操作 More 列表或旧页面。
        DispatchQueue.main.async { [weak self] in
            guard let self, let navigation = self.knownNavigation, let host = self.knownHost,
                  navigation.topViewController === host else { return }
            self.attach(navigation, host: host)
        }
    }

    /// 返回系统 More 列表；参数：animated 为是否允许转场动画；返回值：无，恢复进入前导航状态，不关闭云会话或清空草稿。
    func returnToMore(animated: Bool) {
        let controller = navigation
        restore()
        controller?.popToRootViewController(animated: animated)
    }

    /// 页面不再属于可见 More 层级时释放适配；参数：无；返回值：无，内部 SwiftUI 页面跳转不恢复重复外层栏。
    func restoreIfOutsideMore() {
        guard let navigation else { return }
        // More 内部仍可能使用新的页面宿主；只有离开可见容器或已回到 More 列表才释放，不把二级跳转误判为离开。
        if navigation.view.window == nil || navigation.topViewController === navigation.viewControllers.first { restore() }
    }

    /// 恢复外层导航栏；参数：无；返回值：无，只还原本适配器记录的状态，无业务副作用。
    func restore() {
        navigation?.setNavigationBarHidden(wasHidden, animated: false)
        navigation = nil
        host = nil
        // 生命周期回调无输入、返回值无；离开后取消一级页面的 More 返回按钮。
        DispatchQueue.main.async { [weak self] in self?.active = false }
    }
}

/// 系统 More 容器探针；仅在确认父控制器属于 More 后隐藏外层导航，其他标签与 iPad 保持系统行为。
private struct MoreTabNavigationProbe: UIViewControllerRepresentable {
    let state: MoreTabNavigationState

    /// 创建导航探针；参数：context 为系统生命周期上下文；返回值：透明控制器，不读写业务数据。
    func makeUIViewController(context: Context) -> Controller { Controller(state: state) }

    /// 更新导航归属；参数：controller 为现有探针，context 为生命周期上下文；返回值：无，仅检查公开控制器层级。
    func updateUIViewController(_ controller: Controller, context: Context) { controller.adapt() }

    /// 释放导航适配；参数：controller 为被移除探针，coordinator 为默认协调器；返回值：无，恢复进入前外层导航状态。
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.state.restore() }

    final class Controller: UIViewController {
        let state: MoreTabNavigationState

        /// 创建透明控制器；参数：state 为本页面导航状态；返回值：导航探针，无业务副作用。
        init(state: MoreTabNavigationState) { self.state = state; super.init(nibName: nil, bundle: nil) }

        /// 拒绝 storyboard 构造；参数：coder 为系统解码器；返回值：nil，此控制器仅由 SwiftUI 创建，无副作用。
        required init?(coder: NSCoder) { nil }

        /// 页面出现时检查 More 层级；参数：animated 为系统转场标志；返回值：无，只更新导航外观。
        override func viewWillAppear(_ animated: Bool) { super.viewWillAppear(animated); adapt() }

        /// 挂载后检查导航层级；参数：parent 为父控制器或 nil；返回值：无，未挂载时不改变导航。
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); if parent != nil { adapt() } }

        /// 页面消失后检查外层导航；参数：animated 为系统转场标志；返回值：无，切换标签或返回 More 时恢复原状。
        override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); state.restoreIfOutsideMore() }

        /// 检查并适配重复导航；参数：无；返回值：无，只使用公开的父控制器关系，未确认 More 归属时不操作外层导航。
        func adapt() {
            guard let more = tabBarController?.moreNavigationController else { return }
            var ancestor = parent
            while let current = ancestor {
                if current.parent === more, more.topViewController === current { state.attach(more, host: current); return }
                ancestor = current.parent
            }
        }
    }
}

/// 共用一级导航栈；Content 为业务页面，持续存在的容器统一处理 More 外层导航与二级返回。
struct TabRootNavigation<Content: View>: View {
    private let content: Content
    @StateObject private var state = MoreTabNavigationState()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 创建一级导航栈；参数：content 为无输入、返回 Content 的业务页面回调；返回值：原生导航容器，无业务副作用。
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    /// 构建一级导航；参数：无；返回值：More 内一级提供返回，二级沿用系统返回，减少动态效果时取消返回动画，不改变标题例外。
    var body: some View {
        NavigationStack {
            content.toolbar {
                if state.active {
                    ToolbarItem(placement: .topBarLeading) {
                        // 返回回调无输入、返回值无；只回到系统 More 对象列表，不修改任何业务数据。
                        Button("返回", systemImage: "chevron.left") { state.returnToMore(animated: !reduceMotion) }
                            .labelStyle(.iconOnly).accessibilityLabel("返回更多页面")
                    }
                }
            }
            // 出现回调无输入、返回值无；返回按钮属于本页 toolbar，二级页面自然使用自己的系统返回，不用额外状态缓存可见性。
            .onAppear { state.reactivate() }
        }
        // 探针挂在持续存在的栈上，内部页面切换不会释放外层适配，避免返回一级后丢失按钮。
        .background(MoreTabNavigationProbe(state: state))
    }
}
