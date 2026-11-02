import SwiftUI

/// 摄入与参考值的能量小伙伴；动画只响应记录变化，减少动态效果时保持静止。
struct NutritionEnergyCompanion: View {
    let state: NutritionEnergyState
    var title = "今日能量"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingDetails = false
    @State private var revealed = false

    /// 获取展示阶段的填充比例；参数：无；返回值：初次出现从零过渡到真实比例，减少动态效果直接展示最终值。
    private var displayedFill: Double { reduceMotion || revealed ? state.fill : 0 }

    /// 获取深浅色分别选择的单序列颜色；参数：无；返回值：能量标记颜色，文字仍使用系统前景。
    private var energyColor: Color {
        colorScheme == .dark ? Color(red: 70 / 255, green: 150 / 255, blue: 159 / 255) : Color(red: 40 / 255, green: 127 / 255, blue: 136 / 255)
    }
    /// 构建可访问的动画结论；参数：无；返回值：小伙伴、真实比例、数值与可展开明细；没有自动上传行为。
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Image(systemName: "sparkle").foregroundStyle(energyColor).accessibilityHidden(true)
            }
            let layout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .center, spacing: 22))
            layout {
                companion.frame(width: 112, height: 130).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.title).font(.system(.title3, design: .rounded, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let ratio = state.ratio, state.hasMeals {
                        Text(ratio.formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                            .contentTransition(.numericText())
                        Text("已记录 / 每日参考").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "fork.knife.circle").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(energyColor.opacity(0.13))
                    Capsule().fill(energyColor).frame(width: geometry.size.width * displayedFill)
                }
            }.frame(height: 8).accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline) {
                valueLabel("已记录", value: state.recorded)
                Spacer(minLength: 12)
                valueLabel("每日参考", value: state.validGoal)
            }
            DisclosureGroup(isExpanded: $showingDetails) {
                VStack(alignment: .leading, spacing: 8) {
                    if let goal = state.validGoal, state.hasMeals {
                        LabeledContent(state.recorded > goal ? "高于参考" : "与参考相差", value: "\(abs(state.recorded - goal).formatted(.number.precision(.fractionLength(0)))) 千卡")
                    }
                    Text("仅比较已记录餐食；照片热量为估算。").font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 6)
            } label: {
                Text("查看数值").font(.subheadline)
            }
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 28))
        .animation(reduceMotion ? nil : .spring(response: 0.65, dampingFraction: 0.8), value: state)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.8), value: revealed)
        .onAppear { revealed = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.accessibilitySummary)
    }
    /// 构建数值标签；参数：title 为意义、value 为千卡或 nil；返回值：文字与单位组合，未知显示横杠。
    private func valueLabel(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { "\($0.formatted(.number.precision(.fractionLength(0)))) 千卡" } ?? "—")
                .font(.system(.subheadline, design: .rounded, weight: .medium))
        }.accessibilityElement(children: .combine)
    }
    /// 绘制有表情的能量种子；参数：无；返回值：按真实比例填充的形状；超量保留温和表情而非惩罚反馈。
    private var companion: some View {
        ZStack {
            Ellipse().fill(energyColor.opacity(0.13)).frame(width: 74, height: 10).offset(y: 56)
            Capsule().fill(energyColor).frame(width: 10, height: 26).rotationEffect(.degrees(-32)).offset(x: -45, y: 15)
            Capsule().fill(energyColor).frame(width: 10, height: 26).rotationEffect(.degrees(32)).offset(x: 45, y: 15)
            RoundedRectangle(cornerRadius: 38).fill(energyColor.opacity(0.12)).frame(width: 88, height: 90)
            RoundedRectangle(cornerRadius: 38).fill(energyColor.opacity(0.8)).frame(width: 88, height: 90)
                .mask(alignment: .bottom) { Rectangle().frame(height: 90 * displayedFill) }
            RoundedRectangle(cornerRadius: 38).strokeBorder(energyColor, lineWidth: 2).frame(width: 88, height: 90)
            HStack(spacing: 22) {
                Capsule().frame(width: 5, height: 9)
                Capsule().frame(width: 5, height: 9)
            }.foregroundStyle(.primary).offset(y: -3)
            Smile().stroke(.primary, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 17, height: 9).offset(y: 13)
            Image(systemName: "leaf.fill").font(.system(size: 25, weight: .medium)).foregroundStyle(energyColor)
                .rotationEffect(.degrees(-20)).offset(x: 10, y: -49)
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : state.recorded)
        }
        // 阶段回调输入视图和位移阶段，输出一次轻跳；仅在摄入变化时触发，不持续循环。
        .phaseAnimator([0.0, -5.0, 0.0], trigger: reduceMotion ? 0 : (revealed ? state.recorded + 1 : 0)) { content, offset in
            content.offset(y: reduceMotion ? 0 : offset)
        } animation: { _ in .easeInOut(duration: reduceMotion ? 0 : 0.22) }
    }
}

/// 表情弧线只表示友好，不承担医学状态编码。
private struct Smile: Shape {
    /// 构建嘴角曲线；参数：rect 为布局区域；返回值：向下弯的二次贝塞尔路径，无副作用。
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY * 1.6))
        return path
    }
}
