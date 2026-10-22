import SwiftUI
import UserNotifications

enum ConfigurationCategory: String, CaseIterable {
    case general, monitoring, purchase
    var title: String {
        switch self {
        case .general: "通用"
        case .monitoring: "监控默认值"
        case .purchase: "购买辅助"
        }
    }
}

struct ConfigurationView: View {
    let store: TaskStore
    @Binding var category: ConfigurationCategory
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system
    @State private var draft = ScanDefaults()
    @State private var pickup = PickupProfile()
    @State private var notificationStatus = "读取中…"
    @State private var testing = false
    @State private var showScanHelp = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 0) {
            Picker("配置类别", selection: $category) {
                ForEach(ConfigurationCategory.allCases, id: \.self) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.top, 20)
            .padding(.bottom, 4)
            Form {
                switch category {
                case .general:
                    Section("外观") {
                        Picker("显示模式", selection: $appearance) {
                            ForEach(AppAppearance.allCases, id: \.self) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                case .monitoring: monitoringSettings
                case .purchase: purchaseSettings
                }
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if category != .general {
                    Button("保存", action: save)
                        .disabled(store.storageError != nil || !hasChanges)
                }
            }
        }
        .onAppear { draft = store.defaults; pickup = store.purchaseAssistant.profile }
        .task { await refreshPermission() }
        .onChange(of: scenePhase) { _, value in if value == .active { Task { await refreshPermission() } } }
    }

    private var hasChanges: Bool {
        switch category {
        case .general: false
        case .monitoring: draft != store.defaults
        case .purchase: pickup != store.purchaseAssistant.profile
        }
    }

    @ViewBuilder private var monitoringSettings: some View {
        Section("查询范围") {
            RegionFields(region: $draft.region)
        }
        Section("扫描频率") {
            HStack {
                TextField("扫描间隔（秒）", value: $draft.interval, format: .number)
                Button("扫描频率说明", systemImage: "info.circle") { showScanHelp.toggle() }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    .popover(isPresented: $showScanHelp) {
                        Text("有货时自动加速查询，随后进入观察期。更短的自定义间隔优先；服务端冷却期间暂停查询。")
                            .font(.callout).padding(16).frame(width: 280)
                    }
            }
        }
        Section {
            Toggle("系统通知", isOn: $draft.appNotification)
            if draft.appNotification {
                HStack {
                    Text(notificationStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("通知权限…") {
                        Task {
                            let settings = await UNUserNotificationCenter.current().notificationSettings()
                            if settings.authorizationStatus == .notDetermined {
                                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                                await refreshPermission()
                            } else if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            Toggle("Bark", isOn: $draft.barkNotification)
            if draft.barkNotification {
                TextField("Bark 地址", text: $draft.barkURL, prompt: Text("https://api.day.app/{Key}/"))
                HStack {
                    Spacer()
                    Button(testing ? "发送中…" : "测试推送") { Task { await testBark() } }
                        .disabled(testing || draft.barkURL.isEmpty)
                }
            }
        } header: { Text("库存通知") }
        footer: { Text("以上设置用于新建任务，可在添加产品时单独调整。") }
    }

    @ViewBuilder private var purchaseSettings: some View {
        Section {
            PickupProfileFields(profile: $pickup)
        } header: { Text("取货人") }
        footer: { Text("所有购买辅助任务共用，资料仅保存在本机。") }
        Section("结账") {
            Picker("付款方式", selection: $pickup.payment) {
                ForEach(PickupProfile.Payment.allCases, id: \.self) { payment in
                    Text(payment.title).tag(payment)
                }
            }.pickerStyle(.menu)
        }
        Section {
            HStack {
                Text("Chrome")
                Spacer()
                if store.purchaseAssistant.ready {
                    Button("登录 Apple 账户…") { store.purchaseAssistant.openLogin() }
                        .disabled(store.purchaseAssistant.activeTask != nil)
                } else {
                    Button(store.purchaseAssistant.preparing ? "正在设置…" : "设置浏览器…") { store.purchaseAssistant.prepare() }
                        .disabled(store.purchaseAssistant.preparing)
                }
            }
        } header: { Text("浏览器") }
        footer: { Text("使用独立的 Chrome 窗口。登录失效时，在浏览器中重新登录。") }
    }

    private func save() {
        if category == .monitoring {
            guard draft.isValid else { store.toast.show("请填写完整查询范围，并输入有效的扫描间隔", kind: .error); return }
            guard !draft.barkNotification || InventoryNotifier.barkURL(base: draft.barkURL, title: "test", body: "test") != nil else {
                store.toast.show("请填写有效的 Bark 地址", kind: .error); return
            }
            store.saveDefaults(draft)
        } else {
            guard store.purchaseAssistant.saveProfile(pickup) else {
                store.toast.show(store.purchaseAssistant.profileError ?? "取货资料保存失败", kind: .error)
                return
            }
        }
        guard store.storageError == nil else { return }
        store.toast.show("配置已保存")
    }

    private func refreshPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notificationStatus = settings.alertSetting == .enabled ? "已允许" : "横幅未开启"
        case .denied: notificationStatus = "未授权"
        case .notDetermined: notificationStatus = "未授权"
        @unknown default: notificationStatus = "未知"
        }
    }

    private func testBark() async {
        guard let url = InventoryNotifier.barkURL(base: draft.barkURL, title: "库存监测 · 测试通知", body: "Bark 推送配置成功") else {
            store.toast.show("请填写有效的 Bark 地址", kind: .error); return
        }
        testing = true
        defer { testing = false }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
               let code = payload?["code"] as? Int, code == 200 {
                store.toast.show("测试推送已发送")
            } else { store.toast.show("测试发送失败，请检查 Bark 地址和服务状态", kind: .error) }
        } catch { store.toast.show("测试发送失败，请检查网络或 Bark 地址", kind: .error) }
    }
}
