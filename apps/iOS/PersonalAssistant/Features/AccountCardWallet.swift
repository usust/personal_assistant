import SwiftUI

/// 账单内的钱包卡片；卡面缓存与账户财务资料分离，所有编辑仍由外层统一保存。
struct AccountCardWallet: View {
    @Binding var cards: [AccountCard]
    let provider: AccountProvider
    let accountID: Int?
    @Environment(AppStore.self) private var store
    @State private var stackIDs: [String] = []
    @State private var artwork: [String: SavedCardArtwork] = [:]
    @State private var menuOpen = false
    @State private var editingID: String?
    @State private var revealedID: String?
    @ScaledMetric(relativeTo: .body) private var editorHeight: CGFloat = 210

    /// 读取最前层卡片；参数：无；返回值：卡堆末位的完整卡面，无卡时为 nil。
    private var selectedCard: AccountCard? { displayedCards.last }
    /// 生成从后层到前层的卡堆；参数：无；返回值：保留已有槽位，移除失效卡片并把新增卡放到前层，使用本机保存的顺序。
    private var displayedCards: [AccountCard] {
        let existing = stackIDs.compactMap { id in cards.first { $0.id == id } }
        return existing + cards.filter { !stackIDs.contains($0.id) }
    }
    /// 交换点击卡与最前层卡；参数：id 为已存在的卡片 ID；返回值：无；其他卡片保持槽位，立即保存本机顺序，同时更新账户草稿顺序。
    private func selectCard(_ id: String) {
        var ids = displayedCards.map(\.id)
        guard let index = ids.firstIndex(of: id), !ids.isEmpty else { return }
        ids.swapAt(index, ids.count - 1)
        if selectedCard?.id != id { revealedID = nil }
        menuOpen = false
        stackIDs = ids
        cards = ids.compactMap { id in cards.first { $0.id == id } }
        // 使用用户空间和卡片标识保存偏好，账户同步更换临时 ID 后仍能恢复。
        let preference = "wallet-order:" + (store.finance?.activeKey ?? "preview")
        let currentKeys = Set(cards.map { key($0.id) })
        let other = (UserDefaults.standard.stringArray(forKey: preference) ?? []).filter { !currentKeys.contains($0) }
        UserDefaults.standard.set(other + cards.map { key($0.id) }, forKey: preference)
    }

    /// 计算稳定缓存键；参数：id 为卡片 ID；返回值：包含当前用户空间的隔离键，兼容旧卡固定 ID。
    private func key(_ id: String) -> String { (store.finance?.activeKey ?? "preview") + ":" + (id == "legacy" ? "account-\(accountID ?? 0)" : id) }
    /// 生成本机卡面加载标识；参数：无；返回值：卡片或空间改变时重新读取本机偏好，不联网。
    private var artworkIdentity: String { (store.finance?.activeKey ?? "") + provider.name + cards.map { $0.id + $0.name }.joined(separator: "|") }
    /// 绘制始终层叠的钱包；参数：无；返回值：单一卡堆和右侧滑出操作栏，编辑另开表单，不重复绘制选中卡。
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !cards.isEmpty {
                ZStack(alignment: .top) {
                    // 卡面始终保持完整尺寸并按槽位叠放；点击区域单独限定为露出的部分，避免后层卡抢占前层触摸。
                    ForEach(Array(displayedCards.enumerated()), id: \.element.id) { index, card in
                        face(card)
                            // 菜单展开时只保留后层卡的露出部分，避免玻璃按钮落在另一张卡面上而误导操作对象。
                            .frame(height: menuOpen && card.id != selectedCard?.id ? 64 : 210, alignment: .top)
                            .clipped()
                            .offset(x: card.id == selectedCard?.id && menuOpen ? -80 : 0, y: CGFloat(index) * 64)
                            .zIndex(Double(index))
                    }
                }
                .frame(height: CGFloat(max(0, displayedCards.count - 1)) * 64 + 210, alignment: .top)
                .accessibilityHidden(true)
                .overlay(alignment: .topTrailing) {
                  ZStack(alignment: .topTrailing) {
                    if menuOpen {
                        actionMenu
                            .frame(width: 80, height: 210)
                            .offset(y: CGFloat(max(0, displayedCards.count - 1)) * 64)
                    }
                  VStack(spacing: 0) {
                    ForEach(displayedCards) { card in
                        // 点击回调无参数、无返回值；将后层卡与前层卡交换，其他槽位不动；右侧操作栏始终操作前层卡。
                        Button { withAnimation(.snappy) { selectCard(card.id) } } label: {
                            Color.clear
                                .frame(height: card.id == selectedCard?.id ? 210 : 64)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityIdentifier("wallet-card-" + card.id)
                            .accessibilityLabel("\(card.name.isEmpty ? "新卡片" : card.name)，\(displayNumber(card))")
                            .accessibilityValue(card.id == selectedCard?.id ? "已选中" : "未选中")
                            .overlay {
                                WalletCardGestureSurface(canSwipe: card.id == selectedCard?.id,
                                    select: { withAnimation(.snappy) { selectCard(card.id) } },
                                    reveal: { open in withAnimation(.snappy) { menuOpen = open } })
                                    .accessibilityHidden(true)
                            }
                            .offset(x: card.id == selectedCard?.id && menuOpen ? -80 : 0)
                            .accessibilityAction(named: "显示操作") { selectCard(card.id); menuOpen = true }
                    }
                  }
                  }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            // 添加回调无参数、无返回值；创建卡片并打开编辑，标签撑满卡面宽度以扩大点击区域。
            Button { addCard() } label: {
                Label("添加卡片", systemImage: "plus")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(RoundedRectangle(cornerRadius: 16))
            }
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: 16))
                .disabled(cards.count >= 30)
        }
        .task(id: artworkIdentity) { loadArtwork() }
        .onChange(of: store.finance?.activeKey) { _, _ in stackIDs = []; menuOpen = false; editingID = nil; revealedID = nil; artwork = [:] }
        .sheet(isPresented: Binding(get: { editingID != nil }, set: { if !$0 { editingID = nil } })) {
            if let index = cards.firstIndex(where: { $0.id == editingID }) {
                NavigationStack {
                    Form {
                        TextField("卡片名称", text: $cards[index].name).textInputAutocapitalization(.never)
                        CardNumberTextField(value: $cards[index].maskedAccountNumber, name: cards[index].name)
                            .frame(minHeight: 28)
                    }
                        .contentMargins(.top, 8)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { editingID = nil } } }
                }
                // 两个输入行与完成按钮使用紧凑高度，随系统字号缩放；键盘由系统避让。
                .presentationDetents([.height(editorHeight)])
                .presentationDragIndicator(.visible)
            }
        }
    }
    /// 绘制右侧操作栏；参数：无；返回值：上下排列的查看、编辑、删除玻璃按钮，删除必须点按，不支持整段滑动直接删除。
    private var actionMenu: some View {
        VStack(spacing: 12) {
            Button(revealedID == selectedCard?.id ? "隐藏卡号" : "查看卡号", systemImage: revealedID == selectedCard?.id ? "eye.slash" : "eye") {
                guard let id = selectedCard?.id else { return }
                withAnimation(.snappy) { revealedID = revealedID == id ? nil : id; menuOpen = false }
            }
            Button("编辑卡片", systemImage: "pencil") { editingID = selectedCard?.id; revealedID = nil; menuOpen = false }
            Button("删除卡片", systemImage: "trash", role: .destructive) {
                guard let id = selectedCard?.id else { return }
                withAnimation(.snappy) {
                    cards.removeAll { $0.id == id }; stackIDs.removeAll { $0 == id }; revealedID = nil; menuOpen = false
                }
            }.tint(.red)
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .controlSize(.large)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }
    /// 新建并编辑卡片；参数：无；返回值：无；限制最多 30 张，新卡置于前层并收起菜单。
    private func addCard() {
        guard cards.count < 30 else { return }
        let card = AccountCard(); cards.append(card); selectCard(card.id); editingID = card.id
    }
    /// 绘制单张卡面；参数：card 为卡片资料；返回值：固定高度卡片，默认原生绘制，默认遮罩卡号，主动查看时在卡面原位显示完整号码，允许手选背景。
    private func face(_ card: AccountCard) -> some View {
        ZStack(alignment: .topLeading) {
            NativeCardBackground(name: card.name, bank: provider.name)
            if let image = cardImage(card) {
                GeometryReader { geometry in
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
                LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0.15), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    AccountProviderIcon(provider: provider, size: 30)
                    Text(card.name.isEmpty ? "新卡片" : card.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                }
                Spacer()
                Text(provider.name).font(.caption).lineLimit(1)
                Text(displayNumber(card)).font(.system(.title3, design: .monospaced).weight(.medium))
                    .lineLimit(1).minimumScaleFactor(0.65)
            }.foregroundStyle(.white).padding(18)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.24), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 4)
    }
    /// 生成当前卡面号码；参数：card 为卡片；返回值：默认遮罩，主动查看时显示完整号码或已保存尾号。
    private func displayNumber(_ card: AccountCard) -> String {
        CardNumberFormat.presentation(card.maskedAccountNumber, name: card.name, revealed: revealedID == card.id)
    }
    /// 读取用户自选背景；参数：card 为当前卡片；返回值：有效手选图片或 nil，旧自动图片不再展示，空数据使用原生卡面。
    private func cardImage(_ card: AccountCard) -> UIImage? {
        guard let saved = artwork[card.id], saved.manual else { return nil }
        return UIImage(data: saved.image)
    }
    /// 加载本机手选偏好；参数：无；返回值：无；忽略旧自动搜索缓存，不联网、不改写卡片或账务资料。
    private func loadArtwork() {
        let preference = "wallet-order:" + (store.finance?.activeKey ?? "preview")
        let saved = UserDefaults.standard.stringArray(forKey: preference) ?? []
        stackIDs = saved.compactMap { savedKey in cards.first { key($0.id) == savedKey }?.id }
        // 回调输入卡片、返回手选偏好键值或 nil；旧缓存保留在磁盘但不作为默认背景。
        artwork = Dictionary(uniqueKeysWithValues: cards.compactMap { card in
            guard let value = CardArtwork.load(key(card.id)), value.manual else { return nil }
            return (card.id, value)
        })
    }
}

/// 只读预览入口使用虚构号码，禁用自动联网；不写财务资料。
struct AccountCardWalletPreview: View {
    @State private var cards = [AccountCard(id: "preview-one", name: "银联 初音未来粉丝信用卡", maskedAccountNumber: "**** 1234"), AccountCard(id: "preview-two", name: "招商银行美国运通百夫长金卡", maskedAccountNumber: "**** 5678"), AccountCard(id: "preview-three", name: "VISA全币种国际信用卡", maskedAccountNumber: "0000 0000 0000 9012"), AccountCard(id: "preview-four", name: "皮卡丘信用卡", maskedAccountNumber: "**** 3456")]
    /// 展示隔离钱包；参数：无；返回值：可检查卡片堆叠和槽位交换的预览页面。
    var body: some View {
        NavigationStack {
            ScrollView { AccountCardWallet(cards: $cards, provider: .defaultBank, accountID: nil).padding(20) }
                .background(Color(uiColor: .systemGroupedBackground)).navigationTitle("招商银行信用账户")
        }
    }
}
