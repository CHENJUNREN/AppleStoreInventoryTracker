import SwiftUI

struct ContentView: View {
    let store: TaskStore
    @State private var selection = "monitor"
    @State private var editing: ScanTask?
    @State private var deleting: ScanTask?
    @State private var actionError: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(" 产品库存监控", systemImage: "shippingbox").tag("monitor")
                Label("配置", systemImage: "slider.horizontal.3").tag("settings")
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
        } detail: {
            Group {
                if selection == "settings" {
                    ConfigurationView(store: store)
                } else {
                    monitoringPage
                }
            }
            .navigationTitle(selection == "settings" ? "配置" : " 产品库存监控")
        }
        .frame(minWidth: 780, minHeight: 520)
        .sheet(item: $editing) { task in TaskEditor(store: store, initial: task) }
        .alert("删除扫描任务？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let task = deleting { store.delete(task) }
                deleting = nil
            }
        } message: { Text("该任务的扫描将停止，保存的配置将被删除。") }
        .alert("无法开始扫描", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("好") { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

    private var monitoringPage: some View {
        VStack(spacing: 0) {
            if let error = store.storageError {
                Text(error).foregroundStyle(.red).padding()
            }
            if store.tasks.isEmpty {
                ContentUnavailableView {
                    Label("添加第一个产品", systemImage: "shippingbox")
                } description: {
                    Text("添加型号，开始监测到店取货库存。")
                } actions: {
                    Button("添加产品", systemImage: "plus") { editing = ScanTask() }
                        .buttonStyle(.borderedProminent).disabled(store.storageError != nil)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(store.tasks) { task in
                            ScanTaskCard(task: task, defaults: store.defaults, runner: store.runner(for: task.id),
                                         start: {
                                if let error = store.validationError(for: task) { actionError = error }
                                else { store.start(task) }
                            }, edit: { editing = task }, delete: { deleting = task })
                        }
                    }.padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: store.tasks.isEmpty ? .textBackgroundColor : .underPageBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("添加产品", systemImage: "plus") { editing = ScanTask() }
                    .keyboardShortcut("n").disabled(store.storageError != nil)
            }
        }
    }
}

private struct ScanTaskCard: View {
    let task: ScanTask
    let defaults: ScanDefaults
    let runner: ContentViewModel
    let start: () -> Void
    let edit: () -> Void
    let delete: () -> Void
    @State private var expanded = false
    private var effective: ScanDefaults { task.resolved(using: defaults) }

    private var regionLabel: String {
        let region = effective.region
        return "\(region.city) · \(region.district)"
    }

    private var status: String {
        if runner.isQuerying { return "查询中" }
        if runner.lastError != nil { return "等待重试" }
        if runner.isTracking { return runner.countdownText }
        return runner.hasStarted ? "已停止" : "未开始"
    }

    private var stockSummary: String {
        guard let inventory = runner.inventoryInfos.first else { return regionLabel }
        let stock = inventory.availableStores.isEmpty ? "暂无现货" : "\(inventory.availableStores.count) 家可取货"
        let stale = !runner.isTracking || !runner.hasCompletedRequest || runner.lastError != nil ? " · 上次结果" : ""
        return "\(regionLabel) · \(stock)\(stale)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                product
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(status)
                    .font(.caption).monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
                    .foregroundStyle(runner.lastError == nil ? Color.secondary : Color.orange)
                    .help(runner.isTracking ? runner.countdownLabel : status)
                    .accessibilityLabel(runner.isTracking && !runner.isQuerying ? "\(runner.countdownLabel)，\(status)" : status)
                HStack(spacing: 6) {
                    iconButton(runner.isTracking ? "停止扫描" : "开始扫描", symbol: runner.isTracking ? "stop.fill" : "play.fill") {
                        if runner.isTracking { runner.stopTracking(preservingResults: true) } else { start() }
                    }
                    iconButton("编辑", symbol: "pencil", action: edit)
                    iconButton("删除", symbol: "trash", action: delete)
                    iconButton(expanded ? "收起详情" : "展开详情", symbol: expanded ? "chevron.up" : "chevron.down") {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    }
                    .accessibilityValue(expanded ? "已展开" : "已收起")
                }
            }
            if expanded {
                Divider().padding(.vertical, 16)
                details
            }
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var highlightedAvailability: String? {
        guard runner.isTracking, runner.hasCompletedRequest, runner.lastError == nil,
              let inventory = runner.inventoryInfos.first, !inventory.availableStores.isEmpty else { return nil }
        return "\(inventory.availableStores.count) 家可取货"
    }

    private func iconButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var product: some View {
        if let inventory = runner.inventoryInfos.first {
            if let url = inventory.purchaseURL {
                Link(destination: url) {
                    ProductInventoryHeader(inventory: inventory, title: task.name.isEmpty ? nil : task.name, summary: highlightedAvailability == nil ? stockSummary : regionLabel, highlightedAvailability: highlightedAvailability)
                }.buttonStyle(.plain).help("在 Apple 官网查看产品")
            } else {
                ProductInventoryHeader(inventory: inventory, title: task.name.isEmpty ? nil : task.name, summary: highlightedAvailability == nil ? stockSummary : regionLabel, highlightedAvailability: highlightedAvailability)
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox").font(.title2).foregroundStyle(.tertiary)
                    .frame(width: 52, height: 52)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text(task.name.isEmpty ? task.product : task.name).font(.headline).lineLimit(2)
                    Text(regionLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = runner.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                Text(task.product)
                Spacer()
                Text("每 \(effective.interval) 秒")
                Text("通知：\(notificationSummary)")
            }.foregroundStyle(.secondary)
            if let date = runner.lastSuccessAt {
                HStack {
                    Text("更新于 \(date.formatted(date: .omitted, time: .standard))")
                    Spacer()
                    Text("\(runner.trackingCount) 次扫描")
                }.foregroundStyle(.secondary)
            }
            if runner.isTracking { Text(runner.countdownLabel).foregroundStyle(.secondary) }
            if let inventory = runner.inventoryInfos.first {
                ForEach(inventory.stores) { shop in
                    HStack {
                        Text(shop.storeName)
                        Spacer()
                        Label(shop.isProductAvailable ? "可取货" : "暂无现货", systemImage: shop.isProductAvailable ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(shop.isProductAvailable && runner.isTracking && runner.hasCompletedRequest && runner.lastError == nil ? Color.green : Color.secondary)
                    }
                }
            }
        }.font(.caption)
    }

    private var notificationSummary: String {
        let names = [effective.appNotification ? "系统" : nil, effective.barkNotification ? "Bark" : nil].compactMap { $0 }
        return names.isEmpty ? "关闭" : names.joined(separator: "、")
    }
}
