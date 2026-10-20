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
    @State private var draft: ScanTask
    @State private var customRegion: ScanRegion
    @State private var customInterval: Int
    @State private var error: String?
    @State private var showOptions: Bool
    @State private var startAfterSaving = false

    init(store: TaskStore, initial: ScanTask) {
        self.store = store
        _draft = State(initialValue: initial)
        _showOptions = State(initialValue: initial.region != nil || initial.interval != nil || initial.appNotification != nil || initial.barkNotification != nil)
        _customRegion = State(initialValue: initial.region ?? store.defaults.region)
        _customInterval = State(initialValue: initial.interval ?? store.defaults.interval)
    }

    private var effective: ScanDefaults { draft.resolved(using: store.defaults) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(store.tasks.contains(where: { $0.id == draft.id }) ? "编辑产品" : "添加产品").font(.title2.bold())
                Spacer()
            }.padding(24)
            Form {
                Section("产品") {
                    TextField("产品型号", text: $draft.product, prompt: Text("例如 MYLU3CH/A"))
                    TextField("备注名称", text: $draft.name, prompt: Text("选填"))
                }
                Section {
                    Button {
                        showOptions.toggle()
                    } label: {
                        HStack {
                            Text("自定义选项")
                            Spacer()
                            Image(systemName: showOptions ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showOptions ? "已展开" : "已收起")
                } footer: {
                    if !showOptions {
                        Text("\(effective.region.city) · \(effective.region.district) · 每 \(effective.interval) 秒")
                    }
                }
                if showOptions {
                    Section("地区") {
                        Toggle("使用默认", isOn: Binding(get: { draft.region == nil }, set: { draft.region = $0 ? nil : customRegion }))
                            .accessibilityLabel("使用默认地区")
                        if draft.region == nil {
                            LabeledContent("当前地区", value: "\(store.defaults.region.city) · \(store.defaults.region.district)")
                                .foregroundStyle(.secondary)
                        } else {
                            RegionFields(region: $customRegion)
                                .onChange(of: customRegion) { _, value in draft.region = value }
                        }
                    }
                    Section("扫描") {
                        Toggle("使用默认", isOn: Binding(get: { draft.interval == nil }, set: { draft.interval = $0 ? nil : customInterval }))
                            .accessibilityLabel("使用默认间隔")
                        if draft.interval == nil {
                            LabeledContent("间隔", value: "\(store.defaults.interval) 秒").foregroundStyle(.secondary)
                        } else {
                            TextField("间隔（秒）", value: $customInterval, format: .number)
                                .onChange(of: customInterval) { _, value in draft.interval = value }
                        }
                    }
                    Section("通知") {
                        notificationPicker("系统通知", value: $draft.appNotification, defaultValue: store.defaults.appNotification)
                        notificationPicker("Bark 推送", value: $draft.barkNotification, defaultValue: store.defaults.barkNotification)
                    }
                }
            }.formStyle(.grouped)
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 24) }
            HStack {
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if !store.runner(for: draft.id).isTracking {
                    Toggle("保存后开始", isOn: $startAfterSaving).toggleStyle(.checkbox).fixedSize()
                }
                Button("保存") { save(start: startAfterSaving) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 480, height: showOptions ? 560 : 340)
    }

    private func notificationPicker(_ title: String, value: Binding<Bool?>, defaultValue: Bool) -> some View {
        Picker(title, selection: value) {
            Text("使用默认（\(defaultValue ? "开启" : "关闭")）").tag(nil as Bool?)
            Text("开启").tag(true as Bool?)
            Text("关闭").tag(false as Bool?)
        }
        .pickerStyle(.menu)
    }

    private func save(start: Bool) {
        error = store.validationError(for: draft)
        guard error == nil else { return }
        store.save(draft, start: start)
        dismiss()
    }
}
