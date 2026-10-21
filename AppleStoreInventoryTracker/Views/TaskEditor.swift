import SwiftUI

struct RegionFields: View {
    @Binding var region: ScanRegion
    var body: some View {
        TextField("省份", text: $region.province)
        TextField("城市", text: $region.city)
        TextField("区", text: $region.district)
    }
}

struct TaskEditor: View {
    let store: TaskStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ScanTaskDraft
    @State private var error: String?
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
                        Toggle("自定义监控设置", isOn: Binding(
                            get: { draft.customizationEnabled },
                            set: {
                                draft.setCustomizationEnabled($0, defaults: store.defaults)
                                error = nil
                            }
                        ))
                    } footer: {
                        Text("关闭时使用「配置」页中的地区、扫描间隔和通知设置，保存后作为此产品的独立配置。")
                    }
                    if draft.customizationEnabled {
                        Section("地区") {
                            RegionFields(region: $draft.settings.region)
                        }
                        Section("扫描") {
                            TextField("间隔（秒）", value: $draft.settings.interval, format: .number)
                        }
                        Section("通知") {
                            Toggle("系统通知", isOn: $draft.settings.appNotification)
                            Toggle("Bark 推送", isOn: $draft.settings.barkNotification)
                            if draft.settings.barkNotification {
                                TextField("Bark 地址", text: $draft.settings.barkURL, prompt: Text("https://api.day.app/{Key}/"))
                            }
                        }
                    }
                }.formStyle(.grouped)
                if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 24) }
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
        error = store.validationError(for: task)
        guard error == nil else { return }
        store.save(task, start: start)
        dismiss()
    }
}
