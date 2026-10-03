import ActivityKit
import SwiftUI
import WidgetKit

@main
struct ScreenshotActivityWidget: Widget {
    /// 构建锁屏及灵动岛实时状态；参数：无；返回值：唯一实时活动配置；仅用户点击后才打开应用处理记录。
    var body: some WidgetConfiguration {
        // 锁屏回调输入活动上下文、返回状态行；过期活动显示中断而不继续声称正在识别。
        ActivityConfiguration(for: ScreenshotActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: symbol(context))
                    .foregroundStyle(color(context))
                Text("图片记账")
                Spacer()
                Text(title(context))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "personalassistant://screenshot-records"))
        } dynamicIsland: { context in
            // 灵动岛回调输入活动上下文、返回展开和紧凑布局；只展示真实阶段，不伪造百分比。
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "viewfinder").foregroundStyle(color(context))
                }
                DynamicIslandExpandedRegion(.trailing) { statusIndicator(context) }
            } compactLeading: {
                Image(systemName: "viewfinder").foregroundStyle(color(context))
            } compactTrailing: {
                statusIndicator(context)
            } minimal: {
                statusIndicator(context)
            }
            .widgetURL(URL(string: "personalassistant://screenshot-records"))
            .keylineTint(color(context))
        }
    }

    /// 构建统一状态指示器；参数：context 为系统活动上下文；返回值：识别转圈或真实终态图标，无副作用；所有灵动岛布局共用且不显示文字。
    @ViewBuilder private func statusIndicator(_ context: ActivityViewContext<ScreenshotActivityAttributes>) -> some View {
        // 系统可能自动展示展开布局，因此展开、紧凑和最小布局都必须复用相同的无文字状态。
        if context.state.phase == .processing && !context.isStale {
            ProgressView()
                .controlSize(.mini)
                .tint(color(context))
                .frame(width: 20, height: 20)
                .accessibilityLabel(context.state.phase.title)
        } else {
            Image(systemName: symbol(context))
                .font(.caption)
                .foregroundStyle(color(context))
                .frame(width: 20, height: 20)
                .accessibilityLabel(title(context))
        }
    }

    /// 决定活动标题；参数：context 为系统活动上下文；返回值：阶段标题，识别超时为中断提示，终态不被过期标记覆盖，无副作用。
    private func title(_ context: ActivityViewContext<ScreenshotActivityAttributes>) -> String {
        context.isStale && context.state.phase == .processing ? "已中断" : context.state.phase.title
    }

    /// 决定状态图标；参数：context 为系统活动上下文；返回值：阶段或中断图标，无副作用。
    private func symbol(_ context: ActivityViewContext<ScreenshotActivityAttributes>) -> String {
        context.isStale && context.state.phase == .processing ? "exclamationmark.circle.fill" : context.state.phase.symbol
    }

    /// 决定状态色；参数：context 为系统活动上下文；返回值：成功绿色、异常橙色或识别青色，无副作用。
    private func color(_ context: ActivityViewContext<ScreenshotActivityAttributes>) -> Color {
        if context.isStale && context.state.phase == .processing { return .orange }
        switch context.state.phase {
        case .processing: return .cyan
        case .posted: return .green
        case .review, .failed: return .orange
        }
    }
}
