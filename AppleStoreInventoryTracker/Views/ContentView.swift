import SwiftUI

struct ContentView: View {
    let store: TaskStore
    @State private var selection = "monitor"
    @State private var configurationCategory = ConfigurationCategory.monitoring
    @State private var showingAddProduct = false
    @State private var deleting: ScanTask?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(" 产品库存监控", systemImage: "shippingbox").tag("monitor")
                Label("设置", systemImage: "slider.horizontal.3").tag("settings")
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
        } detail: {
            Group {
                if selection == "settings" {
                    ConfigurationView(store: store, category: $configurationCategory)
                } else {
                    monitoringPage
                }
            }
            .navigationTitle(selection == "settings" ? "设置" : " 产品库存监控")
        }
        .frame(minWidth: 780, minHeight: 520)
        .modifier(ToastOverlay(center: store.toast))
        .onChange(of: store.storageError, initial: true) { _, error in
            if let error { store.toast.show(error, kind: .error) }
        }
        .onAppear {
            if let error = store.purchaseAssistant.profileError { store.toast.show(error, kind: .error) }
        }
        .sheet(isPresented: $showingAddProduct) { TaskEditor(store: store) }
        .alert("删除监控任务？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let task = deleting {
                    store.delete(task)
                    if store.storageError == nil { store.toast.show("任务已删除") }
                }
                deleting = nil
            }
        } message: { Text("该任务的监控将停止，保存的设置将被删除。") }
        .environment(store.toast)
    }

    private var monitoringPage: some View {
        VStack(spacing: 0) {
            if store.tasks.isEmpty {
                ContentUnavailableView {
                    Label("添加第一个产品", systemImage: "shippingbox")
                } description: {
                    Text("添加产品，开始监控到店取货库存。")
                } actions: {
                    Button("添加产品", systemImage: "plus") { showingAddProduct = true }
                        .buttonStyle(.borderedProminent).disabled(store.storageError != nil)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(store.tasks) { task in
                            ScanTaskCard(task: task, store: store, openConfiguration: { configurationCategory = .purchase; selection = "settings" }, defaults: store.defaults, runner: store.runner(for: task.id),
                                         start: {
                                if let error = store.validationError(for: task) { store.toast.show(error, kind: .error) }
                                else { store.start(task) }
                            }, delete: { deleting = task })
                        }
                    }.padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: store.tasks.isEmpty ? .textBackgroundColor : .underPageBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("添加产品", systemImage: "plus") { showingAddProduct = true }
                    .keyboardShortcut("n").disabled(store.storageError != nil)
            }
        }
    }
}

private struct ScanTaskCard: View {
    let task: ScanTask
    let store: TaskStore
    let openConfiguration: () -> Void
    @State private var showingPurchaseSettings = false
    let defaults: ScanDefaults
    let runner: ContentViewModel
    let start: () -> Void
    let delete: () -> Void
    @State private var expanded = false
    @State private var showingStores = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var effective: ScanDefaults { task.resolved(using: defaults) }

    private var regionLabel: String {
        effective.region.city
    }

    private var trackingColor: Color {
        guard runner.isTracking else { return .secondary }
        return runner.lastError == nil ? .blue : .orange
    }

    private var stockSummary: String {
        guard let inventory = runner.inventoryInfos.first else { return "暂无库存信息" }
        let stock = inventory.availableStores.isEmpty ? "暂无现货" : "\(inventory.availableStores.count) 家可取货"
        let stale = hasCurrentResult ? "" : " · 上次结果"
        return "\(stock)\(stale)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Keep disclosure and actions as sibling controls so actions never toggle details.
            HStack(spacing: 0) {
                disclosureButton
                actions
            }
            if expanded {
                VStack(alignment: .leading, spacing: 16) {
                    Divider()
                    purchaseControls
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("活动记录").font(.subheadline.weight(.medium))
                            Spacer()
                            Button("查看门店") { showingStores = true }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.small)
                                .disabled(runner.inventoryInfos.isEmpty)
                                .popover(isPresented: $showingStores) {
                                    ScrollView { details.padding(16) }.frame(width: 320, height: 320)
                                }
                        }
                        TaskActivityList(entries: store.histories[task.id.uuidString]?.entries ?? []).equatable()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showingPurchaseSettings) {
            PurchaseSettingsView(store: store, task: task, openConfiguration: openConfiguration)
        }
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(hovering ? 0.025 : 0))
                        .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(trackingColor.opacity(runner.isTracking ? 0.4 : 0.12), lineWidth: 1)
                        .allowsHitTesting(false)
                }
        }
    }

    private var purchaseControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("有货时辅助购买").font(.subheadline.weight(.medium))
                Spacer()
                Button("设置…", systemImage: "slider.horizontal.3") { showingPurchaseSettings = true }
                    .disabled(store.purchaseAssistant.activeTask == task.id)
                Toggle("有货时辅助购买", isOn: Binding(
                get: { task.purchase?.enabled == true },
                set: { enabled in
                    if enabled && !store.canEnablePurchase(task.purchase) {
                        showingPurchaseSettings = true
                    } else {
                        var settings = task.purchase ?? TaskPurchaseSettings()
                        settings.enabled = enabled
                        store.setPurchase(settings, for: task.id)
                    }
                }
                )).toggleStyle(.switch).labelsHidden()
            }
            if let settings = task.purchase {
                Text(purchaseSummary(settings))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let state = store.purchaseAssistant.states[task.id] {
                HStack(spacing: 8) {
                    Label(state.rawValue, systemImage: state.needsAttention ? "exclamationmark.circle" : "clock")
                        .font(.caption)
                        .foregroundStyle(state.needsAttention ? Color.orange : Color.secondary)
                    Spacer()
                    if store.purchaseAssistant.canResume(task.id) {
                        Button("继续辅助购买", systemImage: "play") { store.purchaseAssistant.resume(task.id) }
                            .help("在 Chrome 完成登录后继续")
                    } else if state == .login {
                        Button("前往设置") { openConfiguration() }
                    }
                    Button("结束本次辅助", systemImage: "stop") {
                        var settings = task.purchase ?? TaskPurchaseSettings()
                        settings.enabled = false
                        store.setPurchase(settings, for: task.id)
                        store.purchaseAssistant.reset(task.id)
                    }
                    .help("关闭辅助购买并释放浏览器；再次开启后才会重新尝试。")
                }
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }

    private func purchaseSummary(_ settings: TaskPurchaseSettings) -> String {
        let first = settings.stores.first?.name ?? "未选择门店"
        let stores = settings.stores.count > 1 ? "\(first)等 \(settings.stores.count) 家门店" : first
        return "\(stores) · AppleCare+ \(settings.appleCare ? "加购" : "不加购")"
    }

    private var disclosureButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                expanded.toggle()
            }
        } label: {
            HStack(spacing: 16) {
                product.frame(maxWidth: .infinity, alignment: .leading)
                statusLabel
            }
            .padding(20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "收起详情" : "查看活动记录")
        .accessibilityValue(expanded ? "已展开" : "已收起")
        .onHover { hovering = $0 }
    }

    private var statusLabel: some View {
        TaskCardStatusLabel(runner: runner, reduceMotion: reduceMotion)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            CardIconAction(
                title: runner.isTracking ? "停止监控" : "开始监控",
                symbol: runner.isTracking ? "stop.fill" : "play.fill",
                destination: .action {
                    if runner.isTracking { runner.stopTracking(preservingResults: true) }
                    else { start() }
                }
            )
            CardIconAction(title: "删除", symbol: "trash", destination: .action(delete), color: .red)
            CardIconAction(
                title: "在 Apple 官网购买",
                symbol: "rectangle.portrait.and.arrow.right",
                destination: .link(purchaseURL)
            )
            .padding(.leading, 8)
        }
        .padding(.trailing, 20)
        .padding(.vertical, 20)
    }

    private var purchaseURL: URL? {
        runner.inventoryInfos.first?.purchaseURL ?? AppleProductPage.purchaseURL(for: task.product)
    }

    private var hasCurrentResult: Bool {
        runner.isTracking && runner.hasCompletedRequest && runner.lastError == nil
    }

    private var highlightedAvailability: String? {
        guard hasCurrentResult,
              let inventory = runner.inventoryInfos.first, !inventory.availableStores.isEmpty else { return nil }
        return "\(inventory.availableStores.count) 家可取货"
    }

    private var product: some View {
        ProductInventoryHeader(
            product: task.product,
            title: task.name.isEmpty ? (runner.inventoryInfos.first?.productName ?? "待查询产品") : task.name
        ) {
            configurationSummary
            Group {
                if let highlightedAvailability {
                    Label(highlightedAvailability, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .fontWeight(.semibold)
                } else {
                    Text(stockSummary).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
    }

    private var intervalLabel: String {
        effective.interval % 60 == 0 ? "\(effective.interval / 60) 分钟" : "\(effective.interval) 秒"
    }

    private var notificationChannels: String {
        [effective.appNotification ? "系统" : nil, effective.barkNotification ? "Bark" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var configurationSummary: some View {
        HStack(spacing: 10) {
            Label(regionLabel, systemImage: "mappin.and.ellipse")
                .lineLimit(1)
                .help(regionLabel)
            Label(intervalLabel, systemImage: "clock")
                .fixedSize()
                .help("查询间隔：\(intervalLabel)")
            if task.purchase?.enabled == true {
                let state = store.purchaseAssistant.states[task.id]
                Label(state?.needsAttention == true ? "辅助购买 · \(state!.rawValue)" : "辅助购买",
                      systemImage: state?.needsAttention == true ? "exclamationmark.circle" : "bag")
                    .foregroundStyle(state?.needsAttention == true ? Color.orange : Color.secondary)
                    .fixedSize()
            }
            if !notificationChannels.isEmpty {
                Label(notificationChannels, systemImage: "bell")
                    .fixedSize()
                    .help("已开启通知：\(notificationChannels)")
                    .accessibilityLabel("已开启通知：\(notificationChannels)")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let inventory = runner.inventoryInfos.first {
                ForEach(inventory.stores.filter(\.isProductAvailable) + inventory.stores.filter { !$0.isProductAvailable }) { shop in
                    HStack {
                        Text(shop.storeName)
                        Spacer()
                        Label(shop.isProductAvailable ? "可取货" : "暂无现货", systemImage: shop.isProductAvailable ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(shop.isProductAvailable && hasCurrentResult ? Color.green : Color.secondary)
                    }
                }
            } else if runner.lastError == nil {
                Text("暂无门店信息").foregroundStyle(.secondary)
            }
            if let date = runner.lastSuccessAt {
                Text("更新于 \(date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }.font(.caption)
    }
}

private struct TaskCardStatusLabel: View {
    let runner: ContentViewModel
    let reduceMotion: Bool

    private var isCountingDown: Bool { runner.isTracking && !runner.isQuerying }
    private var status: String {
        guard runner.isTracking else { return runner.hasStarted ? "已停止" : "未开始" }
        if runner.isQuerying { return "查询中" }
        if runner.lastError != nil { return "重试 \(runner.countdownText)" }
        return runner.countdownText
    }

    var body: some View {
        Text(status)
            .font(.caption)
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : (isCountingDown ? .numericText(countsDown: true) : .opacity))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: status)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 64, alignment: .trailing)
            .foregroundStyle(runner.isTracking && runner.lastError != nil ? Color.orange : Color.secondary)
            .help(runner.isTracking ? runner.countdownLabel : status)
            .accessibilityLabel(isCountingDown ? "\(runner.countdownLabel)，\(status)" : status)
    }
}

/// A shared appearance for card actions, preserving native button and link semantics.
private struct CardIconAction: View {
    enum Destination {
        case action(() -> Void)
        case link(URL?)
    }

    let title: String
    let symbol: String
    let destination: Destination
    var color: Color = .secondary

    private var isUnavailable: Bool {
        if case .link(nil) = destination { return true }
        return false
    }

    private var accessibleTitle: String {
        isUnavailable ? "购买链接不可用" : title
    }

    var body: some View {
        Group {
            switch destination {
            case .action(let action):
                Button(action: action) { label }
            case .link(let url):
                if let url {
                    Link(destination: url) { label }
                } else {
                    Button {} label: { label }
                }
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isUnavailable ? Color.secondary.opacity(0.5) : color)
        .disabled(isUnavailable)
        .help(accessibleTitle)
        .accessibilityLabel(accessibleTitle)
    }

    private var label: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}


private struct ActivityBottomPreference: PreferenceKey {
    static var defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

private struct TaskActivityList: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.entries == rhs.entries }
    let entries: [TaskActivity]
    @State private var following = true
    @State private var hasNewEntries = false
    private let rowHeight: CGFloat = 28
    private var height: CGFloat { CGFloat(min(max(entries.count, 1), 10)) * rowHeight }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Group {
                    if #available(macOS 15.0, *) {
                        LazyVStack(alignment: .leading, spacing: 0) { rows }
                    } else {
                        VStack(alignment: .leading, spacing: 0) { rows }
                    }
                }
                .background {
                    if #available(macOS 15.0, *) {
                        EmptyView()
                    } else {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ActivityBottomPreference.self,
                                value: geometry.frame(in: .named("activity")).maxY <= height + 2)
                        }
                    }
                }
            }

            .coordinateSpace(name: "activity")
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if entries.isEmpty { Text("暂无活动记录").font(.caption).foregroundStyle(.tertiary).padding(.top, 6) }
            }
            .overlay(alignment: .bottomTrailing) {
                if hasNewEntries && !following {
                    Button("查看最新", systemImage: "arrow.down") {
                        following = true
                        hasNewEntries = false
                        proxy.scrollTo("latest", anchor: .bottom)
                    }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                }
            }
            .modifier(ActivityScrollTracking(following: $following, hasNewEntries: $hasNewEntries))
            .onPreferenceChange(ActivityBottomPreference.self) { isAtBottom in
                if #available(macOS 15.0, *) { return }
                if following != isAtBottom { following = isAtBottom }
                if isAtBottom && hasNewEntries { hasNewEntries = false }
            }
            .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
            .onChange(of: entries) { _, _ in
                if following { proxy.scrollTo("latest", anchor: .bottom) }
                else { hasNewEntries = true }
            }
        }
    }

    @ViewBuilder private var rows: some View {
        ForEach(entries) { entry in
            TaskActivityRow(entry: entry).equatable()
        }
        Color.clear.frame(height: 0).id("latest")
    }
}

private struct TaskActivityRow: View, Equatable {
    let entry: TaskActivity
    var body: some View {
                        HStack(spacing: 10) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .monospacedDigit().foregroundStyle(.tertiary)
                                .frame(width: 64, alignment: .leading)
                            Image(systemName: symbol(entry.kind))
                                .foregroundStyle(color(entry.kind)).frame(width: 14)
                                .accessibilityHidden(true)
                            Text(entry.message).lineLimit(1)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption)
                        .frame(height: 28)
                        .help(entry.date.formatted(date: .abbreviated, time: .standard) + " · " + entry.message)
                        .textSelection(.enabled)
                        .contextMenu {
                            Button("复制记录") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.date.formatted() + " · " + entry.message, forType: .string)
                            }
                        }
    }

    private func symbol(_ kind: TaskActivity.Kind) -> String {
        switch kind {
        case .information: "circle.fill"
        case .stock: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    private func color(_ kind: TaskActivity.Kind) -> Color {
        switch kind {
        case .information: .secondary
        case .stock: .green
        case .warning: .orange
        case .error: .red
        }
    }
}


private struct ActivityScrollTracking: ViewModifier {
    @Binding var following: Bool
    @Binding var hasNewEntries: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 2
            } action: { _, isAtBottom in
                following = isAtBottom
                if isAtBottom { hasNewEntries = false }
            }
        } else {
            content
        }
    }
}
