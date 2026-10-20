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
    @State private var startAfterSaving = false

    init(store: TaskStore, initial: ScanTask) {
        self.store = store
        _draft = State(initialValue: ScanTaskDraft(task: initial, defaults: store.defaults))
    }

    private var effective: ScanDefaults { draft.settings }
    private var showOptions: Bool { draft.customizationEnabled }

    private var notificationSummary: String {
        let channels = [
            draft.settings.appNotification ? "系统" : nil,
            draft.settings.barkNotification ? "Bark" : nil
        ].compactMap { $0 }
        return channels.isEmpty ? "通知关闭" : "通知：\(channels.joined(separator: "、"))"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.tasks.contains(where: { $0.id == draft.task.id }) ? "编辑产品" : "添加产品").font(.title2.bold())
                Spacer()
            }.padding(24)
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
                Section {
                    Toggle("自定义选项", isOn: Binding(
                        get: { draft.customizationEnabled },
                        set: { enabled in
                            draft.setCustomizationEnabled(enabled, defaults: store.defaults)
                            error = nil
                        }
                    ))
                } footer: {
                    if !showOptions {
                        Text("\(effective.region.city) · \(effective.region.district) · 每 \(effective.interval) 秒 · \(notificationSummary)")
                    }
                }
                if showOptions {
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
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if !store.runner(for: draft.task.id).isTracking {
                    Toggle("保存后开始", isOn: $startAfterSaving).toggleStyle(.checkbox).fixedSize()
                }
                Button("保存") { save(start: startAfterSaving) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 480, height: showOptions ? 560 : 340)
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
