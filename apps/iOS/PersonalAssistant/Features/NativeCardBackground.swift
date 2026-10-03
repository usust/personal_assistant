import SwiftUI

/// 原生矢量卡面不含示例卡号和实卡图案；按名称选择配色，任意屏幕密度保持清晰。
struct NativeCardBackground: View {
    let name: String
    let bank: String

    /// 选择卡片主题色；参数：无；返回值：渐变起止颜色，仅用于外观，不推断或修改卡组织、账户属性。
    private var palette: [Color] {
        let value = name.lowercased()
        if value.contains("初音") || value.contains("miku") {
            return [Color(red: 0.08, green: 0.46, blue: 0.47), Color(red: 0.02, green: 0.19, blue: 0.25)]
        }
        if value.contains("皮卡丘") || value.contains("pikachu") || value.contains("宝可梦") {
            return [Color(red: 0.55, green: 0.36, blue: 0.06), Color(red: 0.25, green: 0.16, blue: 0.03)]
        }
        if value.contains("白金") || value.contains("platinum") {
            return [Color(red: 0.37, green: 0.41, blue: 0.48), Color(red: 0.13, green: 0.17, blue: 0.23)]
        }
        if value.contains("金卡") || value.contains("gold") {
            return [Color(red: 0.48, green: 0.35, blue: 0.17), Color(red: 0.20, green: 0.14, blue: 0.07)]
        }
        if value.contains("visa") || value.contains("全币") {
            return [Color(red: 0.16, green: 0.25, blue: 0.41), Color(red: 0.04, green: 0.08, blue: 0.17)]
        }
        return bank.contains("招商") || bank.contains("招行")
            ? [Color(red: 0.40, green: 0.13, blue: 0.20), Color(red: 0.16, green: 0.05, blue: 0.10)]
            : [Color(red: 0.17, green: 0.32, blue: 0.42), Color(red: 0.05, green: 0.14, blue: 0.23)]
    }

    /// 绘制渐变和几何线条；参数：无；返回值：无文字、不可交互的背景，装饰集中在右侧以保持名称和尾号清晰。
    var body: some View {
        LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                // 绘制回调输入画布及实际尺寸、返回无；使用比例坐标和矢量曲线，避免放大位图产生模糊。
                Canvas { context, size in
                    for index in 0..<5 {
                        let shift = CGFloat(index) * size.width * 0.12
                        var line = Path()
                        line.move(to: CGPoint(x: size.width * 0.55 + shift, y: -20))
                        line.addCurve(to: CGPoint(x: size.width * 0.32 + shift, y: size.height + 20),
                                      control1: CGPoint(x: size.width * 1.1 + shift, y: size.height * 0.30),
                                      control2: CGPoint(x: size.width * 0.3 + shift, y: size.height * 0.70))
                        context.stroke(line, with: .color(.white.opacity(index == 0 ? 0.16 : 0.07)), lineWidth: 1)
                    }
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
