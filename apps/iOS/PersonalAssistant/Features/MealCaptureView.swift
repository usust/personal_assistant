import SwiftUI
import PhotosUI
import AVFoundation

/// 拍照、外发同意、识别核对与确认保存分步进行，图片仅留在当前页面内存。
struct MealCaptureView: View {
    let date: String
    let recorded: Double
    let goal: Double?
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var photo: PhotosPickerItem?
    @State private var image: Data?
    @State private var showingCamera = false
    @State private var photoRequest = UUID()
    @State private var configID = 0
    @State private var consent = false
    @State private var confirmingAnalysis = false
    @State private var busy = false
    @State private var importing = false
    @State private var error: String?
    @State private var configError: String?
    @State private var items: [MealItemDraft] = []
    @State private var note = ""
    @State private var mealType = "lunch"
    @State private var recordID = UUID().uuidString.lowercased()
    @State private var submitted: [String: Any]?

    /// 获取当前配置；参数：无；返回值：本人可用目录中的配置或 nil；无副作用。
    private var config: AIConfig? { store.configs.first { $0.id == configID } }
    /// 汇总有效草稿；参数：无；返回值：待确认千卡合计；保存仍要求全部项目合法。
    private var total: Double { items.compactMap(\.item).reduce(0) { $0 + $1.calories } }
    /// 锁定网络结果未确认的草稿；参数：无；返回值：是否禁止改动内容；同一幂等键重试始终发送同一正文。
    private var locked: Bool { busy || importing || submitted != nil }
    /// 获取所选配置版本；参数：无；返回值：配置更新时间或 nil，供授权失效监听使用；无副作用。
    private var configVersion: String? { config?.updated_at }
    /// 判断照片授权开关是否可用；参数：无；返回值：草稿未锁定且照片、配置齐全时为 true；不代表已同意外发。
    private var canGiveConsent: Bool {
        guard !locked, image != nil, let _ = config else { return false }
        return true
    }
    /// 判断是否可发起视觉分析；参数：无；返回值：已同意且所选配置版本有效时为 true；无网络副作用。
    private var canAnalyze: Bool {
        guard canGiveConsent, consent, let config else { return false }
        return !config.updated_at.isEmpty
    }
    /// 判断是否可确认保存；参数：无；返回值：草稿未锁定且所有项目有效时为 true；未知保存结果只能通过原快照重试。
    private var canSave: Bool { !locked && NutritionMath.validMeal(items, note: note) }
    /// 构建外发对象文案；参数：无；返回值：所选服务的说明或 nil；将字符串插值与视图泛型推断分开。
    private var destinationDescription: String? {
        guard let config else { return nil }
        return "照片将经当前服务器发送至 \(config.provider_name)（\(config.base_url)）的 \(config.model_name)。"
    }
    /// 获取分析确认标题；参数：无；返回值：首次分析或覆盖现有草稿的确认标题；无副作用。
    private var analysisConfirmationTitle: String {
        items.isEmpty ? "发送照片并分析？" : "重新分析会替换当前食物草稿，继续？"
    }
    /// 构建拍照分析流程；参数：无；返回值：分段类型检查的表单与操作，不自动保存或上传健康数据。
    var body: some View {
        NavigationStack {
            captureForm
        }
    }

    /// 构建表单容器；参数：无；返回值：原有导航、授权监听和弹层；拆分内容以避免单个 ViewBuilder 表达式过大。
    private var captureForm: some View {
        Form {
            photoSection
            analysisSection
            foodSections
            statusSections
        }
        .navigationTitle("分析用餐")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { captureToolbar }
        .interactiveDismissDisabled(locked)
        .task { await loadConfigs() }
        .onChange(of: photo) { _, selected in Task { await importPhoto(selected) } }
        .onChange(of: configID) { _, _ in consent = false }
        .onChange(of: configVersion) { _, _ in consent = false }
        .fullScreenCover(isPresented: $showingCamera) { cameraContent }
        .confirmationDialog(analysisConfirmationTitle, isPresented: $confirmingAnalysis, titleVisibility: .visible) {
            Button("发送并分析") { Task { await analyze() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅发送本张照片至所选 AI 服务；不会发送健康日汇总。")
        }
    }

    /// 构建照片来源分组；参数：无；返回值：内存预览、拍照、相册与处理进度；不自动发起网络请求。
    private var photoSection: some View {
        Section {
            if let image, let preview = UIImage(data: image) {
                Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 220)
                    .accessibilityLabel("本次待分析餐食照片")
            }
            Button("拍照", systemImage: "camera") { Task { await openCamera() } }.disabled(locked)
            PhotosPicker(selection: $photo, matching: .images, photoLibrary: .shared()) {
                Label("从相册选择", systemImage: "photo")
            }.disabled(locked)
            if importing { ProgressView("正在处理照片…") }
        }
    }

    /// 构建独立授权分组；参数：无；返回值：显式 header/footer 的合法 Section，开关和按钮只接收已确定类型的 Bool。
    private var analysisSection: some View {
        Section {
            configurationFields
            Toggle("同意发送本张照片至所选 AI 服务", isOn: $consent)
                .disabled(!canGiveConsent)
            Button("分析用餐热量") { confirmingAnalysis = true }
                .buttonStyle(.glassProminent)
                .disabled(!canAnalyze)
        } header: {
            Text("照片分析")
        } footer: {
            Text("照片不保存到饮食记录；识别仅估算可见食物，核对后才保存。")
        }
    }

    /// 构建配置字段；参数：无；返回值：可用配置选择、服务说明及加载错误，不改变外发同意状态。
    @ViewBuilder private var configurationFields: some View {
        if let configError {
            InlineError(message: configError)
            Button("重新加载 AI 配置") { Task { await loadConfigs() } }.disabled(locked)
        }
        Picker("AI 配置", selection: $configID) {
            Text("请选择视觉模型").tag(0)
            ForEach(store.configs) { config in Text(config.name).tag(config.id) }
        }.disabled(locked)
        if let destinationDescription {
            Text(destinationDescription).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// 构建餐食区域；参数：无；返回值：空草稿入口或核对、比较分组；无直接持久化副作用。
    @ViewBuilder private var foodSections: some View {
        if items.isEmpty {
            Section {
                Button("手动添加食物", systemImage: "plus") { items.append(MealItemDraft()) }.disabled(locked)
            }
        } else {
            reviewSection
            mealSummarySection
        }
    }

    /// 构建错误、进度和安全重试区域；参数：无；返回值：不隐藏未确认保存状态的分组；重试沿用冻结正文。
    @ViewBuilder private var statusSections: some View {
        if let error { Section { InlineError(message: error) } }
        if busy { Section { ProgressView(submitted == nil ? "正在分析…" : "正在保存…") } }
        if submitted != nil && !busy {
            Section {
                Text("保存结果尚未确认，请重试核对。重试不会重复创建记录。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("重试保存") { Task { await save() } }
            }
        }
    }

    /// 构建导航操作；参数：无；返回值：取消和保存工具栏，未知保存结果期间保留离开锁定；无自动写入。
    @ToolbarContentBuilder private var captureToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("取消") { dismiss() }.disabled(locked)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("保存记录") { Task { await save() } }
                .buttonStyle(.glassProminent)
                .disabled(!canSave)
        }
    }

    /// 构建相机弹层；参数：无；返回值：系统相机，回调 data 为内存照片或 nil，返回值无；取消不改变现有图片。
    private var cameraContent: some View {
        MealCamera { data in
            showingCamera = false
            if let data { acceptImage(data) }
        }.ignoresSafeArea()
    }

    /// 构建核对表单；参数：无；返回值：餐次、独立类型检查的食物编辑行和备注；无直接写入。
    private var reviewSection: some View {
        Section("核对估算") {
            LabeledContent("记录日期", value: date)
            Picker("餐次", selection: $mealType) {
                Text("早餐").tag("breakfast"); Text("午餐").tag("lunch")
                Text("晚餐").tag("dinner"); Text("加餐").tag("snack")
            }
            ForEach($items) { draft in foodEditor(draft) }
            if items.count < 20 { Button("添加食物", systemImage: "plus") { items.append(MealItemDraft()) } }
            TextField("备注", text: $note, axis: .vertical).lineLimit(2...5)
            if note.utf8.count > 1500 { Text("备注过长，请缩短").font(.caption).foregroundStyle(.orange) }
        }.disabled(locked)
    }

    /// 构建单项编辑器；参数：draft 为当前有效食物绑定；返回值：独立子视图，删除回调无参数和返回值，按稳定 ID 移除且不写服务器。
    private func foodEditor(_ draft: Binding<MealItemDraft>) -> some View {
        let id = draft.wrappedValue.id
        return MealItemEditor(item: draft) { items.removeAll { $0.id == id } }
    }

    /// 构建本餐与全天比较；参数：无；返回值：合法草稿的估算合计及手动目标比较；保留估算限制说明。
    private var mealSummarySection: some View {
        Section {
            LabeledContent("本餐估算", value: "约 \(total.formatted(.number.precision(.fractionLength(0)))) 千卡")
            if NutritionMath.validMeal(items, note: note) {
                Text(NutritionMath.comparison(recorded: recorded, adding: total, goal: goal))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        } footer: {
            Text("修改克数会按比例调整热量，也可直接修正热量。高于目标不代表需要跳餐或额外运动补偿。")
        }
    }
    /// 加载可用视觉配置目录；参数：无；返回值：无；不自动同意外发，失败不覆盖食物草稿。
    @MainActor private func loadConfigs() async {
        let session = store.cloudSessionID
        do {
            try await store.loadConfigs()
            guard session == store.cloudSessionID, !Task.isCancelled else { return }
            configError = nil
            if configID == 0 { configID = store.configs.first?.id ?? 0 }
        } catch { if session == store.cloudSessionID { configError = error.localizedDescription } }
    }
    /// 请求相机权限；参数：无；返回值：无；设备不支持或拒绝时允许继续使用相册，不直接跳系统设置。
    @MainActor private func openCamera() async {
        guard !locked else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { error = "当前设备无法拍照，请从相册选择。"; return }
        let session = store.cloudSessionID
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed: Bool
        if status == .authorized { allowed = true }
        else if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
        else { allowed = false }
        guard session == store.cloudSessionID else { return }
        if allowed { error = nil; showingCamera = true }
        else { error = "相机权限未开启，可在系统设置中允许，或从相册选择。" }
    }
    /// 读取用户选择的照片；参数：selected 为单张选择或 nil；返回值：无；最新选择与本人会话有效才接收，失败保留旧图，不发网络。
    @MainActor private func importPhoto(_ selected: PhotosPickerItem?) async {
        guard let selected, !busy, submitted == nil else { return }
        let session = store.cloudSessionID, request = UUID()
        photoRequest = request; importing = true; consent = false
        defer { if photoRequest == request { importing = false } }
        do {
            guard let data = try await selected.loadTransferable(type: Data.self) else { throw APIError(status: 0, message: "无法读取照片，请重新选择。") }
            guard session == store.cloudSessionID, photoRequest == request, !Task.isCancelled else { return }
            acceptImage(data)
        } catch { if session == store.cloudSessionID, photoRequest == request { self.error = error.localizedDescription } }
    }
    /// 标准化并去除照片元数据；参数：data 为相册/相机原始字节；返回值：无；仅保存内存JPEG，图片改变后重新要求授权。
    @MainActor private func acceptImage(_ data: Data) {
        do {
            image = try PaymentImageProcessor.normalizedImage(data)
            // 新照片不能沿用旧图的识别资料，避免识别失败后误保存上一餐；照片从不自动触发识别或保存。
            items = []; note = ""; consent = false; error = nil
        }
        catch { self.error = "照片格式或尺寸无效，请换一张清晰的用餐照片。"; consent = false }
    }
    /// 外发本张照片并取得可核对结果；参数：无；返回值：无；使用配置版本防止授权对象变化，失败保留原草稿，每次调用后撤销同意。
    @MainActor private func analyze() async {
        guard !locked, consent, let image, let config, !config.updated_at.isEmpty else { return }
        let session = store.cloudSessionID
        busy = true; error = nil
        defer { busy = false; consent = false }
        do {
            let result: MealAnalysisResult = try await store.api.request("/health-management/meal-analysis", method: "POST", body: ["config_id": config.id, "config_version": config.updated_at, "consent": true, "image": "data:image/jpeg;base64," + image.base64EncodedString()])
            guard session == store.cloudSessionID, !Task.isCancelled else { return }
            guard result.valid else { throw APIError(status: 502, message: "识别结果无效，请重试或手动记录。") }
            guard result.recognized else { error = "未能识别餐食，请换一张清晰照片或手动添加食物。"; return }
            items = result.items.map { MealItemDraft($0) }; note = result.note
        } catch {
            guard session == store.cloudSessionID else { return }
            self.error = nutritionFailure(error)
            if let api = error as? APIError, api.status == 409 {
                // 配置变化后重新读取外发对象，但不沿用同意状态；用户须查看新配置并再次同意。
                consent = false; await loadConfigs()
            }
        }
    }
    /// 确认保存本餐；参数：无；返回值：无；使用稳定UUID和冻结正文安全重试，网络结果未知时不允许修改后再次创建。
    @MainActor private func save() async {
        guard !busy, !importing, submitted != nil || NutritionMath.validMeal(items, note: note) else { return }
        if submitted == nil {
            submitted = ["id": recordID, "date": date, "meal_type": mealType, "items": items.compactMap(\.item).map { ["name": $0.name, "grams": $0.grams, "calories": $0.calories] as [String: Any] }, "note": note]
        }
        let session = store.cloudSessionID
        busy = true; error = nil; defer { busy = false }
        do {
            let _: MealRecord = try await store.api.request("/health-management/meals", method: "POST", body: submitted)
            guard session == store.cloudSessionID else { return }
            image = nil; dismiss()
        } catch {
            guard session == store.cloudSessionID else { return }
            self.error = nutritionFailure(error)
            // 明确的写入前校验/授权失败可以继续修改；超时、5xx及解码失败保持快照，以相同幂等键核对。
            if let api = error as? APIError, [400, 401, 403, 404, 413, 422].contains(api.status) { submitted = nil }
        }
    }
}

/// 单个食物编辑器单独类型检查，不把动态绑定和份量换算嵌入整个页面的 ViewBuilder。
private struct MealItemEditor: View {
    @Binding var item: MealItemDraft
    /// 删除操作；参数：无；返回值：无；父页按稳定 ID 移除草稿，不调用接口。
    let onRemove: () -> Void

    /// 构建克数绑定；参数：无；返回值：明确为 String 的绑定，setter 的 value 为新文本；修改后仍按原密度换算热量。
    private var gramsBinding: Binding<String> {
        Binding<String>(get: { item.grams }, set: { value in
            var draft = item
            draft.changeGrams(value)
            item = draft
        })
    }
    /// 构建热量绑定；参数：无；返回值：明确为 String 的绑定，setter 的 value 为新文本；手动修改同步更新换算密度。
    private var caloriesBinding: Binding<String> {
        Binding<String>(get: { item.calories }, set: { value in
            var draft = item
            draft.changeCalories(value)
            item = draft
        })
    }
    /// 构建独立食物行；参数：无；返回值：名称、克数、热量、校验提示及移除操作；只修改当前绑定草稿。
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("食物名称", text: $item.name)
            LabeledContent("份量（克）") {
                TextField("克", text: gramsBinding)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            LabeledContent("估算热量（千卡）") {
                TextField("千卡", text: caloriesBinding)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
            }
            if item.item == nil {
                Text("请填写名称、有效克数及热量").font(.caption).foregroundStyle(.orange)
            }
            Button("移除食物", role: .destructive, action: onRemove)
        }.padding(.vertical, 4)
    }
}

/// 系统相机只负责拍摄，不写入相册，也不申请麦克风权限。
private struct MealCamera: UIViewControllerRepresentable {
    let onCapture: (Data?) -> Void
    /// 构造系统相机；参数：context 为桥接上下文；返回值：仅静态照片相机控制器，设备可用性已在展示前检查。
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera; picker.mediaTypes = ["public.image"]
        picker.delegate = context.coordinator; return picker
    }
    /// 同步控制器；参数：uiViewController 为相机，context 为桥接上下文；返回值：无；相机配置固定，无额外副作用。
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    /// 创建代理；参数：无；返回值：转交照片或取消的代理；不持久化图片。
    func makeCoordinator() -> Coordinator { Coordinator(onCapture: onCapture) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data?) -> Void
        /// 初始化拍摄代理；参数：onCapture 接收内存JPEG或取消nil、无返回值；返回值：代理；无副作用。
        init(onCapture: @escaping (Data?) -> Void) { self.onCapture = onCapture }
        /// 处理拍照；参数：picker 为控制器，info 为系统照片；返回值：无；只交付内存数据，不保存相册或EXIF。
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onCapture((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.9))
        }
        /// 处理取消；参数：picker 为相机控制器；返回值：无；交付nil关闭，不改写现有照片。
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onCapture(nil) }
    }
}
