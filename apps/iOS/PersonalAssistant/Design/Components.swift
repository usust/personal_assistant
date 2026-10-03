import SwiftUI

struct InlineError: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline).foregroundStyle(.red).accessibilityLabel("错误：\(message)")
    }
}
struct SymbolTile: View {
    let symbol: String
    var color: Color = .teal
    var body: some View {
        Image(systemName: symbol).font(.title3.weight(.semibold))
            .foregroundStyle(color).frame(width: 44, height: 44)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityHidden(true)
    }
}
struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    var color: Color = .teal
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(color)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            .accessibilityElement(children: .combine)
    }
}
struct SaveToolbar: ToolbarContent {
    @Environment(\.dismiss) private var dismiss
    let busy: Bool
    let valid: Bool
    let save: () -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
        ToolbarItem(placement: .confirmationAction) {
            Button(action: save) { if busy { ProgressView() } else { Text("保存").bold() } }.disabled(busy || !valid)
        }
    }
}
extension Color {
    /// 解析清单颜色；参数：hex 为 #RRGGBB；返回值：颜色，无效时使用青色；无副作用。
    static func listColor(_ hex: String) -> Color {
        guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return .teal }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct TimeInput: View {
    let title: String
    @Binding var value: String
    private var enabled: Binding<Bool> { Binding(get: { !value.isEmpty }, set: { value = $0 ? "09:00" : "" }) }
    private var time: Binding<Date> {
        Binding(get: {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "HH:mm"
            return formatter.date(from: value) ?? .now
        }, set: { date in
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "HH:mm"
            value = formatter.string(from: date)
        })
    }
    var body: some View {
        Toggle("指定" + title, isOn: enabled)
        if !value.isEmpty { DatePicker(title, selection: time, displayedComponents: .hourAndMinute) }
    }
}
