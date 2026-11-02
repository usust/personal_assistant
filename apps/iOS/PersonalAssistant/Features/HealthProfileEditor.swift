import SwiftUI

/// 身体资料与能量参考共用编辑页；HealthKit 读取值仅参与本次计算，手动资料留在本机。
struct HealthProfileEditor: View {
    var observed: HealthProfile? = nil
    var currentGoal: Double? = nil
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var manual = HealthProfile()
    @State private var height = ""
    @State private var weight = ""
    @State private var age = ""
    @State private var customGoal = ""
    @State private var useCustom = false
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?

    /// 获取当前本机资料作用域；参数：无；返回值：服务器及账号的安全标识，未登录为 nil。
    private var owner: String? {
        store.profile.map { MealThumbnailStore.scope(server: store.api.baseURL, userID: $0.id) }
    }
    /// 从文本构造手动草稿；参数：无；返回值：仅包含用户输入的资料，不保存健康读取副本。
    private var draft: HealthProfile {
        var result = manual
        result.heightCM = decimal(height)
        result.weightKG = decimal(weight)
        result.age = Int(age)
        return result
    }
    /// 合并本次可读取数据；参数：无；返回值：用于预览的资料，活动水平及特殊情况保持手动选择。
    private var effective: HealthProfile { observed.map { draft.mergingHealth($0) } ?? draft }
    /// 获取输入校验结果；参数：无；返回值：非空输入均为合理有限数时为 true，允许保留不完整资料。
    private var validInput: Bool {
        (height.isEmpty || decimal(height).map { $0.isFinite && (50...250).contains($0) } == true) &&
        (weight.isEmpty || decimal(weight).map { $0.isFinite && (2...350).contains($0) } == true) &&
        (age.isEmpty || Int(age).map { (0...130).contains($0) } == true)
    }
    /// 获取本次待采用目标；参数：无；返回值：接口支持的千卡值，缺失或超出范围时 nil；不截断建议。
    private var proposedGoal: Double? {
        let value = useCustom ? decimal(customGoal) : effective.recommendation.map { ($0.calories / 10).rounded() * 10 }
        return value.flatMap { NutritionMath.validGoal($0) ? $0 : nil }
    }
    /// 构建资料与估算依据表单；参数：无；返回值：本机保存及明确采用目标的操作，写入时锁定关闭。
    var body: some View {
        NavigationStack {
            Form {
                Section("身体资料") {
                    numberField("身高", text: $height, unit: "厘米", measured: HealthProfile.validHeight(observed?.heightCM) ? observed?.heightCM : nil)
                    numberField("体重", text: $weight, unit: "千克", measured: HealthProfile.validWeight(observed?.weightKG) ? observed?.weightKG : nil)
                    numberField("年龄", text: $age, unit: "岁", measured: observed?.age.flatMap { (0...130).contains($0) ? Double($0) : nil })
                    if let sex = observed?.sex, sex != .unspecified {
                        LabeledContent("生理性别", value: "\(sex.title) · Apple 健康")
                    } else {
                        Picker("生理性别", selection: $manual.sex) {
                            ForEach(HealthProfile.Sex.allCases) { value in Text(value.title).tag(value) }
                        }
                    }
                    if !validInput { Text("请检查身高、体重和年龄").foregroundStyle(.red) }
                }
                Section("日常活动") {
                    Picker("活动水平", selection: $manual.activity) {
                        ForEach(HealthProfile.Activity.allCases) { value in Text(value.title).tag(value) }
                    }
                    Text(activityDescription).font(.caption).foregroundStyle(.secondary)
                    Toggle("孕哺期或需要专业营养指导", isOn: $manual.requiresProfessionalGuidance)
                }
                Section("每日能量参考") {
                    Toggle("使用专业指导的自定目标", isOn: $useCustom)
                    if useCustom {
                        numberField("每日热量", text: $customGoal, unit: "千卡", measured: nil)
                        if !customGoal.isEmpty && proposedGoal == nil {
                            Text("请输入 1000–6000 千卡").font(.caption).foregroundStyle(.red)
                        }
                    } else if let recommendation = effective.recommendation {
                        HStack(alignment: .firstTextBaseline) {
                            Text(((recommendation.calories / 10).rounded() * 10).formatted(.number.precision(.fractionLength(0))))
                                .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                            Text("千卡 / 日").foregroundStyle(.secondary)
                        }.accessibilityElement(children: .combine)
                        Text("维持体重估算").font(.subheadline).foregroundStyle(.secondary)
                        DisclosureGroup("计算依据") {
                            LabeledContent("基础代谢", value: "\(recommendation.basalCalories.formatted(.number.precision(.fractionLength(0)))) 千卡")
                            LabeledContent("活动系数", value: recommendation.activityMultiplier.formatted())
                            Text("Mifflin–St Jeor：10 × 体重(kg) + 6.25 × 身高(cm) − 5 × 年龄 + 生理性别常数；男性 +5，女性 −161。基础代谢乘以活动系数，不再叠加当天运动消耗。")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("适用于 18–80 岁一般成年人，是生活方式参考。实际需要会随身体情况变化。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if proposedGoal == nil { Text("估算超出可保存范围，请使用专业指导目标。").font(.caption) }
                    } else {
                        Text(effective.missingRequirements.joined(separator: "、"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Button("采用为每日参考") { Task { await save(adoptGoal: true) } }
                        .buttonStyle(.glassProminent)
                        .disabled(!validInput || proposedGoal == nil || busy)
                }
                if let error { Section { InlineError(message: error) } }
                if busy { ProgressView("正在保存…") }
            }
            .navigationTitle("身体资料与目标").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存资料") { Task { await save(adoptGoal: false) } }.disabled(!validInput || busy)
                }
            }
            .disabled(busy).interactiveDismissDisabled(busy)
            .task { load() }
        }
    }

    /// 解释活动系数选择；参数：无；返回值：当前档位对应活动习惯，避免只凭名称猜测。
    private var activityDescription: String {
        switch manual.activity {
        case .sedentary: return "以坐着为主，较少规律运动"
        case .light: return "轻体力活动，每周约 1–3 次运动"
        case .moderate: return "日常走动较多，每周约 3–5 次运动"
        case .high: return "体力劳动或每周约 6–7 次高强度运动"
        }
    }
    /// 构建数值输入或本次健康读取值；参数：title 为字段名、text 为手动文本、unit 为单位、measured 为健康数值；返回值：有可读取值时显示来源，否则允许补录；无持久化副作用。
    private func numberField(_ title: String, text: Binding<String>, unit: String, measured: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(title) {
                if let measured {
                    Text("\(measured.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                } else {
                    HStack {
                        TextField("未填写", text: text).keyboardType(title == "年龄" ? .numberPad : .decimalPad)
                            .multilineTextAlignment(.trailing).accessibilityLabel(title)
                        Text(unit).foregroundStyle(.secondary)
                    }
                }
            }
            if measured != nil { Text("Apple 健康").font(.caption2).foregroundStyle(.secondary) }
        }
    }
    /// 解析系统十进制键盘文本；参数：text 为未分组的数字，接受当前地区小数分隔符及持久化使用的点号；返回值：完整文本可解析时的数值，否则 nil；不接受混合分隔符或截断解析。
    private func decimal(_ text: String) -> Double? {
        let separator = Locale.current.decimalSeparator ?? "."
        return Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: separator, with: "."))
    }

    /// 首次装载当前账号的手动资料；参数：无；返回值：无；不将 HealthKit 读取值写入输入或磁盘。
    private func load() {
        guard !loaded, let owner else { return }
        loaded = true
        manual = HealthProfileStore.load(owner: owner) ?? HealthProfile()
        height = manual.heightCM.map(MealItemDraft.number) ?? ""
        weight = manual.weightKG.map(MealItemDraft.number) ?? ""
        age = manual.age.map(String.init) ?? ""
        customGoal = currentGoal.map(MealItemDraft.number) ?? ""
    }
    /// 保存资料并可选采用每日目标；参数：adoptGoal 表示用户明确选择将当前参考写入服务器；返回值：无；先保存本机资料，云端失败保留输入及错误，不自动重试或跨账号提交结果。
    @MainActor private func save(adoptGoal: Bool) async {
        guard !busy, validInput, let owner, !adoptGoal || proposedGoal != nil else { return }
        let session = store.cloudSessionID
        busy = true; error = nil
        defer { busy = false }
        do {
            try HealthProfileStore.save(draft, owner: owner)
            if adoptGoal, let proposedGoal {
                try await store.api.mutate("/health-management/nutrition/goal", method: "PUT", body: ["daily_goal": proposedGoal])
            }
            guard session == store.cloudSessionID else { return }
            dismiss()
        } catch {
            guard session == store.cloudSessionID else { return }
            self.error = error.localizedDescription
        }
    }
}
