import SwiftUI
import UniformTypeIdentifiers

/// 系统文件保存面板的只读数据载体；文档不持有账号、凭证或活动数据库文件。
private nonisolated struct BackupFileDocument: FileDocument {
    /// 声明可读取格式；参数：无；返回值：JSON 类型数组，无副作用。
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    /// 包装已完成校验的导出数据；参数：data 为完整 JSON 字节；返回值：文档，无磁盘副作用。
    init(data: Data) { self.data = data }

    /// 满足系统文档读取协议；参数：configuration 为系统提供的文件；返回值：文档；非普通文件抛错，不执行业务导入。
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = contents
    }

    /// 向系统提交文件内容；参数：configuration 为保存配置；返回值：完整 JSON 的文件包装器；由系统选择目标并完成写入，不直接操作用户目录。
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct DataExportView: View {
    @Environment(AppStore.self) private var store
    @State private var scope: DataBackup.Scope = .account
    @State private var generating = false
    @State private var exporting = false
    @State private var document = BackupFileDocument(data: Data())
    @State private var filename = "PersonalAssistant-backup.json"
    @State private var error: String?
    @State private var result: String?
    @State private var exportTask: Task<Void, Never>?

    /// 构建导出页面；参数：无；返回值：范围选择、生成进度及系统文件保存入口；游客可离线导出本机账本，全部导出要求登录。
    var body: some View {
        Form {
            Section {
                Picker("导出范围", selection: $scope) {
                    if store.canUseCloud { Text(DataBackup.Scope.account.title).tag(DataBackup.Scope.account) }
                    Text(DataBackup.Scope.local.title).tag(DataBackup.Scope.local)
                }.disabled(generating || exporting)
                    .accessibilityIdentifier("backupScope")
            } footer: {
                Text(scope == .account ? "包含云端数据和当前本机账本。备份未加密。" : "仅当前本机账本，包含未同步记录。备份未加密。")
            }
            Section {
                // 点击回调无输入和返回；启动可取消的生成任务，成功后才打开系统保存面板。
                Button {
                    exportTask = Task { await prepareExport() }
                } label: {
                    HStack {
                        Label(generating ? "正在生成" : "导出数据", systemImage: "square.and.arrow.up")
                        Spacer()
                        if generating { ProgressView() }
                    }
                }.disabled(generating || exporting || store.finance == nil || store.isAuthenticating)
                    .accessibilityIdentifier("exportBackup")
                if let result { Text(result).font(.footnote).foregroundStyle(.secondary) }
            }
            if let error { InlineError(message: error) }
            if let storageError = store.localStorageError { InlineError(message: storageError) }
        }
        .navigationTitle("数据导出").navigationBarTitleDisplayMode(.inline)
        .fileExporter(isPresented: $exporting, document: document, contentTypes: [.json], defaultFilename: filename) { outcome in
            // 保存回调输入系统结果、返回无；仅系统确认写入成功才提示成功，取消不作为失败，随后释放含个人数据的内存副本。
            switch outcome {
            case .success: result = "已导出"
            case .failure(let failure):
                if (failure as NSError).code != NSUserCancelledError { error = failure.localizedDescription }
            }
            document = BackupFileDocument(data: Data())
        } onCancellation: {
            // 取消回调无输入和返回；取消系统面板也立即释放完整备份，避免大文件副本常驻页面状态。
            document = BackupFileDocument(data: Data())
        }
        // 首次出现无输入和返回；游客默认本机范围，不发网络请求。
        .onAppear { if !store.canUseCloud { scope = .local } }
        // 云权限回调输入旧、新权限、返回无；认证失效后收回全部导出选项，避免无效选择。
        .onChange(of: store.canUseCloud) { _, available in if !available { scope = .local } }
        // 范围回调输入旧、新值、返回无；不复用上一范围的成功或错误信息。
        .onChange(of: scope) { _, _ in result = nil; error = nil }
        // 离页回调无输入和返回；取消网络生成，避免页面关闭后继续打开保存面板。
        .onDisappear { exportTask?.cancel() }
    }

    /// 准备文件并展示保存面板；参数：无；返回值：无；错误保留页面可重试，取消不显示错误，生成成功不等同文件已保存。
    @MainActor
    private func prepareExport() async {
        generating = true; error = nil; result = nil
        defer { generating = false }
        do {
            let data = try await store.exportBackup(scope: scope)
            try Task.checkCancellation()
            document = BackupFileDocument(data: data)
            filename = DataBackup.filename()
            exporting = true
        } catch {
            guard !(error is CancellationError), !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
