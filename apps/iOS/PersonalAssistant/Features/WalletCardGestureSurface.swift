import SwiftUI
import UIKit

/// 定向横滑触摸层；纵向手势直接交还外层滚动视图，点击仍选择卡片。
struct WalletCardGestureSurface: UIViewRepresentable {
    let canSwipe: Bool
    let select: () -> Void
    let reveal: (Bool) -> Void

    /// 创建协调器；参数：无；返回值：保存最新回调并管理手势方向的协调器。
    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }
    /// 创建透明触摸层；参数：context 为 SwiftUI 生命周期上下文；返回值：带点击与横滑识别器的视图，不包含展示内容。
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap)
        return view
    }
    /// 更新触摸回调；参数：uiView 为既有视图，context 为协调器上下文；返回值：无，保证换卡后手势对应当前卡片。
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.owner = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: WalletCardGestureSurface
        /// 初始化回调持有者；参数：owner 为当前卡片触摸配置；返回值：协调器，无外部副作用。
        init(owner: WalletCardGestureSurface) { self.owner = owner }
        /// 判断是否接管拖动；参数：gestureRecognizer 为待开始识别器；返回值：仅前层卡的明显横向手势可开始，其他方向交给页面滚动。
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return owner.canSwipe && abs(velocity.x) > abs(velocity.y) * 1.5
        }
        /// 允许与外层滚动协调；参数：gestureRecognizer、otherGestureRecognizer 为同时竞争的识别器；返回值：true，外层仍可处理纵向滚动。
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        /// 处理点击；参数：gesture 为点击识别器；返回值：无，选择或收起当前卡片。
        @objc func tap(_ gesture: UITapGestureRecognizer) {
            if gesture.state == .ended { owner.select() }
        }
        /// 完成侧滑；参数：gesture 为定向拖动识别器；返回值：无，超过 32 点左滑展开、右滑收起，不执行删除。
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard gesture.state == .ended else { return }
            let x = gesture.translation(in: gesture.view).x
            if abs(x) > 32 { owner.reveal(x < 0) }
        }
    }
}
