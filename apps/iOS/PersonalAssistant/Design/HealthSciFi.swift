import SwiftUI

/// 健康模块科幻视觉的统一配色；仅用于氛围与强调，不表达健康好坏。
enum HealthSciFi {
    /// 主霓虹青色；参数：无；返回值：强调色。
    static let cyan = Color(red: 0.25, green: 0.92, blue: 0.95)
    /// 辅助紫蓝色；参数：无；返回值：用于色散、辉光与第二光环。
    static let violet = Color(red: 0.52, green: 0.42, blue: 1.0)
    /// 深空底色；参数：无；返回值：页面最底层颜色。
    static let deep = Color(red: 0.01, green: 0.025, blue: 0.05)

    /// 伪随机小数；参数：seed 为任意种子；返回值：[0, 1) 内的确定性数值，保证粒子位置每帧稳定。
    static func frac(_ seed: Double) -> Double {
        let value = sin(seed) * 43758.5453
        return value - value.rounded(.down)
    }
}

/// 深空背景：透视网格地板、漂浮粒子与辉光；开启「减少动态效果」时停在静态画面。
struct HealthSciFiBackground: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 构建背景；参数：无；返回值：以 30 帧刷新的 Canvas 与静态渐变，不接收触摸。
    var body: some View {
        ZStack {
            HealthSciFi.deep
            RadialGradient(colors: [HealthSciFi.cyan.opacity(0.12), .clear], center: .init(x: 0.5, y: 0.05), startRadius: 0, endRadius: 380)
            RadialGradient(colors: [HealthSciFi.violet.opacity(0.10), .clear], center: .init(x: 0.95, y: 0.85), startRadius: 0, endRadius: 360)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                Canvas { ctx, size in drawScene(ctx, size, t) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 绘制网格地板与粒子；参数：ctx 为画布上下文，size 为画布尺寸，t 为秒级时间（静态时为 0）；返回值：无；网格相位由 t 推进形成向前流动的错觉。
    private func drawScene(_ ctx: GraphicsContext, _ size: CGSize, _ t: Double) {
        let horizon = size.height * 0.58
        let cx = size.width / 2
        let cyan = HealthSciFi.cyan
        // 纵向透视线：远端收拢、近端展开，用渐变让远处淡出。
        for i in -8...8 {
            var line = Path()
            line.move(to: CGPoint(x: cx + CGFloat(i) * size.width * 0.03, y: horizon))
            line.addLine(to: CGPoint(x: cx + CGFloat(i) * size.width * 0.38, y: size.height))
            ctx.stroke(line, with: .linearGradient(Gradient(colors: [cyan.opacity(0), cyan.opacity(0.14)]), startPoint: CGPoint(x: cx, y: horizon), endPoint: CGPoint(x: cx, y: size.height)), lineWidth: 0.6)
        }
        // 横向线按 z² 分布并随时间推进，近处更密更亮。
        let phase = (t * 0.12).truncatingRemainder(dividingBy: 1)
        for k in 0..<10 {
            let z = (CGFloat(k) + CGFloat(phase)) / 10
            let y = horizon + (size.height - horizon) * z * z
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(line, with: .color(cyan.opacity(0.03 + 0.14 * Double(z))), lineWidth: 0.6)
        }
        // 粒子向上漂移并轻微闪烁。
        for i in 0..<18 {
            let seed = Double(i) * 12.9898
            let speed = 0.012 + 0.03 * HealthSciFi.frac(seed * 2.3)
            let yRatio = HealthSciFi.frac(HealthSciFi.frac(seed * 1.7 + 3) - t * speed + 1)
            let x = HealthSciFi.frac(seed) * size.width + sin(t * 0.3 + seed) * 8
            let r = 0.8 + 1.4 * HealthSciFi.frac(seed * 3.1)
            let alpha = 0.15 + 0.5 * abs(sin(t * 0.8 + seed))
            let rect = CGRect(x: x, y: yRatio * size.height, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color((i % 3 == 0 ? HealthSciFi.violet : cyan).opacity(alpha)))
        }
    }
}

/// 玻璃全息面板修饰器；开启「降低透明度」时改用不透明底色。
struct HoloPanel: ViewModifier {
    var accent: Color
    var radius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// 包装内容；参数：content 为被修饰视图；返回值：带渐变底、霓虹描边、角标与辉光的视图。
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(LinearGradient(
                    colors: reduceTransparency
                        ? [Color(white: 0.10), Color(white: 0.05)]
                        : [accent.opacity(0.08), accent.opacity(0.02), .black.opacity(0.35)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay { shape.strokeBorder(LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.08), accent.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1) }

    }
}

/// 入场动画：上移并去模糊；开启「减少动态效果」时直接显示。
struct HoloAppear: ViewModifier {
    var delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    /// 包装内容；参数：content 为被修饰视图；返回值：首次出现时错峰入场的视图。
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .blur(radius: shown ? 0 : 3)
            .onAppear {
                if reduceMotion { shown = true } else { withAnimation(.spring(duration: 0.8, bounce: 0.25).delay(delay)) { shown = true } }
            }
    }
}

/// 滚动 3D 倾斜：靠近屏幕边缘的内容向后倾斜并淡出；减少动态效果时不生效。
struct HoloScroll: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 包装内容；参数：content 为被修饰视图；返回值：随滚动位置变化的视图。
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.scrollTransition(.interactive) { view, phase in
                view
                    .rotation3DEffect(.degrees(phase.value * -12), axis: (1, 0, 0), perspective: 0.5)
                    .opacity(1 - abs(phase.value) * 0.45)
                    .scaleEffect(1 - abs(phase.value) * 0.06)
            }
        }
    }
}

extension View {
    /// 套用玻璃全息面板；参数：accent 为描边与辉光色，radius 为圆角；返回值：面板化视图。
    func holoPanel(_ accent: Color = HealthSciFi.cyan, radius: CGFloat = 20) -> some View {
        modifier(HoloPanel(accent: accent, radius: radius))
    }
    /// 套用错峰入场；参数：delay 为延迟秒数；返回值：入场动画视图。
    func holoAppear(_ delay: Double = 0) -> some View { modifier(HoloAppear(delay: delay)) }
    /// 套用滚动 3D 倾斜；参数：无；返回值：随滚动变形的视图。
    func holoScroll() -> some View { modifier(HoloScroll()) }
}

/// 可动画的数字文本；通过 animatableData 逐帧插值，实现从旧值滚动到新值。
struct CountingText: View, Animatable {
    var value: Double
    var decimals: Int

    /// 动画插值数据；参数：无；返回值：当前显示的数值。
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    /// 构建文本；参数：无；返回值：按 decimals 最多保留小数位的数字。
    var body: some View { Text(value.formatted(.number.precision(.fractionLength(0...decimals)))) }
}

/// 滚动计数数字；缺失值显示 —，减少动态效果时直接显示实测值。
struct HoloNumber: View {
    let value: Double?
    var decimals = 1
    var font: Font
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0.0

    /// 构建数字；参数：无；返回值：随实测值变化而计数的等宽数字。
    var body: some View {
        Group {
            if let value, value.isFinite {
                CountingText(value: reduceMotion ? value : shown, decimals: decimals)
            } else {
                Text("—")
            }
        }
        .font(font).monospacedDigit()
        .onAppear(perform: animate)
        .onChange(of: value) { _, _ in animate() }
    }

    /// 触发计数动画；参数：无；返回值：无；无有效值时保持原状。
    private func animate() {
        guard let value, value.isFinite else { return }
        if reduceMotion { shown = value } else { withAnimation(.easeOut(duration: 1.1)) { shown = value } }
    }
}

/// 区块标题：霓虹竖条加字距标题。
struct HoloTitle: View {
    let title: String
    var symbol: String?

    /// 构建标题；参数：无；返回值：带发光竖条与可选图标的标题行。
    var body: some View {
        HStack(spacing: 10) {
            Capsule().fill(HealthSciFi.cyan).frame(width: 3, height: 20).shadow(color: HealthSciFi.cyan, radius: 5)
            if let symbol { Image(systemName: symbol).foregroundStyle(HealthSciFi.cyan) }
            Text(title).font(.title3.bold()).tracking(1.2).foregroundStyle(.white)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 持续脉冲的状态点。
struct HoloPulseDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    /// 构建状态点；参数：无；返回值：中心实点加向外扩散的光圈。
    var body: some View {
        ZStack {
            Circle().stroke(HealthSciFi.cyan, lineWidth: 1).scaleEffect(pulse ? 2.6 : 1).opacity(pulse ? 0 : 0.9)
            Circle().fill(HealthSciFi.cyan)
        }
        .frame(width: 7, height: 7)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityHidden(true)
    }
}

/// 发光胶囊按钮样式；按下缩放，空闲时呼吸发光。
struct HoloButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glow = false

    /// 构建按钮外观；参数：configuration 为系统按钮配置；返回值：渐变胶囊与辉光样式。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline).foregroundStyle(.black)
            .padding(.vertical, 14).frame(maxWidth: .infinity)
            .background(Capsule().fill(LinearGradient(colors: [HealthSciFi.cyan, HealthSciFi.cyan.opacity(0.65)], startPoint: .leading, endPoint: .trailing)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.5), lineWidth: 1))
            .shadow(color: HealthSciFi.cyan.opacity(glow ? 0.5 : 0.2), radius: glow ? 12 : 6)
            .opacity(isEnabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { glow = true }
            }
    }
}

/// 连接线形状；参数 from、to 为起止点；返回值：两点间直线，可配合 trim 做描绘动画。
struct HoloConnector: Shape {
    var from: CGPoint
    var to: CGPoint

    /// 生成路径；参数：rect 为绘制区域（未使用）；返回值：from 到 to 的线段。
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        return p
    }
}

/// 读数标注线：从面板边缘逐段画向身体部位，并在终点显示脉冲光点；每次出现时重新描绘。
struct HoloCalloutLine: View {
    var from: CGPoint
    var to: CGPoint
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0

    /// 构建标注线；参数：无；返回值：虚线、终点光环与脉冲点，纯装饰。
    var body: some View {
        ZStack {
            HoloConnector(from: from, to: to)
                .trim(from: 0, to: drawn)
                .stroke(HealthSciFi.cyan.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            Circle().stroke(HealthSciFi.cyan.opacity(0.6), lineWidth: 1)
                .frame(width: 16, height: 16).position(to).opacity(drawn)
            HoloPulseDot().position(to).opacity(drawn)
        }
        .onAppear {
            if reduceMotion { drawn = 1 } else { withAnimation(.easeOut(duration: 0.7).delay(0.15)) { drawn = 1 } }
        }
        .accessibilityHidden(true)
    }
}

/// 轮播进度条；出现时在 duration 秒内由左向右线性填满，重建视图即重新计时。
struct HoloProgress: View {
    var duration: Double
    @State private var fill: CGFloat = 0

    /// 构建进度条；参数：无；返回值：贴底的 3pt 半透明条。
    var body: some View {
        Rectangle().fill(.black.opacity(0.35))
            .frame(height: 3)
            .scaleEffect(x: fill, anchor: .leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .onAppear { withAnimation(.linear(duration: duration)) { fill = 1 } }
    }
}
