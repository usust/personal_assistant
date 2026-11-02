import SwiftUI

/// 本机健康首页；参数：无；返回值：身体档案、能量参考及真实健康指标；健康读取仅在用户联接后执行。
@MainActor
struct HealthDashboardView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// 当前账号的只读 HealthKit 读取器；切换账号时整体替换，旧请求无法覆盖新账号快照。
    @State private var reader = HealthDashboardReader()
    /// 仅发布当前有效读取结果；前台恢复、跨日、刷新失败时清空，不沿用读取器内部旧快照参与公式。
    @State private var observedSnapshot: HealthSnapshot?
    /// 观测有效期令牌；生命周期变化使进行中的结果失效，随后安排一次无授权弹窗的补读。
    @State private var observationGeneration = UUID()
    /// 仅保存手动录入字段；HealthKit 观测值只在展示和计算时合并，不写入本地档案。
    @State private var manualProfile = HealthProfile()
    /// 已装载的账号范围；与实时身份不一致时隐藏所有旧读数。
    @State private var displayedScope: String?
    /// 仅表示该账号曾明确发起联接，不推断 HealthKit 是否允许每一项读取。
    @State private var connected = false
    /// 当前档案编辑器的展示状态；换号时关闭，避免保存到不同身份。
    @State private var editingProfile = false
    /// 当前指标浏览分组；只影响本机显示。
    @State private var selectedGroup = MetricGroup.body
    /// 清理确认绑定到发起时身份，防止确认期间换号误删另一账号。
    @State private var confirmingCleanup = false
    @State private var cleanupScope: String?
    /// 分账号保留清理失败，刷新与重新读取不会掩盖失败；重试成功才移除。
    @State private var cleanupErrors: [String: String] = [:]
    @State private var cleanedScope: String?
    /// 主视觉当前选中的身体部位；仅影响显示，失效时回退到首个有参数的部位。
    @State private var heroOrgan: BodyOrgan?
    /// 轮播计时戳；用户点选后更新以重启计时。
    @State private var heroStamp = UUID()
    /// 分组胶囊共享几何动画命名空间。
    @Namespace private var groupNamespace

    /// 当前本机资料范围；参数：无；返回值：稳定设备空间，不随登录或退出改变。
    private var scope: String? { store.localDataScope }

    /// 页面强调色；参数：无；返回值：科幻霓虹青，页面固定深色外观。
    private var accent: Color { HealthSciFi.cyan }

    /// 当前身份可见的健康快照；参数：无；返回值：身份匹配时的快照，否则为 nil，避免切换期间展示旧数据。
    private var snapshot: HealthSnapshot? {
        guard let scope, scope == displayedScope else { return nil }
        return observedSnapshot
    }

    /// 用于显示与热量估算的合并档案；参数：无；返回值：健康观测优先、手动信息补全的档案，不产生持久化副作用。
    private var profile: HealthProfile {
        guard scope != nil, scope == displayedScope else { return HealthProfile() }
        return manualProfile.mergingHealth(snapshot?.profile ?? HealthProfile())
    }

    /// 当前分类的真实健康指标；参数：无；返回值：保留读取器顺序的指标列表，不补造读数或采样日期。
    private var visibleMetrics: [HealthMetric] {
        snapshot?.metrics.filter { metric in selectedGroup.includes(metric.id) } ?? []
    }

    /// 构建健康首页；参数：无；返回值：科幻全息风格的可滚动仪表盘；不执行上传或云端分析。
    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                profileHero.holoAppear(0)
                nutritionSection.holoAppear(0.15).holoScroll()
                connectionSection.holoAppear(0.25)
                if snapshot != nil { metricsSection }
                cloudDestination.holoScroll()
                cleanupSection
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .scrollIndicators(.hidden)
        // 深空动态背景固定在滚动内容之后，形成视差层次。
        .background { HealthSciFiBackground().ignoresSafeArea() }
        .preferredColorScheme(.dark)
        .navigationTitle("健康管理")
        .navigationBarTitleDisplayMode(.inline)
        .tint(accent)
        // 身份任务：输入为当前范围；输出无。范围改变即清空旧数据，并仅为已联接身份执行无弹窗读取。
        .task(id: scope) { await activateScope() }
        // 下拉刷新：输入、输出无；只刷新手动档案及已联接的健康数据，绝不触发授权弹窗。
        .refreshable { await refresh(requestAuthorization: false) }
        // 前台回调；参数为旧、新场景阶段，返回值无；先立即移除旧观测，再仅为已联接身份无弹窗补读。
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { invalidateObservationsAndRefresh() }
        }
        // 时间变化回调；参数为系统跨日或时钟变化通知，返回值无；重新计算当天范围和年龄，不触发授权。
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            invalidateObservationsAndRefresh()
        }
        .sheet(isPresented: $editingProfile, onDismiss: reloadManualProfile) {
            HealthProfileEditor(observed: snapshot?.profile)
                .id(store.cloudSessionID)
        }
        .confirmationDialog("清理本机健康资料与餐食照片？", isPresented: $confirmingCleanup, titleVisibility: .visible) {
            Button("清理本机资料", role: .destructive, action: clearLocalData)
            // 取消回调；参数、返回值：无；保留全部本机资料。
            Button("取消", role: .cancel) { cleanupScope = nil }
        } message: {
            Text("删除当前账号的本机身体档案与餐食照片，并断开本页联接。Apple 健康及服务器数据不受影响。")
        }
    }

    /// 身体档案主视觉；参数：无；返回值：内脏人体示意与按部位关联的真实参数，大字号或减少动态效果时改为静态列表。
    private var profileHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HoloTitle(title: "身体档案", symbol: "waveform.path.ecg")
                Spacer()
                // 编辑回调；参数、返回值：无；打开当前账号的本地档案编辑器。
                Button { editingProfile = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(accent)
                        .frame(width: 44, height: 44)
                        .holoPanel(accent, radius: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑身体档案")
                .disabled(scope == nil)
            }
            if dynamicTypeSize >= .xxxLarge || reduceMotion {
                staticHero
            } else {
                heroStage
            }
        }
    }

    /// 身体档案主视觉的数据项；字段：id 为稳定标识，title 为参数名，value 为数值（缺失为 nil），text 为非数值读数（如性别，优先于 value），decimals 为最多小数位，unit 为单位，organ 为关联的身体部位。
    private struct HeroItem: Identifiable {
        let id: String
        let title: String
        var value: Double?
        var text: String?
        var decimals = 1
        var unit = ""
        let organ: BodyOrgan
    }

    /// 有读数的身体参数；参数：无；返回值：按部位关联的参数列表（脑：年龄、睡眠；心脏：心率；肺：血氧、呼吸；肝：基础代谢；胃：膳食能量；肾：饮水；腹部：体重、BMI、体脂；体型：身高、性别、步行、活动水平）；缺失的参数不补零也不占位，BMI 与基础代谢只在有真实依据时出现。
    private var heroItems: [HeroItem] {
        var items: [HeroItem] = []
        let metrics = snapshot?.metrics ?? []
        // 按稳定标识取读取器指标，仅采用有读数者。
        func observed(_ id: String) -> HealthMetric? { metrics.first { $0.id == id && $0.value != nil } }
        // 追加读取器指标；参数：id 为指标标识，organ 为关联部位，decimals 为小数位；返回值：无；无读数时忽略。
        func add(_ id: String, _ organ: BodyOrgan, decimals: Int = 1) {
            guard let m = observed(id) else { return }
            items.append(HeroItem(id: m.id, title: m.title, value: m.value, decimals: decimals, unit: m.unit, organ: organ))
        }
        if let age = profile.age { items.append(HeroItem(id: "age", title: "年龄", value: Double(age), decimals: 0, unit: "岁", organ: .brain)) }
        add("sleep", .brain)
        add("restingHeartRate", .heart, decimals: 0); add("heartRate", .heart, decimals: 0); add("hrv", .heart, decimals: 0)
        add("oxygen", .lungs, decimals: 0); add("respiratoryRate", .lungs, decimals: 0); add("vo2Max", .lungs)
        if let basal = profile.recommendation?.basalCalories {
            items.append(HeroItem(id: "basal", title: "基础代谢", value: basal, decimals: 0, unit: "千卡", organ: .liver))
        }
        add("dietaryEnergy", .stomach, decimals: 0)
        add("water", .kidneys, decimals: 0)
        if let weight = profile.weightKG { items.append(HeroItem(id: "weight", title: "体重", value: weight, unit: "公斤", organ: .gut)) }
        // BMI 优先采用 Apple 健康读数；缺失时由有效身高体重计算。
        var bmi = observed("bmi")?.value
        if bmi == nil, HealthProfile.validHeight(profile.heightCM), HealthProfile.validWeight(profile.weightKG), let h = profile.heightCM, let w = profile.weightKG {
            bmi = w / pow(h / 100, 2)
        }
        if let bmi { items.append(HeroItem(id: "bmi", title: "身体质量指数", value: bmi, unit: "BMI", organ: .gut)) }
        add("bodyFat", .gut); add("leanMass", .gut)
        if let height = profile.heightCM { items.append(HeroItem(id: "height", title: "身高", value: height, unit: "厘米", organ: .frame)) }
        if profile.sex != .unspecified { items.append(HeroItem(id: "sex", title: "性别", text: profile.sex.title, organ: .frame)) }
        add("walkingSpeed", .frame, decimals: 2); add("steps", .frame, decimals: 0)
        items.append(HeroItem(id: "activity", title: "活动水平", text: profile.activity.title, organ: .frame))
        return items
    }

    /// 按部位分组的参数；参数：无；返回值：按人体自上而下顺序、仅含有参数的部位及其参数。
    private var organGroups: [(organ: BodyOrgan, items: [HeroItem])] {
        let items = heroItems
        return BodyOrgan.allCases.compactMap { organ in
            let own = items.filter { $0.organ == organ }
            return own.isEmpty ? nil : (organ, own)
        }
    }

    /// 当前轮播部位；参数：groups 为分组；返回值：选中的部位，失效或为空时回退到首个有参数的部位。
    private func currentOrgan(_ groups: [(organ: BodyOrgan, items: [HeroItem])]) -> BodyOrgan? {
        if let heroOrgan, groups.contains(where: { $0.organ == heroOrgan }) { return heroOrgan }
        return groups.first?.organ
    }

    /// 单项参数行；参数：item 为参数；返回值：参数名在上、数值与单位在下的紧凑行，数值从 0 滚动到实测值，完整信息供辅助功能朗读。
    private func heroRow(_ item: HeroItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let text = item.text {
                    Text(text).font(.system(.headline, design: .rounded, weight: .semibold)).foregroundStyle(.white)
                } else {
                    HoloNumber(value: item.value, decimals: item.decimals, font: .system(.title3, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(item.unit).font(.caption2).foregroundStyle(accent)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.title) \(item.text ?? (item.value.map { number($0, decimals: item.decimals) } ?? "未记录")) \(item.unit)")
    }

    /// 部位报告卡；参数：organ 为部位，items 为其参数；返回值：体检报告式的部位标题加参数列表，参数逐项错峰入场。
    private func organReport(_ organ: BodyOrgan, _ items: [HeroItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: organ.symbol).foregroundStyle(accent)
                Text(organ.title).font(.headline).foregroundStyle(.white)
                Spacer(minLength: 0)
            }
            Rectangle().fill(LinearGradient(colors: [accent.opacity(0.6), accent.opacity(0)], startPoint: .leading, endPoint: .trailing)).frame(height: 1)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                heroRow(item).holoAppear(Double(index) * 0.07)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoPanel(accent, radius: 18)
    }

    /// 呼吸、心率等节律来源；参数：id 为指标标识；返回值：有读数的值，否则 nil；用于让器官动画贴近真实数据。
    private func rhythmValue(_ id: String) -> Double? {
        snapshot?.metrics.first { $0.id == id }?.value
    }

    /// 全息舞台；参数：无；返回值：左侧内脏人体、右侧当前部位的参数报告；两者以标注线连接，每 5 秒自动轮换到下一个有参数的部位，下方选择器可点选并重置计时。
    private var heroStage: some View {
        let groups = organGroups
        let current = currentOrgan(groups)
        let height: CGFloat = 320
        return VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                HealthBodyFigure(
                    active: current, available: Set(groups.map(\.organ)),
                    heartRate: rhythmValue("heartRate") ?? rhythmValue("restingHeartRate"),
                    respiratoryRate: rhythmValue("respiratoryRate")
                )
                .frame(height: height)
                if let current, let items = groups.first(where: { $0.organ == current })?.items {
                    organReport(current, items)
                        .id(current)
                        .transition(.opacity.combined(with: .offset(x: 12)))
                }
            }
            .overlay {
                // 标注线：自报告卡左缘指向当前部位，切换部位时重新描绘。
                if let current {
                    HoloCalloutLine(
                        from: CGPoint(x: height * 0.52 + 14, y: height / 2),
                        to: CGPoint(x: current.center.x * height, y: current.center.y * height)
                    )
                    .id(current)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                }
            }
            .animation(.spring(duration: 0.6), value: current)
            if groups.count > 1 { organPicker(groups, current) }
        }
        // 轮播任务：标识为部位集合与计时戳，变化即重启；每 5 秒切换下一个部位，视图消失时自动取消。
        .task(id: groups.map(\.organ.rawValue).joined() + heroStamp.uuidString) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, groups.count > 1, let now = currentOrgan(groups),
                      let index = groups.firstIndex(where: { $0.organ == now }) else { continue }
                heroOrgan = groups[(index + 1) % groups.count].organ
            }
        }
    }

    /// 部位选择器；参数：groups 为分组，current 为当前部位；返回值：横向图标条，选中项以共享胶囊滑动并带轮播进度；点选后切换并重置轮播计时。
    private func organPicker(_ groups: [(organ: BodyOrgan, items: [HeroItem])], _ current: BodyOrgan?) -> some View {
        HStack(spacing: 6) {
            ForEach(groups, id: \.organ) { group in
                let selected = group.organ == current
                // 选择回调；参数、返回值：无；切换部位并重启 5 秒计时，避免刚点选就被轮换。
                Button {
                    withAnimation(.spring(duration: 0.45, bounce: 0.25)) { heroOrgan = group.organ }
                    heroStamp = UUID()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: group.organ.symbol).font(.subheadline)
                        Text(group.organ.title).font(.caption2)
                    }
                    .foregroundStyle(selected ? Color.black : Color.white.opacity(0.75))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background {
                        if selected {
                            ZStack(alignment: .bottomLeading) {
                                Capsule().fill(accent)
                                HoloProgress(duration: 5).id(heroStamp.uuidString + group.organ.rawValue)
                            }
                            .clipShape(Capsule())
                            .matchedGeometryEffect(id: "organSelection", in: groupNamespace)
                            .shadow(color: accent.opacity(0.5), radius: 6)
                        } else {
                            Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(group.organ.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    /// 静态主视觉；参数：无；返回值：较小的内脏人体加全部部位报告卡；用于「减少动态效果」或超大字号，所有参数同时可见且不轮播。
    private var staticHero: some View {
        VStack(spacing: 14) {
            HealthBodyFigure(active: nil, available: Set(organGroups.map(\.organ)), heartRate: nil, respiratoryRate: nil)
                .frame(height: 240)
            ForEach(organGroups, id: \.organ) { group in organReport(group.organ, group.items) }
        }
    }

    /// 饮食入口及符合适用条件时的每日能量参考；参数：无；返回值：主导航入口和可展开计算依据，不生成虚构目标。
    private var nutritionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink {
                NutritionView(observed: snapshot?.profile)
                    .id(store.cloudSessionID)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "fork.knife")
                        .font(.title3).foregroundStyle(accent)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(accent.opacity(0.14)))
                        .overlay(Circle().strokeBorder(accent.opacity(0.6), lineWidth: 1))
                    Text("饮食记录").font(.headline).foregroundStyle(.white)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold()).foregroundStyle(accent)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Rectangle()
                .fill(LinearGradient(colors: [accent.opacity(0.7), accent.opacity(0)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
            if let recommendation = profile.recommendation {
                VStack(alignment: .leading, spacing: 8) {
                    Text("每日能量参考").font(.subheadline).foregroundStyle(.white.opacity(0.65))
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            HoloNumber(value: recommendation.calories, decimals: 0, font: .system(.largeTitle, design: .rounded, weight: .semibold))
                                .foregroundStyle(LinearGradient(colors: [.white, accent], startPoint: .top, endPoint: .bottom))
                            Text("千卡 / 日").font(.subheadline).foregroundStyle(accent)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            HoloNumber(value: recommendation.calories, decimals: 0, font: .system(.largeTitle, design: .rounded, weight: .semibold))
                                .foregroundStyle(LinearGradient(colors: [.white, accent], startPoint: .top, endPoint: .bottom))
                            Text("千卡 / 日").font(.subheadline).foregroundStyle(accent)
                        }
                    }
                    DisclosureGroup("计算依据") {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("基础代谢", value: "\(number(recommendation.basalCalories, decimals: 0)) 千卡")
                            LabeledContent("活动系数", value: number(recommendation.activityMultiplier, decimals: 3))
                            Text("Mifflin–St Jeor 公式 × 活动系数")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .padding(.top, 10)
                    }
                    .font(.subheadline)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("每日能量参考").font(.subheadline).foregroundStyle(.white.opacity(0.65))
                    Text("—").font(.system(.title, design: .rounded, weight: .semibold)).foregroundStyle(.white)
                    if !profile.missingRequirements.isEmpty {
                        Text(profile.missingRequirements.joined(separator: "、"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .holoPanel(accent, radius: 24)
    }

    /// Apple 健康联接与读取状态；参数：无；返回值：显式授权按钮、必要权限说明及错误，始终不上传本机读数。
    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Label("Apple 健康", systemImage: "heart.text.clipboard")
                    .font(.headline).foregroundStyle(.white)
                Spacer()
                if reader.isLoading {
                    ProgressView().tint(accent).accessibilityLabel("正在读取健康数据")
                } else if connected && scope == displayedScope {
                    HStack(spacing: 8) {
                        HoloPulseDot()
                        Text("已联接").font(.caption).foregroundStyle(accent)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.5), value: connected)
            if !reader.isAvailable {
                Text("此设备不支持 Apple 健康")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                // 用户授权回调；参数、返回值：无；只有明确点击才允许系统请求健康读取权限。
                Button {
                    Task { await refresh(requestAuthorization: true) }
                } label: {
                    Label(connected ? "重新联接 Apple 健康" : "联接 Apple 健康", systemImage: "link")
                }
                .buttonStyle(HoloButtonStyle())
                .disabled(reader.isLoading || scope == nil)
                if !connected {
                    Text("读取你允许的健康数据，仅保留在本机。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if scope == displayedScope, let errorMessage = reader.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let readAt = snapshot?.readAt {
                Text("读取于 \(readAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 多指标分组概览；参数：无；返回值：共享胶囊滑动的分类筛选和逐项错峰入场的真实读数。
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HoloTitle(title: "健康指标", symbol: "chart.xyaxis.line")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MetricGroup.allCases) { group in
                        // 分类回调；输入为当前分组，输出无；仅切换视图，不重新授权或改变指标值。
                        Button {
                            withAnimation(.spring(duration: 0.45, bounce: 0.3)) { selectedGroup = group }
                        } label: {
                            Label(group.title, systemImage: group.symbol)
                                .font(.subheadline)
                                .foregroundStyle(selectedGroup == group ? Color.black : Color.white.opacity(0.8))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 34)
                                .background {
                                    if selectedGroup == group {
                                        Capsule().fill(accent).shadow(color: accent.opacity(0.7), radius: 8)
                                            .matchedGeometryEffect(id: "metricGroupSelection", in: groupNamespace)
                                    } else {
                                        Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedGroup == group ? .isSelected : [])
                    }
                }
                .padding(.vertical, 4)
            }
            // 切换分组时以分组为标识重建列表，使各行重新错峰入场。
            VStack(spacing: 10) {
                ForEach(Array(visibleMetrics.enumerated()), id: \.element.id) { index, metric in
                    metricRow(metric, index: index).holoScroll()
                }
            }
            .id(selectedGroup)
            if visibleMetrics.contains(where: { $0.value == nil }) {
                Text("— 表示未记录或未获读取权限")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// 渲染单项指标；参数：metric 为读取器提供的指标，允许数值与日期缺失，index 为组内序号用于错峰入场；返回值：真实值、单位与采样时间，不把缺失转为零。
    private func metricRow(_ metric: HealthMetric, index: Int) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: metric.symbol)
                .font(.body).foregroundStyle(accent)
                .frame(width: 38, height: 38)
                .background(Circle().fill(accent.opacity(0.12)))
                .overlay(Circle().strokeBorder(accent.opacity(0.5), lineWidth: 1))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(metric.title).font(.subheadline).foregroundStyle(.white)
                Text(metric.measuredAt.map { date in
                    date.formatted(date: .abbreviated, time: .shortened)
                } ?? "—")
                .font(.caption2).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                HoloNumber(value: metric.value, font: .system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text(metric.unit).font(.caption).foregroundStyle(accent)
            }
        }
        .padding(14)
        .holoPanel(accent, radius: 18)
        .holoAppear(Double(index) * 0.06)
        .accessibilityElement(children: .combine)
    }

    /// 次要云端入口；参数：无；返回值：明确独立的同步与报告导航，不因进入首页自动触发同步。
    private var cloudDestination: some View {
        NavigationLink {
            HealthCloudView(observed: snapshot?.profile).id(store.cloudSessionID)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "icloud").frame(width: 24).foregroundStyle(accent)
                Text("同步与报告")
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(accent)
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .holoPanel(accent, radius: 16)
        }
        .buttonStyle(.plain)
    }

    /// 本机资料清理入口；参数：无；返回值：确认按钮与可重试的删除结果，失败信息不会被普通刷新清除。
    private var cleanupSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 清理确认回调；参数、返回值：无；记录当前范围，实际删除只在确认后执行。
            Button("清理本机健康资料与餐食照片", role: .destructive) {
                cleanupScope = scope
                confirmingCleanup = true
            }
            .font(.subheadline)
            .frame(minHeight: 44)
            .disabled(scope == nil || scope != displayedScope)
            if let scope, let error = cleanupErrors[scope] {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // 重试回调；参数、返回值：无；复用已确认范围的幂等删除，不省略任何失败。
                Button("重试清理") {
                    cleanupScope = scope
                    clearLocalData()
                }
                .font(.subheadline)
            } else if let scope, cleanedScope == scope {
                Label("已清理本机资料", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 清理已确认身份的本机资料；参数：无；返回值：无；分别删除档案与照片并汇总错误，清除联接偏好和内存快照，不触碰 HealthKit 或服务器。
    private func clearLocalData() {
        guard let cleanupScope, cleanupScope == scope, cleanupScope == displayedScope else { return }
        var failures: [String] = []
        do {
            try HealthProfileStore.remove(owner: cleanupScope)
            manualProfile = HealthProfile()
        } catch {
            failures.append("身体档案：\(error.localizedDescription)")
        }
        do {
            try MealThumbnailStore.removeAll(owner: cleanupScope)
        } catch {
            failures.append("餐食照片：\(error.localizedDescription)")
        }
        // 即使某个文件删除失败，也停止后续自动读取；替换读取器使清理前仍在进行的请求不能恢复快照或联接标记。
        UserDefaults.standard.removeObject(forKey: connectionKey(cleanupScope))
        connected = false
        observedSnapshot = nil
        observationGeneration = UUID()
        reader = HealthDashboardReader()
        if failures.isEmpty {
            cleanupErrors.removeValue(forKey: cleanupScope)
            cleanedScope = cleanupScope
        } else {
            cleanupErrors[cleanupScope] = failures.joined(separator: "\n")
            cleanedScope = nil
        }
    }

    /// 格式化可缺失的有限数值；参数：value 为真实数值，decimals 为最多保留的小数位数（默认 1）；返回值：本地化数字或缺失占位，无副作用。
    private func number(_ value: Double?, decimals: Int = 1) -> String {
        guard let value, value.isFinite else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0...decimals)))
    }

    /// 重载当前身份的手动档案；参数：无；返回值：无；编辑器关闭和刷新时读取本地文件，未登录或身份不匹配时不展示旧档案。
    private func reloadManualProfile() {
        guard let scope, scope == displayedScope else {
            manualProfile = HealthProfile()
            return
        }
        manualProfile = HealthProfileStore.load(owner: scope) ?? HealthProfile()
    }

    /// 激活账号范围；参数：无；返回值：无；清空旧账号内存与界面状态，只恢复此身份明确选择过的健康联接。
    private func activateScope() async {
        let nextScope = scope
        observedSnapshot = nil
        observationGeneration = UUID()
        reader = HealthDashboardReader()
        displayedScope = nextScope
        manualProfile = HealthProfile()
        connected = false
        editingProfile = false
        confirmingCleanup = false
        cleanupScope = nil
        selectedGroup = .body
        guard let nextScope else { return }
        connected = UserDefaults.standard.bool(forKey: connectionKey(nextScope))
        reloadManualProfile()
        if connected { await refresh(requestAuthorization: false) }
    }

    /// 使旧观测立即失效并补读；参数：无；返回值：无；回到前台或跨日时调用，仅已联接账号可静默读取，进行中的明确授权不被取消。
    private func invalidateObservationsAndRefresh() {
        observedSnapshot = nil
        observationGeneration = UUID()
        guard scope != nil, scope == displayedScope, connected else { return }
        // 静默刷新任务；参数、返回值：无；当前读取若仍忙，由其完成分支依据有效期令牌补读。
        Task { await refresh(requestAuthorization: false) }
    }

    /// 刷新当前账号的健康资料；参数：requestAuthorization 仅可由明确联接按钮传 true；返回值：无；先清空已发布观测，成功才发布新结果；跨日或前台切换期间完成的读取必须静默补读，取消、换号或清理后丢弃结果。
    private func refresh(requestAuthorization: Bool) async {
        guard let currentScope = scope, currentScope == displayedScope else { return }
        reloadManualProfile()
        observedSnapshot = nil
        guard reader.isAvailable, !reader.isLoading, requestAuthorization || connected else { return }
        // 每轮使用全新读取器，失败时不能重新发布内部保留的旧快照；已开始的授权不因生命周期回调而被替换。
        let currentReader = HealthDashboardReader()
        reader = currentReader
        let generation = observationGeneration
        await currentReader.refresh(requestAuthorization: requestAuthorization)
        guard !Task.isCancelled, currentScope == scope, currentScope == displayedScope, currentReader === reader else { return }
        if requestAuthorization, currentReader.errorMessage == nil {
            cleanedScope = nil
            connected = true
            UserDefaults.standard.set(true, forKey: connectionKey(currentScope))
        }
        // 授权弹窗也可能造成前后台切换；保存明确联接结果后静默补读，避免丢失首次联接或把授权前观测用于计算。
        guard generation == observationGeneration else {
            if connected { await refresh(requestAuthorization: false) }
            return
        }
        if currentReader.errorMessage == nil {
            observedSnapshot = currentReader.snapshot
        }
    }

    /// 生成联接偏好键；参数：scope 为服务器与用户共同生成的散列；返回值：仅保存明确联接动作的本机偏好键，不包含健康数值。
    private func connectionKey(_ scope: String) -> String {
        "health.dashboard.connected.\(scope)"
    }

    /// 健康指标的固定浏览分组；分类仅影响排列，不以颜色表示健康好坏。
    private enum MetricGroup: String, CaseIterable, Identifiable {
        case body, activity, vitals, sleep, nutrition

        /// 分组稳定标识；参数：无；返回值：枚举原始字符串。
        var id: String { rawValue }

        /// 分组标题；参数：无；返回值：简短中文分类名称。
        var title: String {
            switch self {
            case .body: "身体"
            case .activity: "活动"
            case .vitals: "体征"
            case .sleep: "睡眠"
            case .nutrition: "饮食"
            }
        }

        /// 分组图标；参数：无；返回值：配合文字使用的系统符号名称。
        var symbol: String {
            switch self {
            case .body: "figure.stand"
            case .activity: "figure.walk"
            case .vitals: "waveform.path.ecg"
            case .sleep: "bed.double"
            case .nutrition: "fork.knife"
            }
        }

        /// 判断指标所属分类；参数：id 为读取器稳定标识；返回值：是否属于当前分类，新增未知指标归入体征以避免静默遗漏。
        func includes(_ id: String) -> Bool {
            let body = ["height", "weight", "age", "bmi", "bodyFat", "leanMass"]
            let activity = ["steps", "activeEnergy", "restingEnergy", "walkingDistance", "flights", "exerciseMinutes", "standMinutes", "workouts", "vo2Max", "walkingSpeed"]
            let sleep = ["sleep"]
            let nutrition = ["water", "dietaryEnergy"]
            switch self {
            case .body: return body.contains(id)
            case .activity: return activity.contains(id)
            case .sleep: return sleep.contains(id)
            case .nutrition: return nutrition.contains(id)
            case .vitals: return !body.contains(id) && !activity.contains(id) && !sleep.contains(id) && !nutrition.contains(id)
            }
        }
    }
}
