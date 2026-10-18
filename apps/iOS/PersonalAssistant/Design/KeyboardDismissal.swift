import SwiftUI
import UIKit

/// 在当前应用窗口观察外部点击，统一覆盖导航页、sheet 和全屏编辑页。
struct KeyboardDismissalHost: UIViewRepresentable {
    /// 创建窗口观察视图；参数 context 为 SwiftUI 生命周期上下文；返回值：不参与点击命中的透明视图，进入窗口后安装手势。
    func makeUIView(context: Context) -> KeyboardDismissalView {
        let view = KeyboardDismissalView()
        view.isUserInteractionEnabled = false
        return view
    }

    /// 响应 SwiftUI 更新；参数 uiView 为观察视图，context 为生命周期上下文；返回值：无；窗口绑定由 didMoveToWindow 管理，不重复安装手势。
    func updateUIView(_ uiView: KeyboardDismissalView, context: Context) {}

    /// 释放窗口观察；参数 uiView 为即将销毁的观察视图，coordinator 为系统默认协调器；返回值：无；移除手势，避免残留或重复响应。
    static func dismantleUIView(_ uiView: KeyboardDismissalView, coordinator: ()) {
        uiView.removeDismissalGesture()
    }
}

/// 标记可通过标签或留白获取焦点的整块输入区域，不改变 SwiftUI 的点击分发。
struct KeyboardInputRegion: UIViewRepresentable {
    /// 创建输入区域标记；参数 context 为 SwiftUI 生命周期上下文；返回值：不参与命中测试的透明视图，尺寸由输入组件的背景决定。
    func makeUIView(context: Context) -> KeyboardInputRegionView {
        let view = KeyboardInputRegionView()
        view.isUserInteractionEnabled = false
        return view
    }

    /// 保留布局驱动的标记区域；参数 uiView 为既有标记，context 为生命周期上下文；返回值：无；不主动调整尺寸或焦点。
    func updateUIView(_ uiView: KeyboardInputRegionView, context: Context) {}
}

/// 用公开视图类型识别自定义输入区，避免依赖 SwiftUI 内部视图类名。
final class KeyboardInputRegionView: UIView {}

/// 只结束触摸开始时的编辑对象；不拦截业务点击、不修改草稿，也不跨窗口收起键盘。
final class KeyboardDismissalView: UIView, UIGestureRecognizerDelegate {
    private weak var observedWindow: UIWindow?
    private weak var editingViewAtTouch: UIView?
    private var dismissalGesture: UITapGestureRecognizer?

    /// 跟随所属窗口安装观察手势；参数：无；返回值：无；离开或切换窗口时先解除旧绑定，同一窗口只安装一次。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard observedWindow !== window else { return }
        removeDismissalGesture()
        guard let window else { return }
        let gesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard(_:)))
        // 外部点击同时执行按钮、导航和 SwiftUI 手势；不取消或延迟原控件收到的触摸。
        gesture.cancelsTouchesInView = false
        gesture.delaysTouchesBegan = false
        gesture.delaysTouchesEnded = false
        gesture.delegate = self
        window.addGestureRecognizer(gesture)
        observedWindow = window
        dismissalGesture = gesture
    }

    /// 解除窗口绑定；参数：无；返回值：无；可重复调用，清理手势和触摸开始时的弱引用。
    func removeDismissalGesture() {
        if let dismissalGesture { observedWindow?.removeGestureRecognizer(dismissalGesture) }
        dismissalGesture = nil
        editingViewAtTouch = nil
        observedWindow = nil
    }

    /// 筛选外部点击；参数 gestureRecognizer 为窗口手势，touch 为命中的触摸；返回值：仅窗口内有文本编辑对象、且触摸不在可编辑控件或自定义输入区域内时为 true；不改变焦点。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        editingViewAtTouch = nil
        guard let window = observedWindow, let editingView = firstEditingView(in: window) else { return false }
        // 输入控件的内部子视图也视为输入区域；保留光标定位、文本选择及不同输入框间的连续切换。
        var hitView = touch.view
        while let view = hitView {
            if isEditableInput(view) { return false }
            hitView = view.superview
        }
        // 浮动标签与留白也能聚焦输入；只排除当前命中页面的标记，底层页面不影响 sheet 外部点击。
        if containsInputRegion(at: touch.location(in: window), in: window, controller: owningController(of: touch.view)) { return false }
        editingViewAtTouch = editingView
        return true
    }

    /// 允许原有点击手势同时完成；参数 gestureRecognizer、otherGestureRecognizer 为竞争手势；返回值：true；横滑和纵向拖动仍由原识别器判断，拖动不会被当成外部点击。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    /// 收起外部点击前的键盘；参数 gesture 为已完成的点击手势；返回值：无；同步释放第一响应者，使 SwiftUI FocusState 和浮动标签退出编辑；保留已输入文本。
    @objc private func dismissKeyboard(_ gesture: UITapGestureRecognizer) {
        defer { editingViewAtTouch = nil }
        // 点击可能已打开新面板并转移焦点；此时不再结束新输入框的编辑。
        guard gesture.state == .ended, let editingViewAtTouch,
              editingViewAtTouch.window === observedWindow, editingViewAtTouch.isFirstResponder else { return }
        editingViewAtTouch.resignFirstResponder()
    }

    /// 查找当前窗口内正在编辑的文本控件；参数 root 为搜索起点及其子树；返回值：第一响应者输入视图，未编辑时返回 nil；无副作用。
    private func firstEditingView(in root: UIView) -> UIView? {
        if root.isFirstResponder && isEditableInput(root) { return root }
        for child in root.subviews {
            if let editingView = firstEditingView(in: child) { return editingView }
        }
        return nil
    }

    /// 判断视图能否编辑文本；参数 view 为待检查视图；返回值：系统及 SwiftUI 文本输入控件为 true，只读可选中文本为 false；无副作用。
    private func isEditableInput(_ view: UIView) -> Bool {
        if let textView = view as? UITextView { return textView.isEditable }
        return view is UITextInput
    }

    /// 判断点击是否位于自定义输入区域；参数 point 为窗口坐标，root 为搜索子树，controller 为命中视图所属控制器；返回值：同一页面中未隐藏、未被裁剪的标记包含点击时为 true；无副作用。
    private func containsInputRegion(at point: CGPoint, in root: UIView, controller: UIViewController?) -> Bool {
        guard !root.isHidden, root.alpha > 0.01 else { return false }
        let localPoint = root.convert(point, from: observedWindow)
        if root.clipsToBounds && !root.bounds.contains(localPoint) { return false }
        if root is KeyboardInputRegionView, root.bounds.contains(localPoint), owningController(of: root) === controller { return true }
        for child in root.subviews {
            if containsInputRegion(at: point, in: child, controller: controller) { return true }
        }
        return false
    }

    /// 查找视图所属控制器；参数 view 为命中视图或区域标记，允许 nil；返回值：响应链上的最近控制器，无控制器时为 nil；不加载其他页面或改变焦点。
    private func owningController(of view: UIView?) -> UIViewController? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}
