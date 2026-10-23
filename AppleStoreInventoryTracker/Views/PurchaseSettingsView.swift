import SwiftUI

struct PickupProfileFields: View {
    @Binding var profile: PickupProfile
    var body: some View {
        TextField("姓", text: $profile.lastName)
        TextField("名", text: $profile.firstName)
        TextField("邮箱", text: $profile.emailAddress)
        TextField("手机号", text: $profile.fullDaytimePhone)
        TextField("身份证后四位", text: $profile.nationalIdSelf)
    }
}

struct PurchaseSettingsView: View {
    let store: TaskStore
    let task: ScanTask
    let openConfiguration: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TaskPurchaseSettings

    init(store: TaskStore, task: ScanTask, openConfiguration: @escaping () -> Void) {
        self.store = store
        self.task = task
        self.openConfiguration = openConfiguration
        _draft = State(initialValue: task.purchase ?? TaskPurchaseSettings())
    }

    private var shops: [StoreInventoryInfo] { store.runner(for: task.id).inventoryInfos.first?.stores ?? [] }
    private var remaining: [StoreInventoryInfo] { shops.filter { shop in !draft.stores.contains { $0.id == shop.storeNumber } } }
    private var configured: Bool { store.purchaseAssistant.profile.validationError == nil && store.purchaseAssistant.ready }

    var body: some View {
        SheetLayout(title: "辅助购买") {
            VStack(spacing: 0) {
                Form {
                    if !configured {
                        Section {
                            HStack {
                                Text("请先完善取货资料和浏览器设置。")
                                Spacer()
                                Button("前往设置…") { dismiss(); openConfiguration() }
                            }
                        }
                    }
                    Section {
                        if draft.stores.isEmpty {
                            Text(shops.isEmpty ? "查询后可选择门店" : "尚未选择门店").foregroundStyle(.secondary)
                        }
                        ForEach(draft.stores) { shop in
                            HStack(spacing: 10) {
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                                Text(shop.name)
                                Spacer()
                                Button("移除 \(shop.name)", systemImage: "minus.circle") {
                                    draft.stores.removeAll { $0.id == shop.id }
                                }.labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
                                    .help("移除门店")
                            }
                            .contentShape(Rectangle())
                            .draggable(shop.id)
                            .dropDestination(for: String.self) { items, _ in
                                guard let source = items.first,
                                      let from = draft.stores.firstIndex(where: { $0.id == source }),
                                      let to = draft.stores.firstIndex(of: shop) else { return false }
                                draft.stores.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                                return true
                            }
                            .accessibilityAction(named: "提高优先级") { move(shop, by: -1) }
                            .accessibilityAction(named: "降低优先级") { move(shop, by: 1) }
                            .contextMenu {
                                Button("上移") { move(shop, by: -1) }.disabled(draft.stores.first == shop)
                                Button("下移") { move(shop, by: 1) }.disabled(draft.stores.last == shop)
                                Button("移除", role: .destructive) { draft.stores.removeAll { $0.id == shop.id } }
                            }
                        }
                        if !remaining.isEmpty {
                            Menu {
                                ForEach(remaining) { shop in
                                    Button(shop.storeName) {
                                        draft.stores.append(PreferredStore(id: shop.storeNumber, name: shop.storeName))
                                    }
                                }
                            } label: { Label("添加门店", systemImage: "plus") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    } header: { Text("取货门店") }
                    footer: { Text("按顺序尝试，选择首个可用取货时段。") }
                    Section {
                        Toggle("加购 AppleCare+", isOn: $draft.appleCare)
                    } header: { Text("购买选项") } footer: {
                        Text("将清空购物袋并加入本产品 1 件，不折抵，开具个人发票。")
                    }
                }.formStyle(.grouped)
                HStack {
                    Text("自动填写至检查订单页，下单付款由你完成。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存") {
                        draft.enabled = true
                        store.setPurchase(draft, for: task.id)
                        guard store.storageError == nil else { return }
                        store.toast.show("辅助购买设置已保存")
                        dismiss()
                    }
                    .modifier(SheetPillStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.stores.isEmpty || !configured || store.storageError != nil)
                }.padding(24)
            }
        }.frame(width: 480, height: 480)
    }

    private func move(_ shop: PreferredStore, by delta: Int) {
        guard let index = draft.stores.firstIndex(of: shop), draft.stores.indices.contains(index + delta) else { return }
        draft.stores.swapAt(index, index + delta)
    }
}
