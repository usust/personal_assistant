import SwiftUI

/// iOS 共享视觉尺度；只定义内容层样式，导航与操作层由系统 Liquid Glass 管理。
enum AppVisualStyle {
    static let pageInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 24
    static let itemSpacing: CGFloat = 12
    static let maxContentWidth: CGFloat = 820
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let cardRadius: CGFloat = 20
    static let iconRadius: CGFloat = 12
    static let fieldRadius: CGFloat = 14
    static let keyRadius: CGFloat = 14
    static let cardInset: CGFloat = 20
    static let keypadSpacing: CGFloat = 6
    static let compactKeypadSpacing: CGFloat = 4
    static let keypadFont = Font.system(.title2, design: .rounded)
}

/// 财务类型的语义颜色；使用系统动态颜色适配深浅色，不覆盖用户自定义分类和清单颜色。
enum FinanceVisualStyle {
    static let expense = Color(uiColor: .systemRed)
    static let income = Color(uiColor: .systemTeal)
    static let transfer = Color(uiColor: .systemOrange)

    /// 获取交易类型颜色；参数：type 为 expense、income 或 transfer，未知类型使用支出色；返回值：系统动态颜色，无业务副作用。
    static func color(for type: String) -> Color {
        switch type {
        case "income": return income
        case "transfer": return transfer
        default: return expense
        }
    }
}

/// 共享金额文字；保持数字等宽与圆角字型，字号由系统动态字体管理。
struct AmountText: View {
    enum Emphasis { case prominent, standard, compact }
    let value: String
    var emphasis: Emphasis = .prominent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 返回金额层级字体；参数：无；返回值：主金额、普通指标或辅助金额的动态字体，无副作用。
    private var font: Font {
        switch emphasis {
        case .prominent: return .system(.largeTitle, design: .rounded, weight: .semibold)
        case .standard: return .system(.title2, design: .rounded, weight: .semibold)
        case .compact: return .system(.subheadline, design: .rounded, weight: .semibold)
        }
    }

    /// 构建金额文字；参数：无；返回值：动态字号数字，普通字号受限时适度缩小，辅助字号允许换行而不缩小；辅助功能保留完整值，无副作用。
    var body: some View {
        Text(value).font(font).monospacedDigit()
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 1 : 0.7)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 普通内容卡片；Content 为内容视图类型，不叠加玻璃，系统背景响应外观与减少透明度设置。
struct ContentCard<Content: View>: View {
    private let content: Content
    let padding: CGFloat

    /// 构建共享卡片；参数：padding 为非负内边距，content 为无输入、返回 Content 的构造回调；返回值：内容卡片，无业务副作用。
    init(padding: CGFloat = AppVisualStyle.cardInset, @ViewBuilder content: () -> Content) {
        self.padding = max(0, padding)
        self.content = content()
    }

    /// 构建卡片布局；参数：无；返回值：统一边距、系统背景与连续圆角的内容视图；无副作用。
    var body: some View {
        content.padding(padding).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
    }
}

extension View {
    /// 应用普通内容背景；参数：radius 为非负圆角，默认使用共享卡片尺度；返回值：保持现有布局的实色背景视图，无业务副作用。
    func cardSurface(radius: CGFloat = AppVisualStyle.cardRadius) -> some View {
        background(AppVisualStyle.surface, in: RoundedRectangle(cornerRadius: max(0, radius), style: .continuous))
    }
}

/// 共用浮动标签布局；Content 为实际输入视图，调用方负责焦点、绑定和键盘行为。
struct FloatingFieldContainer<Content: View>: View {
    let title: String
    let raised: Bool
    let inputHeight: CGFloat
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var labelSpace: CGFloat = 22

    /// 创建标签容器；参数：title 为字段名称，raised 为聚焦或有值状态，inputHeight 为非负输入高度，content 为无输入、返回 Content 的回调；返回值：浮动输入容器，无业务副作用。
    init(title: String, raised: Bool, inputHeight: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.title = title
        self.raised = raised
        self.inputHeight = max(0, inputHeight)
        self.content = content()
    }

    /// 构建动态标签；参数：无；返回值：至少 44 点高、标签留白随字号增长的输入布局；减少动态效果时取消标签动画，不改变草稿。
    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(title).font(raised ? .caption : .body).foregroundStyle(.secondary)
                .offset(y: raised ? 0 : max(labelSpace, inputHeight) / 2)
                .allowsHitTesting(false).accessibilityHidden(true)
            content.frame(minHeight: inputHeight).padding(.top, labelSpace)
        }
        .frame(minHeight: 44, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: raised)
    }
}

/// 共用金额按键样式；数字区保持实色，完成键可指定强调色和适合该底色的文字色。
struct AmountKeyStyle: ButtonStyle {
    var accent: Color = .accentColor
    var emphasized = false
    var foreground: Color = .primary
    @Environment(\.isEnabled) private var enabled

    /// 构建按键外观；参数：configuration 为系统提供的标签和按下状态；返回值：统一圆角、实色底及按下反馈的按钮，不缩放或修改金额。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(foreground)
            .background(emphasized ? accent : Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: AppVisualStyle.keyRadius, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

/// 共用指标行；名称、数值与单位明确分层，大字号时自动切换纵向布局。
struct MetricRow: View {
    let title: String
    let value: String
    let symbol: String
    var unit: String = ""

    /// 构建指标行；参数：无；返回值：水平或纵向的完整指标，保留缺失占位和辅助功能读值；无业务副作用。
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { label; Spacer(minLength: 12); reading }
            VStack(alignment: .leading, spacing: 4) { label; reading }
        }.accessibilityElement(children: .combine)
    }

    /// 构建指标名称；参数：无；返回值：统一字重与次级颜色的系统图标标签；无副作用。
    private var label: some View {
        Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
    }

    /// 构建数值和单位；参数：无；返回值：等宽数值与次级单位组合，不将缺失值转换为零；无副作用。
    private var reading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.body.weight(.medium)).monospacedDigit()
            if !unit.isEmpty { Text(unit).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
