import SwiftUI

/// 健康参数所关联的身体部位；仅用于示意性展示，不代表医学定位或诊断。
enum BodyOrgan: String, CaseIterable, Identifiable {
    case brain, heart, lungs, liver, stomach, kidneys, gut, frame

    /// 稳定标识；参数：无；返回值：枚举原始值。
    var id: String { rawValue }

    /// 体检报告式的部位名称；参数：无；返回值：简短中文名。
    var title: String {
        switch self {
        case .brain: "脑"
        case .heart: "心脏"
        case .lungs: "肺"
        case .liver: "肝脏"
        case .stomach: "胃"
        case .kidneys: "肾"
        case .gut: "腹部"
        case .frame: "体型"
        }
    }

    /// 选择器图标；参数：无；返回值：SF Symbols 名称。
    var symbol: String {
        switch self {
        case .brain: "brain.head.profile"
        case .heart: "heart.fill"
        case .lungs: "lungs.fill"
        case .liver: "cross.vial.fill"
        case .stomach: "fork.knife"
        case .kidneys: "drop.fill"
        case .gut: "scalemass.fill"
        case .frame: "figure.stand"
        }
    }

    /// 部位中心；参数：无；返回值：以人体高度为 1、中线为 x=0.26 的坐标，用于标注线终点与缩放锚点。
    var center: CGPoint {
        switch self {
        case .brain: CGPoint(x: 0.26, y: 0.045)
        case .heart: CGPoint(x: 0.272, y: 0.265)
        case .lungs: CGPoint(x: 0.305, y: 0.235)
        case .liver: CGPoint(x: 0.215, y: 0.332)
        case .stomach: CGPoint(x: 0.300, y: 0.335)
        case .kidneys: CGPoint(x: 0.318, y: 0.376)
        case .gut: CGPoint(x: 0.26, y: 0.425)
        case .frame: CGPoint(x: 0.335, y: 0.60)
        }
    }
}

/// 成人比例人体与器官的几何形状；坐标系以人体高度为 1、中线 x=0.26，保证任意尺寸等比缩放。
struct BodyShape: Shape {
    enum Part: Hashable { case head, body, ground, ruler, organ(BodyOrgan) }
    var part: Part

    /// 躯干轮廓的左半身三次贝塞尔分段；每项依次为 c1、c2、终点（单位坐标），起点为 `bodyStart`；右半身由其镜像反向生成。
    private static let bodyStart = CGPoint(x: 0.236, y: 0.103)
    private static let bodySegments: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: 0.236, y: 0.115), CGPoint(x: 0.238, y: 0.128), CGPoint(x: 0.240, y: 0.138)),   // 颈
        (CGPoint(x: 0.225, y: 0.148), CGPoint(x: 0.185, y: 0.150), CGPoint(x: 0.150, y: 0.160)),   // 斜方肌
        (CGPoint(x: 0.128, y: 0.160), CGPoint(x: 0.108, y: 0.178), CGPoint(x: 0.108, y: 0.200)),   // 肩
        (CGPoint(x: 0.104, y: 0.245), CGPoint(x: 0.092, y: 0.295), CGPoint(x: 0.082, y: 0.335)),   // 上臂外侧
        (CGPoint(x: 0.074, y: 0.385), CGPoint(x: 0.062, y: 0.435), CGPoint(x: 0.054, y: 0.475)),   // 前臂外侧
        (CGPoint(x: 0.040, y: 0.500), CGPoint(x: 0.044, y: 0.535), CGPoint(x: 0.062, y: 0.545)),   // 手
        (CGPoint(x: 0.080, y: 0.545), CGPoint(x: 0.088, y: 0.515), CGPoint(x: 0.084, y: 0.480)),   // 手内侧
        (CGPoint(x: 0.086, y: 0.430), CGPoint(x: 0.100, y: 0.385), CGPoint(x: 0.112, y: 0.345)),   // 前臂内侧
        (CGPoint(x: 0.120, y: 0.305), CGPoint(x: 0.134, y: 0.270), CGPoint(x: 0.140, y: 0.240)),   // 腋下
        (CGPoint(x: 0.144, y: 0.285), CGPoint(x: 0.146, y: 0.325), CGPoint(x: 0.152, y: 0.360)),   // 胸廓至腰
        (CGPoint(x: 0.160, y: 0.410), CGPoint(x: 0.130, y: 0.450), CGPoint(x: 0.136, y: 0.490)),   // 髋
        (CGPoint(x: 0.128, y: 0.580), CGPoint(x: 0.148, y: 0.650), CGPoint(x: 0.156, y: 0.705)),   // 大腿外侧
        (CGPoint(x: 0.152, y: 0.790), CGPoint(x: 0.172, y: 0.860), CGPoint(x: 0.176, y: 0.930)),   // 小腿外侧
        (CGPoint(x: 0.180, y: 0.955), CGPoint(x: 0.162, y: 0.972), CGPoint(x: 0.150, y: 0.975)),   // 足跟
        (CGPoint(x: 0.185, y: 0.980), CGPoint(x: 0.215, y: 0.980), CGPoint(x: 0.236, y: 0.972)),   // 足底
        (CGPoint(x: 0.240, y: 0.965), CGPoint(x: 0.232, y: 0.945), CGPoint(x: 0.226, y: 0.930)),   // 足背
        (CGPoint(x: 0.222, y: 0.850), CGPoint(x: 0.230, y: 0.780), CGPoint(x: 0.232, y: 0.710)),   // 小腿内侧
        (CGPoint(x: 0.234, y: 0.640), CGPoint(x: 0.250, y: 0.570), CGPoint(x: 0.258, y: 0.510))    // 大腿内侧至会阴
    ]

    /// 生成路径；参数：rect 为绘制区域（以高度等比缩放并水平居中）；返回值：对应部位的路径，器官含内部细节线，仅描边时可见。
    func path(in rect: CGRect) -> Path {
        let s = rect.height
        let ox = rect.midX - 0.26 * s
        // 坐标换算；参数：x、y 为单位坐标；返回值：画布坐标。
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * s, y: rect.minY + y * s) }
        // 单位矩形；参数：x、y 为左上角，w、h 为宽高（均为单位）；返回值：画布矩形。
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(origin: p(x, y), size: CGSize(width: w * s, height: h * s)) }
        // 水平镜像；参数：x 为左半身横坐标；返回值：右半身对应横坐标。
        func m(_ x: CGFloat) -> CGFloat { 0.52 - x }
        var path = Path()
        switch part {
        case .head:
            path.addEllipse(in: r(0.217, 0.004, 0.086, 0.116))
        case .body:
            // 左半身自颈部向下至会阴，再沿镜像分段反向走回颈部；不闭合以避免颈根处多出描边。
            let segs = Self.bodySegments
            path.move(to: p(Self.bodyStart.x, Self.bodyStart.y))
            for seg in segs { path.addCurve(to: p(seg.2.x, seg.2.y), control1: p(seg.0.x, seg.0.y), control2: p(seg.1.x, seg.1.y)) }
            path.addLine(to: p(m(0.258), 0.510))
            for index in segs.indices.reversed() {
                let seg = segs[index]
                let start = index == 0 ? Self.bodyStart : segs[index - 1].2
                path.addCurve(to: p(m(start.x), start.y), control1: p(m(seg.1.x), seg.1.y), control2: p(m(seg.0.x), seg.0.y))
            }
        case .ground:
            path.addEllipse(in: r(0.09, 0.962, 0.34, 0.03))
        case .ruler:
            // 左侧身高刻度：每 0.05 一条短线，每 0.1 一条长线。
            for i in 0...20 {
                let y = 0.02 + CGFloat(i) * 0.047
                let long = i % 2 == 0
                path.move(to: p(0.0, y)); path.addLine(to: p(long ? 0.022 : 0.012, y))
            }
        case .organ(let organ):
            organPath(organ, &path, p, r, m, s)
        }
        return path
    }

    /// 追加器官路径；参数：organ 为部位，path 为待追加路径，p 为坐标换算，r 为单位矩形，m 为镜像，s 为缩放；返回值：无；体型部位由调用方直接高亮身体，不在此绘制。
    private func organPath(_ organ: BodyOrgan, _ path: inout Path, _ p: (CGFloat, CGFloat) -> CGPoint, _ r: (CGFloat, CGFloat, CGFloat, CGFloat) -> CGRect, _ m: (CGFloat) -> CGFloat, _ s: CGFloat) {
        switch organ {
        case .brain:
            path.addEllipse(in: r(0.226, 0.018, 0.068, 0.054))
            // 中央沟与脑回细线，仅描边可见。
            path.move(to: p(0.26, 0.020)); path.addLine(to: p(0.26, 0.070))
            path.move(to: p(0.236, 0.040)); path.addQuadCurve(to: p(0.254, 0.042), control: p(0.245, 0.030))
            path.move(to: p(0.266, 0.042)); path.addQuadCurve(to: p(0.284, 0.040), control: p(0.275, 0.030))
            path.move(to: p(0.238, 0.058)); path.addQuadCurve(to: p(0.254, 0.060), control: p(0.246, 0.051))
            path.move(to: p(0.266, 0.060)); path.addQuadCurve(to: p(0.282, 0.058), control: p(0.274, 0.051))
        case .lungs:
            // 左肺轮廓，右肺为其镜像；肺尖窄、肺底宽。
            path.move(to: p(0.238, 0.168))
            path.addCurve(to: p(0.188, 0.215), control1: p(0.205, 0.168), control2: p(0.190, 0.190))
            path.addCurve(to: p(0.190, 0.300), control1: p(0.186, 0.245), control2: p(0.184, 0.280))
            path.addCurve(to: p(0.248, 0.305), control1: p(0.200, 0.315), control2: p(0.230, 0.312))
            path.addCurve(to: p(0.238, 0.168), control1: p(0.256, 0.270), control2: p(0.252, 0.200))
            path.move(to: p(m(0.238), 0.168))
            path.addCurve(to: p(m(0.188), 0.215), control1: p(m(0.205), 0.168), control2: p(m(0.190), 0.190))
            path.addCurve(to: p(m(0.190), 0.300), control1: p(m(0.186), 0.245), control2: p(m(0.184), 0.280))
            path.addCurve(to: p(m(0.248), 0.305), control1: p(m(0.200), 0.315), control2: p(m(0.230), 0.312))
            path.addCurve(to: p(m(0.238), 0.168), control1: p(m(0.256), 0.270), control2: p(m(0.252), 0.200))
            // 气管与支气管细线。
            path.move(to: p(0.26, 0.138)); path.addLine(to: p(0.26, 0.190))
            path.move(to: p(0.26, 0.190)); path.addQuadCurve(to: p(0.218, 0.225), control: p(0.240, 0.195))
            path.move(to: p(0.26, 0.190)); path.addQuadCurve(to: p(m(0.218), 0.225), control: p(m(0.240), 0.195))
        case .heart:
            let c = p(0.272, 0.265)
            // 单位偏移换算为画布坐标；参数：dx、dy 为以人体高度为 1 的偏移；返回值：画布坐标。
            func q(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: c.x + dx * 0.78 * s, y: c.y + dy * 0.78 * s) }
            path.move(to: q(0, 0.04))
            path.addCurve(to: q(-0.036, -0.012), control1: q(-0.034, 0.018), control2: q(-0.046, 0.000))
            path.addCurve(to: q(0, -0.02), control1: q(-0.032, -0.046), control2: q(-0.006, -0.034))
            path.addCurve(to: q(0.036, -0.012), control1: q(0.006, -0.034), control2: q(0.032, -0.046))
            path.addCurve(to: q(0, 0.04), control1: q(0.046, 0.000), control2: q(0.034, 0.018))
            path.closeSubpath()
        case .liver:
            path.move(to: p(0.172, 0.318))
            path.addQuadCurve(to: p(0.262, 0.305), control: p(0.210, 0.295))
            path.addQuadCurve(to: p(0.250, 0.340), control: p(0.268, 0.322))
            path.addQuadCurve(to: p(0.200, 0.358), control: p(0.232, 0.362))
            path.addQuadCurve(to: p(0.172, 0.318), control: p(0.168, 0.350))
            path.closeSubpath()
        case .stomach:
            path.move(to: p(0.272, 0.312))
            path.addQuadCurve(to: p(0.325, 0.322), control: p(0.312, 0.298))
            path.addQuadCurve(to: p(0.300, 0.360), control: p(0.338, 0.355))
            path.addQuadCurve(to: p(0.272, 0.312), control: p(0.262, 0.350))
            path.closeSubpath()
        case .kidneys:
            path.addEllipse(in: r(0.185, 0.355, 0.022, 0.042))
            path.addEllipse(in: r(m(0.207), 0.355, 0.022, 0.042))
        case .gut:
            path.addRoundedRect(in: r(0.213, 0.368, 0.094, 0.112), cornerSize: CGSize(width: 0.03 * s, height: 0.03 * s))
            // 肠道折叠细线。
            for i in 0..<4 {
                let y = 0.392 + CGFloat(i) * 0.024
                path.move(to: p(0.226, y))
                path.addQuadCurve(to: p(0.294, y), control: p(0.26, y + (i % 2 == 0 ? 0.014 : -0.014)))
            }
        case .frame:
            break
        }
    }
}

/// 医学示意风格的内脏人体：成人比例的半透明轮廓、细线器官与身高刻度；当前部位高亮，心脏按真实心率搏动，肺按呼吸频率起伏，并有缓慢的扫描光带。
struct HealthBodyFigure: View {
    /// 当前高亮部位；nil 表示无。
    var active: BodyOrgan?
    /// 有读数可展示的部位；其余部位仅以暗线条表示。
    var available: Set<BodyOrgan>
    /// 心率（次/分）；nil 时使用静息默认节奏。
    var heartRate: Double?
    /// 呼吸频率（次/分）；nil 时使用默认节奏。
    var respiratoryRate: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let accent = HealthSciFi.cyan

    /// 构建人体示意；参数：无；返回值：按 0.52 宽高比排布的人体与器官，减少动态效果时为静态画面。
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                BodyShape(part: .ground).stroke(accent.opacity(0.35), lineWidth: 0.8)
                BodyShape(part: .ruler).stroke(.white.opacity(0.28), lineWidth: 0.7)
                silhouette
                scan(t)
                ForEach(BodyOrgan.allCases.filter { $0 != .frame }) { organ in organView(organ, t) }
            }
        }
        .aspectRatio(0.52, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// 人体轮廓；参数：无；返回值：自上而下渐隐的半透明填充与细描边，体型被选中时描边加粗并发光。
    private var silhouette: some View {
        let hot = active == .frame
        return ZStack {
            ForEach([BodyShape.Part.body, .head], id: \.self) { part in
                BodyShape(part: part).fill(LinearGradient(colors: [accent.opacity(hot ? 0.26 : 0.12), accent.opacity(hot ? 0.10 : 0.02)], startPoint: .top, endPoint: .bottom))
                BodyShape(part: part).stroke(accent.opacity(hot ? 0.95 : 0.55), lineWidth: hot ? 1.6 : 1)
            }
        }
        .shadow(color: accent.opacity(hot ? 0.6 : 0), radius: 6)
        .animation(.easeInOut(duration: 0.5), value: active)
    }

    /// 扫描光带；参数：t 为时间；返回值：自上而下循环扫过身体的淡光带，前沿带一条亮线。
    private func scan(_ t: Double) -> some View {
        GeometryReader { g in
            let y = (CGFloat((t * 0.2).truncatingRemainder(dividingBy: 1)) * 1.1 - 0.05) * g.size.height
            ZStack(alignment: .top) {
                LinearGradient(colors: [.clear, accent.opacity(0.28)], startPoint: .top, endPoint: .bottom)
                    .frame(height: g.size.height * 0.08)
                Rectangle().fill(accent.opacity(0.9)).frame(height: 1).offset(y: g.size.height * 0.08)
            }
            .offset(y: y)
        }
        .mask {
            ZStack { BodyShape(part: .body); BodyShape(part: .head) }
        }
    }

    /// 单个器官视图；参数：organ 为部位，t 为时间；返回值：按状态着色的器官，心脏和肺带有生理节律动画。
    private func organView(_ organ: BodyOrgan, _ t: Double) -> some View {
        let isActive = active == organ
        let hasData = available.contains(organ)
        let shape = BodyShape(part: .organ(organ))
        let anchor = UnitPoint(x: organ.center.x / 0.52, y: organ.center.y)
        return ZStack {
            shape.fill(accent.opacity(isActive ? 0.45 : (hasData ? 0.12 : 0.03)))
            shape.stroke(accent.opacity(isActive ? 1 : (hasData ? 0.55 : 0.18)), lineWidth: isActive ? 1.2 : 0.7)
        }
        .shadow(color: accent.opacity(isActive ? 0.8 : 0), radius: 5)
        .scaleEffect(rhythm(organ, t), anchor: anchor)
        .animation(.easeInOut(duration: 0.45), value: isActive)
    }

    /// 器官节律缩放；参数：organ 为部位，t 为时间；返回值：心脏为双峰搏动，肺为正弦起伏，其余为 1；减少动态效果时恒为 1。
    private func rhythm(_ organ: BodyOrgan, _ t: Double) -> CGFloat {
        guard !reduceMotion else { return 1 }
        switch organ {
        case .heart:
            let bpm = min(max(heartRate ?? 72, 40), 160)
            let phase = (t * bpm / 60).truncatingRemainder(dividingBy: 1)
            // 收缩与舒张两个高斯峰，模拟「咚—咚」。
            let pulse = exp(-pow((phase - 0.08) / 0.04, 2)) + 0.6 * exp(-pow((phase - 0.28) / 0.05, 2))
            return 1 + 0.12 * pulse
        case .lungs:
            let rate = min(max(respiratoryRate ?? 14, 6), 40)
            return 1 + 0.035 * sin(t * 2 * .pi * rate / 60)
        default:
            return 1
        }
    }
}
