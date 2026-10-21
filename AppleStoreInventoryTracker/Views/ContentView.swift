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
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        let stale = hasCurrentResult ? "" : " · 上次结果"
        return "\(regionLabel) · \(stock)\(stale)"
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
                    details.textSelection(.enabled)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.primary.opacity(hovering ? 0.025 : 0))
                        .allowsHitTesting(false)
                }
        }
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
        .help(expanded ? "收起详情" : "查看门店库存")
        .accessibilityValue(expanded ? "已展开" : "已收起")
        .onHover { hovering = $0 }
    }

    private var isCountingDown: Bool {
        runner.isTracking && !runner.isQuerying && runner.lastError == nil
    }

    private var statusLabel: some View {
        Text(status)
            .font(.caption)
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : (isCountingDown ? .numericText(countsDown: true) : .opacity))
            // Scope animation to the label so each tick cannot animate the card or its actions.
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: status)
            .frame(width: 64, alignment: .trailing)
            .foregroundStyle(runner.lastError == nil ? Color.secondary : Color.orange)
            .help(runner.isTracking ? runner.countdownLabel : status)
            .accessibilityLabel(isCountingDown ? "\(runner.countdownLabel)，\(status)" : status)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            CardIconAction(
                title: runner.isTracking ? "停止扫描" : "开始扫描",
                symbol: runner.isTracking ? "stop.fill" : "play.fill",
                destination: .action {
                    if runner.isTracking { runner.stopTracking(preservingResults: true) }
                    else { start() }
                }
            )
            CardIconAction(title: "编辑", symbol: "slider.horizontal.3", destination: .action(edit))
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

    @ViewBuilder
    private var product: some View {
        if let inventory = runner.inventoryInfos.first {
            ProductInventoryHeader(inventory: inventory, title: task.name.isEmpty ? nil : task.name, summary: highlightedAvailability == nil ? stockSummary : regionLabel, highlightedAvailability: highlightedAvailability)
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
                    .foregroundStyle(.orange)
            }
            if let inventory = runner.inventoryInfos.first {
                ForEach(inventory.stores) { shop in
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
