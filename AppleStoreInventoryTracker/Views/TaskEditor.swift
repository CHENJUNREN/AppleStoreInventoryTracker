import SwiftUI

struct RegionFields: View {
    @Binding var region: ScanRegion
    var body: some View {
        TextField("省份", text: $region.province)
        TextField("城市", text: $region.city)
        TextField("区／县", text: $region.district)
    }
}

struct TaskEditor: View {
    let store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScanTaskDraft
    @State private var selectedProduct: IPhoneVariant?
    @State private var startAfterSaving = true

    init(store: TaskStore) {
        self.store = store
        _draft = State(initialValue: ScanTaskDraft(task: ScanTask(), defaults: store.defaults))
    }

    var body: some View {
        SheetLayout(title: "添加产品") {
            VStack(spacing: 0) {
                Form {
                    IPhoneProductPicker(product: $selectedProduct)
                    Section {
                        Toggle("单独设置此任务", isOn: Binding(
                            get: { draft.customizationEnabled },
                            set: {
                                draft.setCustomizationEnabled($0, defaults: store.defaults)
                            }
                        ))
                    } header: { Text("监控设置") } footer: {
                        if !draft.customizationEnabled {
                            Text("使用「配置 → 监控默认值」，保存后独立使用。")
                        }
                    }
                    if draft.customizationEnabled {
                        Section("查询范围") {
                            RegionFields(region: $draft.settings.region)
                        }
                        Section("扫描频率") {
                            TextField("扫描间隔（秒）", value: $draft.settings.interval, format: .number)
                        }
                        Section("库存通知") {
                            Toggle("系统通知", isOn: $draft.settings.appNotification)
                            Toggle("Bark", isOn: $draft.settings.barkNotification)
                            if draft.settings.barkNotification {
                                TextField("Bark 地址", text: $draft.settings.barkURL, prompt: Text("https://api.day.app/{Key}/"))
                            }
                        }
                    }
                }.formStyle(.grouped)
                HStack(spacing: 12) {
                    Toggle("保存后开始", isOn: $startAfterSaving).toggleStyle(.checkbox).fixedSize()
                    Spacer()
                    Button("保存") { save(start: startAfterSaving) }
                        .modifier(SheetPillStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedProduct == nil || store.storageError != nil)
                }
                .controlSize(.regular)
                .padding(24)

            }

        }
        .frame(width: 480, height: draft.customizationEnabled ? 620 : 480)
    }

    private func save(start: Bool) {
        guard let selectedProduct else { return }
        if !draft.customizationEnabled {
            draft.setCustomizationEnabled(false, defaults: store.defaults)
        }
        var task = draft.savedTask
        task.product = selectedProduct.partNumber
        task.name = selectedProduct.displayName
        if let error = store.validationError(for: task) { store.toast.show(error, kind: .error); return }
        store.save(task, start: start)
        guard store.storageError == nil else { return }
        store.toast.show("产品已添加")
        dismiss()
    }
}
