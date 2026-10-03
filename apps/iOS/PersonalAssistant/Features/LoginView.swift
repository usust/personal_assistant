import SwiftUI

struct LoginView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var account = ""
    @State private var password = ""
    @State private var answer = ""
    @State private var captcha: Captcha?
    @State private var error: String?
    @State private var busy = false
    @State private var captchaBusy = false
    @State private var registering = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "square.stack.3d.up.fill").font(.system(size: 42)).foregroundStyle(.teal)
                            .padding(20).glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24))
                        Text("让每一天，\n更有条理。").font(.largeTitle.bold())
                        Text("任务、收支与灵感，在这里相遇。").foregroundStyle(.secondary)
                    }.padding(.vertical, 18).listRowBackground(Color.clear)
                }
                Section("连接你的服务") {
                    TextField("https://example.com/api", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(busy || captchaBusy)
                        .onChange(of: server) { _, _ in captcha = nil; answer = "" }
                }
                Section("登录") {
                    TextField("账号", text: $account).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password).textContentType(.password)
                    HStack {
                        TextField("验证码", text: $answer).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button { Task { await refreshCaptcha() } } label: {
                            if captchaBusy { ProgressView() }
                            else if let captcha, let encoded = captcha.image.split(separator: ",").last,
                                    let data = Data(base64Encoded: String(encoded)), let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().frame(width: 140, height: 48).clipShape(.rect(cornerRadius: 10))
                            } else { Text("获取验证码") }
                        }.disabled(captchaBusy || busy).accessibilityLabel("刷新图片验证码")
                    }
                    if let message = error ?? store.sessionError { InlineError(message: message) }
                    Button { Task { await login() } } label: {
                        HStack { Spacer(); if busy { ProgressView() } else { Text("登录 Personal Assistant").bold() }; Spacer() }
                    }.disabled(busy || captchaBusy || captcha == nil || account.isEmpty || password.isEmpty || answer.isEmpty)
                }
                Section { Button("创建账号") { do { try store.setServer(server); registering = true } catch { self.error = error.localizedDescription } }.disabled(captchaBusy) }
            }.disabled(busy).frame(maxWidth: 680).frame(maxWidth: .infinity).background(Color(uiColor: .systemGroupedBackground))
                .task { server = store.api.baseURL; await refreshCaptcha() }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) } }
                .sheet(isPresented: $registering) { UserEditor(user: nil, publicRegistration: true) }
        }
    }
    /// 获取新挑战；参数：无；返回值：无；更新服务器和验证码，网络失败展示错误，不保留旧挑战。
    private func refreshCaptcha() async {
        captchaBusy = true; captcha = nil; answer = ""
        defer { captchaBusy = false }
        do { try store.setServer(server); captcha = try await store.api.request("/auth/captcha"); error = nil }
        catch { self.error = error.localizedDescription }
    }
    /// 提交一次登录；参数：无；返回值：无；消费验证码，失败自动刷新并保留错误，密码仅驻留表单。
    private func login() async {
        guard let captcha else { return }
        busy = true
        defer { busy = false }
        do { try await store.login(account: account.trimmingCharacters(in: .whitespaces), password: password, captcha: captcha, answer: answer); password = ""; dismiss() }
        catch { let message = error.localizedDescription; await refreshCaptcha(); self.error = message }
    }
}
