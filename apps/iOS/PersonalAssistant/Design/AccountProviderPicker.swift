import SwiftUI
import UIKit

/// 账户品牌图标保留原始配色；参数由属性传入：provider 为机构，size 为正数尺寸；无业务副作用。
struct AccountProviderIcon: View {
    let provider: AccountProvider
    var size: CGFloat = 28

    var body: some View {
        Group {
            // 所有机构均有可见图标；资源缺失时使用系统机构图标，不渲染空白。
            if let image = AccountIconImage.image(named: "finance-\(provider.icon)") {
                // 银行与产品标志使用素材原色，避免按钮或列表的 tint 覆盖品牌配色。
                Image(uiImage: image).renderingMode(.original).resizable().scaledToFit()
            } else {
                Image(systemName: provider.type == "bank" ? "building.columns.fill" : "wallet.bifold.fill")
                    .resizable().scaledToFit().padding(5).foregroundStyle(.white).background(Color.orange, in: Circle())
            }
        }.frame(width: size, height: size).clipped()
            .accessibilityHidden(true)
    }
}

/// 统一品牌素材的视觉边界与透明背景；去除外围白底和留白，不改原始资源或封闭的内部白色细节。
@MainActor private enum AccountIconImage {
    /// 初始化有限缓存；参数：无；返回值：最多缓存 128 个标准化图标的容器，无磁盘写入。
    private static let cache: NSCache<NSString, UIImage> = {
        let value = NSCache<NSString, UIImage>(); value.countLimit = 128
        return value
    }()

    /// 读取、清除外围白底并按有效图案裁剪；参数：name 为资产目录名称；返回值：明暗模式通用的透明图标，资源缺失返回 nil，无法分析时保留原图；结果仅缓存在内存。
    static func image(named name: String) -> UIImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        guard let original = UIImage(named: name) else { return nil }
        let side = 256
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        // 绘制回调输入画布上下文，返回无；保留素材长宽比，用统一像素格式分析白边。
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let ratio = min(CGFloat(side) / original.size.width, CGFloat(side) / original.size.height)
            let width = original.size.width * ratio, height = original.size.height * ratio
            original.draw(in: CGRect(x: (CGFloat(side)-width)/2, y: (CGFloat(side)-height)/2, width: width, height: height))
        }
        guard let cg = rendered.cgImage else { return original }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        var bounds: CGRect?
        // 缓冲回调输入可写 RGBA 字节，返回无；先从资产生成统一像素格式。
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        AccountIconBackground.remove(from: &pixels, width: side, height: side)
        var cleaned: CGImage?
        // 缓冲回调输入已去底的 RGBA 字节，返回无；裁剪与成像使用同一坐标系，避免非对称图案上下裁错。
        pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
            let data = bytes.bindMemory(to: UInt8.self)
            var left = side, top = side, right = -1, bottom = -1
            for y in 0..<side {
                for x in 0..<side {
                    let offset = (y * side + x) * 4, alpha = Int(data[offset + 3])
                    if alpha > 24 && min(Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])) < alpha * 96 / 100 {
                        left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                    }
                }
            }
            if right >= left && bottom >= top {
                bounds = CGRect(x: max(0, left-1), y: max(0, top-1), width: min(side-1, right+1)-max(0, left-1)+1, height: min(side-1, bottom+1)-max(0, top-1)+1)
            }
            cleaned = context.makeImage()
        }
        // 裁剪回调接收图案边界并返回裁剪图；映射回调接收像素图并返回 UIKit 图像，失败时保留原图。
        let result = bounds.flatMap { cleaned?.cropping(to: $0) }.map { UIImage(cgImage: $0) } ?? original
        cache.setObject(result, forKey: name as NSString)
        return result
    }
}

/// 交易中的账户选项使用机构图标和账户别名，便于辨认同类型的多个账户。
struct AccountChoiceLabel: View {
    let account: FinancialAccount

    var body: some View {
        Label {
            Text(account.name)
        } icon: {
            AccountProviderIcon(provider: .resolve(type: account.accountType, institution: account.institution))
        }
    }
}

/// 按资金、信用、充值、理财、应收、应付展示账户类型；银行卡再进入机构选择。
struct AccountProviderPicker: View {
    @Binding var selection: AccountProvider
    /// 由编辑页关闭整个选择路径；参数、返回值均无，不提交账户。
    let onComplete: () -> Void
    @State private var query = ""

    private var kinds: [AccountKind] { AccountKindCatalog.bundled?.items ?? [] }
    private var filtered: [AccountKind] { kinds.filter { $0.provider.matches(query) } }

    var body: some View {
        List {
            if AccountKindCatalog.bundled == nil {
                Section { InlineError(message: "账户类型加载失败，可手动添加。") }
            }
            ForEach(AccountKindCatalog.bundled?.sections ?? []) { section in
                let items = filtered.filter { $0.section == section.id }
                if !items.isEmpty {
                    Section {
                        ForEach(items) { kind in
                            if !kind.route.isEmpty {
                                NavigationLink {
                                    AccountProviderList(title: kind.route == "bank" ? "选择储蓄卡银行" : "选择信用卡银行",
                                                        providers: AccountProvider.selectableBanks, selectedID: selection.id,
                                                        creditCards: kind.route == "creditCard", onSelect: choose)
                                } label: { kindLabel(kind) }
                            } else {
                                // 点击回调无参数、无返回值；将类型对应机构写入父表单草稿。
                                Button { choose(kind.provider) } label: {
                                    HStack { kindLabel(kind); Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
                                }.buttonStyle(.plain)
                            }
                        }
                    } header: { Text(section.title).font(.headline).foregroundStyle(.primary).textCase(nil).padding(.vertical, 8) }
                }
            }
            if !query.isEmpty && filtered.isEmpty { ContentUnavailableView.search(text: query) }
            Section { NavigationLink("自定义账户类型") { CustomAccountProviderEditor(onSelect: choose) } }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("选择类型").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索账户类型")
    }

    /// 绘制账户类型行；参数：kind 为共享目录项；返回值：圆形图标与名称组成的视图；无副作用。
    private func kindLabel(_ kind: AccountKind) -> some View {
        HStack(spacing: 14) {
            AccountProviderIcon(provider: kind.provider, size: 38)
            Text(kind.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(minHeight: 52).padding(.vertical, 3)
    }

    /// 更新草稿并返回编辑页；参数：provider 为用户选项；返回值：无；同一持久化机构再次选择保留历史原值，不向服务器保存。
    private func choose(_ provider: AccountProvider) {
        if selection.id != provider.id { selection = provider }
        onComplete()
    }
}

/// 分类内及信用卡机构列表；onSelect 输入选中的机构、返回无，由上级负责更新草稿和导航返回。
private struct AccountProviderList: View {
    let title: String
    let providers: [AccountProvider]
    let selectedID: String
    var creditCards = false
    let onSelect: (AccountProvider) -> Void
    @State private var query = ""

    private var results: [AccountProvider] { providers.filter { $0.matches(query) } }

    var body: some View {
        List {
            if creditCards {
                Section {
                    Text("请选择你已有信用卡的发卡机构。欠款记负数，授信额度不计入余额。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("\(results.count) 个机构") {
                ForEach(results) { item in
                    let provider = creditCards ? item.creditCard() : item
                    AccountProviderRow(provider: provider, selected: selectedID == provider.id, onSelect: onSelect)
                }
            }
            if results.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "名称、地区、拼音或首字母")
    }
}

/// 机构行仅展示图标、长名称与选中状态；onSelect 接收机构并返回无，由父页面处理选择。
private struct AccountProviderRow: View {
    let provider: AccountProvider
    let selected: Bool
    let onSelect: (AccountProvider) -> Void

    var body: some View {
        // 点击回调无参数、无返回值；只把本行机构传回父页面，不执行持久化。
        Button { onSelect(provider) } label: {
            HStack(spacing: 12) {
                AccountProviderIcon(provider: provider, size: 32)
                Text(provider.name).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }.padding(.vertical, 4).frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 自定义机构仅写当前账户；onSelect 输入校验后的机构并返回无，不添加到公共目录。
private struct CustomAccountProviderEditor: View {
    let onSelect: (AccountProvider) -> Void
    @State private var name = ""
    @State private var kind = "bank"

    private var provider: AccountProvider? {
        AccountProvider.custom(name: name, type: kind == "creditCard" ? "bank" : kind == "credit" ? "other" : kind,
                               credit: kind == "creditCard" || kind == "credit")
    }

    var body: some View {
        Form {
            Section("自定义机构") {
                TextField("银行、合作社或平台名称", text: $name)
                Picker("账户类别", selection: $kind) {
                    Text("银行／信用社／合作社").tag("bank")
                    Text("银行信用卡").tag("creditCard")
                    Text("平台信用／借款账户").tag("credit")
                    Text("支付钱包／其他账户").tag("other")
                    Text("投资账户").tag("investment")
                }
            }
            Section {
                Text("名称仅用于当前账户。欠款记负数，信用额度不计入余额。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && provider == nil {
                    InlineError(message: "名称过长，请使用较短的机构名称。")
                }
            }
        }
        .navigationTitle("手动添加机构").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                // 确认回调无参数、无返回值；有效值交回上级草稿，未确认前不修改账户。
                Button("选用") { if let provider { onSelect(provider) } }.disabled(provider == nil)
            }
        }
    }
}
