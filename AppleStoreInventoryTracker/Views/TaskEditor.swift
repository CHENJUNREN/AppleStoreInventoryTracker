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
    @State private var showProductNumberHelp = false
    @State private var startAfterSaving = true

    init(store: TaskStore) {
        self.store = store
        _draft = State(initialValue: ScanTaskDraft(task: ScanTask(), defaults: store.defaults))
    }

    var body: some View {
        SheetLayout(title: "添加产品") {
            VStack(spacing: 0) {
                Form {
                    Section("产品") {
                        HStack {
                            TextField("产品型号", text: $draft.task.product, prompt: Text("例如 MYLU3CH/A"))
                            Button {
                                showProductNumberHelp = true
                            } label: {
                                Image(systemName: "exclamationmark.circle")
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("如何找到产品型号")
                            .accessibilityLabel("如何找到产品型号")
                        }
                        TextField("备注名称", text: $draft.task.name, prompt: Text("选填"))
                    }
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
                }.formStyle(.grouped)
                if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 24) }
                HStack(spacing: 12) {
                    Toggle("保存后开始", isOn: $startAfterSaving).toggleStyle(.checkbox).fixedSize()
                    Spacer()
                    Button("保存") { save(start: startAfterSaving) }
                        .modifier(SheetPillStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.regular)
                .padding(24)

            }

        }
        .frame(width: 480, height: 560)
        .sheet(isPresented: $showProductNumberHelp) { ProductNumberHelp() }
    }

    private func save(start: Bool) {
        let task = draft.savedTask
        error = store.validationError(for: task)
        guard error == nil else { return }
        store.save(task, start: start)
        dismiss()
    }
}
