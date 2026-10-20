import SwiftUI
import UserNotifications

struct ConfigurationView: View {
    let store: TaskStore
    @State private var draft = ScanDefaults()
    @State private var message: String?
    @State private var testMessage: String?
    @State private var notificationStatus = "读取中…"
    @State private var testing = false
    @State private var showScanHelp = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("默认地区") {
                RegionFields(region: $draft.region)
            }
            Section("扫描") {
                HStack {
                    TextField("间隔（秒）", value: $draft.interval, format: .number)
                    Button("扫描频率说明", systemImage: "info.circle") { showScanHelp.toggle() }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                        .popover(isPresented: $showScanHelp) {
                            Text("有货时自动加速查询，随后进入观察期。更短的自定义间隔优先；服务端冷却期间暂停查询。")
                                .font(.callout).padding(16).frame(width: 280)
                        }
                }
            }
            Section("通知") {
                Toggle("系统通知", isOn: $draft.appNotification)
                if draft.appNotification {
                    HStack {
                        Text(notificationStatus).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("管理…") {
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
                        if let testMessage {
                            Text(testMessage).font(.caption).foregroundStyle(.secondary)
                        }
                        Button(testing ? "发送中…" : "测试推送") { Task { await testBark() } }
                            .disabled(testing || draft.barkURL.isEmpty)
                    }
                }
            }
            if let message { Text(message).font(.caption).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("保存", action: save)
                    .disabled(store.storageError != nil || draft == store.defaults)
            }
        }
        .onAppear { draft = store.defaults }
        .task { await refreshPermission() }
        .onChange(of: scenePhase) { _, value in if value == .active { Task { await refreshPermission() } } }
    }

    private func save() {
        guard draft.isValid else { message = "请填写完整地区，扫描间隔必须为有效的正整数。"; return }
        guard (!draft.barkNotification && draft.barkURL.isEmpty) || InventoryNotifier.barkURL(base: draft.barkURL, title: "test", body: "test") != nil else {
            message = "请填写有效的 http 或 https Bark URL。"; return
        }
        // Inherited Bark settings also need a usable address when a task explicitly enables Bark.
        guard !draft.barkURL.isEmpty || !store.tasks.contains(where: { $0.barkNotification == true }) else {
            message = "仍有任务单独开启了 Bark，请保留有效地址或先关闭这些任务的 Bark。"; return
        }
        store.saveDefaults(draft)
        message = "配置已保存。"
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
        testMessage = nil
        guard let url = InventoryNotifier.barkURL(base: draft.barkURL, title: "库存监测 · 测试通知", body: "Bark 推送配置成功") else {
            testMessage = "Bark URL 无效。"; return
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
                testMessage = "测试推送已发送。"
            } else { testMessage = "测试发送失败，请检查 Bark 地址和服务状态。" }
        } catch { testMessage = "测试发送失败，请检查网络或 Bark 地址。" }
    }
}
